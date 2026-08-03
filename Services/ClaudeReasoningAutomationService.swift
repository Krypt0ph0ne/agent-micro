import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.hid
import Observation
import OSLog

/// Claude Desktop exposes effort and model as two separate composer pop-ups.
/// Turning the dial steps the effort slider inside the effort pop-up; holding
/// the dial and turning walks the model menu and confirms on release.
///
/// Every step is verified against Claude's own state rather than against the
/// return code of the action that caused it — see `ClaudeAccessibilityControls`
/// for why that distinction matters here (Chromium reports success for
/// Accessibility actions it then discards).
@MainActor
@Observable
final class ClaudeReasoningAutomationService: EncoderAutomationService {
    private let logger = Logger(subsystem: "io.github.krypt0ph0ne.agentmicro", category: "claude-encoder")
    private static let preferenceKey = "AgentMicro.claudeEncoderAutomationEnabled"
    private static let modelListHoldThresholdSeconds: TimeInterval = 0.35
    static var modelListHoldThresholdMilliseconds: Int { Int(modelListHoldThresholdSeconds * 1000) }
    /// How long a pop-up opened by the dial stays open after the last step.
    /// Reopening it per detent would make a fast rotation unusable, so a burst
    /// of turns shares one open pop-up.
    private static let idleCloseSeconds: TimeInterval = 1.6
    /// Polling grid for "did Claude actually do it". Chosen from the measured
    /// live behaviour: the effort pop-up reports `AXExpanded == true` within
    /// roughly 150 ms of the activating key.
    private static let pollIntervalSeconds: TimeInterval = 0.05
    private static let openTimeoutSeconds: TimeInterval = 1.0
    private static let valueChangeTimeoutSeconds: TimeInterval = 0.6
    private static let closeTimeoutSeconds: TimeInterval = 0.6

    /// True while the Claude profile is selected; both this service and
    /// `CodexReasoningAutomationService` listen to the same private F22–F24
    /// HID triggers, so only the one matching the active profile may act.
    private let isActiveProfile: () -> Bool
    var isExternallySuspended: () -> Bool = { false }
    private var hidManager: IOHIDManager?
    private var inputDebouncer = HIDInputDebouncer()
    private var encoderHoldTimer: Timer?
    private var encoderHoldFired = false
    private var isEncoderPressed = false
    private var suppressCurrentEncoderPress = false
    /// Vendor-protocol encoder events remain valid across a keyboard HID
    /// interface re-enumeration, so they are authoritative for custom pads.
    var usesPhysicalEncoderEvents = false {
        didSet {
            guard oldValue != usesPhysicalEncoderEvents else { return }
            updateMonitoring()
        }
    }

    /// Serializes the Accessibility work. A gesture that arrives while another
    /// one is still driving Claude's UI is reported and dropped instead of
    /// interleaving keystrokes into a half-open menu.
    private var isSequenceInFlight = false
    private var idleCloseTask: Task<Void, Never>?
    /// Cached composer controls. Chromium invalidates elements freely, so both
    /// are revalidated before every use.
    private var cachedEffortPopUp: AXUIElement?
    private var cachedModelPopUp: AXUIElement?
    private var isEffortPopoverOpen = false
    private var isModelMenuOpen = false

    private let permissionMonitor: PermissionMonitor
    private(set) var status = AppLanguage.text("Deaktiviert", "Disabled")
    private(set) var lastInput = AppLanguage.text("Noch kein Drehrad-Signal empfangen", "No dial signal received yet")
    var hasAccessibilityPermission: Bool { permissionMonitor.hasAccessibilityPermission }
    var hasInputMonitoringPermission: Bool { permissionMonitor.hasInputMonitoringPermission }
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.preferenceKey)
            updateMonitoring()
        }
    }

    init(permissionMonitor: PermissionMonitor, isActiveProfile: @escaping () -> Bool) {
        self.permissionMonitor = permissionMonitor
        self.isActiveProfile = isActiveProfile
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.preferenceKey)
        updateMonitoring()
    }

    func requestPermissions() {
        if usesPhysicalEncoderEvents {
            permissionMonitor.requestAccessibilityPermission()
        } else {
            permissionMonitor.requestPermissions()
        }
        updateMonitoring()
        if !hasAccessibilityPermission || (!usesPhysicalEncoderEvents && !hasInputMonitoringPermission) {
            status = AppLanguage.text(
                "Berechtigungen fehlen noch. In den Systemeinstellungen Agent Micro aktivieren und danach zur App zurückkehren.",
                "Permissions are still missing. Enable Agent Micro in System Settings, then come back to the app."
            )
        }
    }

    func refreshPermissions() {
        permissionMonitor.refresh()
        updateMonitoring()
    }

    // MARK: - Input

    /// Model-list-navigation entry point fed by Agent Micro's own firmware
    /// protocol, mirroring `CodexReasoningAutomationService.handlePhysicalEvent`
    /// — the only channel that reliably reports the encoder press's release
    /// edge on the confirmed hardware.
    func handlePhysicalEvent(_ event: CodexPadPhysicalEvent) {
        guard let control = HardwareControl(reportedControlIndex: event.control),
              HardwareControl.encoderActions.contains(control) else { return }
        let source = event.origin == .hardware ? "Hardware" : AppLanguage.text("Diagnose", "Diagnostics")
        lastInput = "\(source): \(control.title) · \(String(describing: event.phase)) · #\(event.sequence)"
        logger.info(
            "Physical encoder received origin=\(event.origin.rawValue, privacy: .public) control=\(control.rawValue, privacy: .public) phase=\(event.phase.rawValue, privacy: .public)"
        )
        guard isActiveProfile() else {
            status = AppLanguage.text(
                "Drehrad ignoriert: Claude-Profil ist nicht aktiv.",
                "Dial ignored: the Claude profile is not active."
            )
            logger.error("Physical encoder rejected: inactive Claude profile")
            return
        }
        guard !isExternallySuspended() else {
            status = AppLanguage.text(
                "Drehrad wartet: Thread-Auswahl ist noch aktiv.",
                "Dial waiting: thread selection is still active."
            )
            logger.error("Physical encoder rejected: thread picker is active")
            return
        }
        logger.info("Physical encoder accepted by Claude automation")
        switch control {
        case .encoderPress:
            switch event.phase {
            case .pressed: beginEncoderHold()
            case .released: endEncoderHold()
            case .triggered: break
            }
        // Confirmed against the hardware: the control labels match the physical
        // rotation, so turning left steps down and turning right steps up. This
        // is the same mapping `CodexReasoningAutomationService` uses.
        case .encoderLeft:
            guard event.phase == .triggered else { return }
            handleRotation(.previous)
        case .encoderRight:
            guard event.phase == .triggered else { return }
            handleRotation(.next)
        case .key1, .key2, .key3, .key4, .key5, .key6:
            break
        }
    }

    private func handleRotation(_ step: CodexModelListStep) {
        if encoderHoldFired {
            driveModelMenuHighlight(step)
        } else if isEncoderPressed {
            status = AppLanguage.text(
                "Drehrad wird gehalten – nach \(Self.modelListHoldThresholdMilliseconds) ms Modelle auswählen.",
                "Dial held — choose models after \(Self.modelListHoldThresholdMilliseconds) ms."
            )
        } else {
            stepEffort(step)
        }
    }

    private func beginEncoderHold() {
        encoderHoldTimer?.invalidate()
        isEncoderPressed = true
        suppressCurrentEncoderPress = false
        encoderHoldFired = false
        guard !isSequenceInFlight else {
            suppressCurrentEncoderPress = true
            status = AppLanguage.text(
                "Drehrad-Druck wartet: eine Aufwandänderung läuft noch.",
                "Dial press waiting: an effort change is still running."
            )
            return
        }
        encoderHoldTimer = Timer.scheduledTimer(withTimeInterval: Self.modelListHoldThresholdSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fireEncoderHold() }
        }
    }

    /// Fires when the hold threshold is crossed and opens Claude's model menu.
    private func fireEncoderHold() {
        guard !suppressCurrentEncoderPress, isEncoderPressed else { return }
        guard isActiveProfile(), !isExternallySuspended() else {
            status = AppLanguage.text(
                "Modellwahl abgebrochen: Profil oder Thread-Auswahl hat sich geändert.",
                "Model selection cancelled: the profile or thread selection changed."
            )
            return
        }
        guard !isSequenceInFlight else { return }
        encoderHoldFired = true
        run { await self.openModelMenu() }
    }

    /// Releasing after a short press is the plain tap gesture: toggle the
    /// effort pop-up. Releasing after a real hold confirms the highlighted
    /// model and closes the model menu instead.
    private func endEncoderHold() {
        encoderHoldTimer?.invalidate()
        encoderHoldTimer = nil
        isEncoderPressed = false
        if suppressCurrentEncoderPress {
            suppressCurrentEncoderPress = false
            return
        }
        let wasHeld = encoderHoldFired
        encoderHoldFired = false
        guard wasHeld else {
            toggleEffortMenu()
            return
        }
        run { await self.confirmModelSelection() }
    }

    // MARK: - Effort

    /// One dial detent = one step of Claude's effort slider, verified by
    /// re-reading the slider's own value afterwards.
    private func stepEffort(_ direction: CodexModelListStep) {
        guard !isModelMenuOpen else {
            status = AppLanguage.text(
                "Drehschritt ignoriert: das Modellmenü ist noch offen.",
                "Dial step ignored: the model menu is still open."
            )
            return
        }
        guard !isSequenceInFlight else {
            status = AppLanguage.text(
                "Drehschritt ignoriert: Claude verarbeitet noch die vorherige Geste.",
                "Dial step ignored: Claude is still processing the previous gesture."
            )
            return
        }
        run { await self.performEffortStep(direction) }
    }

    private func performEffortStep(_ direction: CodexModelListStep) async {
        guard let context = await openEffortPopover() else { return }
        guard let slider = ClaudeAccessibilityControls.effortSlider(in: context.application) else {
            status = AppLanguage.text(
                "Claudes Aufwand-Regler wurde im geöffneten Menü nicht gefunden.",
                "Claude's effort slider was not found in the open menu."
            )
            await closeEffortPopover(context)
            return
        }

        let previous = ClaudeAccessibilityControls.stringValue(of: slider)
        guard let updated = await adjust(slider, direction: direction, from: previous, pid: context.pid) else {
            // No change is not automatically a failure: at either end of the
            // scale the slider legitimately stays put. Distinguish the two by
            // asking whether the value is still readable at all.
            let current = ClaudeAccessibilityControls.stringValue(of: slider)
            if current == previous, !current.isEmpty {
                status = direction == .next
                    ? AppLanguage.text(
                        "Claude-Aufwand ist bereits maximal (\(current)).",
                        "Claude's effort is already at maximum (\(current))."
                    )
                    : AppLanguage.text(
                        "Claude-Aufwand ist bereits minimal (\(current)).",
                        "Claude's effort is already at minimum (\(current))."
                    )
            } else {
                status = AppLanguage.text(
                    "Claude-Aufwand ließ sich nicht ändern (\(previous.isEmpty ? "kein Wert lesbar" : previous)).",
                    "Claude's effort could not be changed (\(previous.isEmpty ? "no readable value" : previous))."
                )
                await closeEffortPopover(context)
                return
            }
            scheduleIdleClose(context)
            return
        }

        status = AppLanguage.text("Claude-Aufwand: \(updated)", "Claude effort: \(updated)")
        logger.info("Claude effort changed \(previous, privacy: .public) → \(updated, privacy: .public)")
        scheduleIdleClose(context)
    }

    /// Steps the slider and waits for its value to actually change.
    /// `AXIncrement`/`AXDecrement` is preferred because it needs no synthetic
    /// input at all; the arrow key is the fallback for the case where Chromium
    /// accepts the Accessibility action and drops it, which it demonstrably
    /// does for other actions on these controls.
    private func adjust(
        _ slider: AXUIElement,
        direction: CodexModelListStep,
        from previous: String,
        pid: pid_t
    ) async -> String? {
        let action = direction == .next ? kAXIncrementAction : kAXDecrementAction
        ClaudeAccessibilityControls.perform(action, on: slider)
        if let changed = await waitForValueChange(of: slider, from: previous) { return changed }

        let keyCode = direction == .next ? kVK_RightArrow : kVK_LeftArrow
        ClaudeAccessibilityControls.postKey(keyCode, to: pid)
        return await waitForValueChange(of: slider, from: previous)
    }

    private func waitForValueChange(of slider: AXUIElement, from previous: String) async -> String? {
        await poll(timeout: Self.valueChangeTimeoutSeconds) {
            let current = ClaudeAccessibilityControls.stringValue(of: slider)
            return (!current.isEmpty && current != previous) ? current : nil
        }
    }

    func toggleEffortMenu() {
        guard !isModelMenuOpen else {
            status = AppLanguage.text(
                "Menü wartet: das Modellmenü ist noch offen.",
                "Menu waiting: the model menu is still open."
            )
            return
        }
        guard !isSequenceInFlight else {
            status = AppLanguage.text(
                "Menü wartet: Claude verarbeitet noch die vorherige Geste.",
                "Menu waiting: Claude is still processing the previous gesture."
            )
            return
        }
        run {
            if self.isEffortPopoverOpen, let context = self.currentContext() {
                await self.closeEffortPopover(context)
                return
            }
            guard let context = await self.openEffortPopover() else { return }
            let value = ClaudeAccessibilityControls.effortSlider(in: context.application)
                .map(ClaudeAccessibilityControls.stringValue(of:)) ?? ""
            self.status = value.isEmpty
                ? AppLanguage.text("Aufwandmenü geöffnet.", "Effort menu opened.")
                : AppLanguage.text("Aufwandmenü offen · \(value)", "Effort menu open · \(value)")
            self.scheduleIdleClose(context)
        }
    }

    // MARK: - Model menu

    private func openModelMenu() async {
        guard let context = currentContext() else { return }
        guard let popUp = resolveModelPopUp(in: context.application) else {
            status = AppLanguage.text(
                "Claudes Modellauswahl wurde nicht gefunden.",
                "Claude's model selector was not found."
            )
            return
        }
        await cancelIdleClose()
        if isEffortPopoverOpen { await closeEffortPopover(context) }

        guard await open(popUp, context: context) else {
            status = AppLanguage.text(
                "Claudes Modellmenü ließ sich nicht öffnen.",
                "Claude's model menu did not open."
            )
            isModelMenuOpen = false
            return
        }
        isModelMenuOpen = true
        let current = ClaudeAccessibilityControls.title(of: popUp)
        status = AppLanguage.text(
            "Modellmenü offen (\(current)): drehen wählt, loslassen übernimmt.",
            "Model menu open (\(current)): turn to choose, release to confirm."
        )
    }

    /// Only acts while the model menu is verified open. Arrow keys go to
    /// Claude's process so a menu that lost focus cannot leak keystrokes into
    /// whatever the user is doing elsewhere.
    private func driveModelMenuHighlight(_ step: CodexModelListStep) {
        guard isModelMenuOpen, let context = currentContext() else { return }
        guard let popUp = cachedModelPopUp, ClaudeAccessibilityControls.isExpanded(popUp) else {
            isModelMenuOpen = false
            status = AppLanguage.text(
                "Modellmenü ist nicht mehr offen – Auswahl abgebrochen.",
                "The model menu is no longer open — selection cancelled."
            )
            return
        }
        ClaudeAccessibilityControls.postKey(step == .next ? kVK_DownArrow : kVK_UpArrow, to: context.pid)
        status = step == .next
            ? AppLanguage.text("Nächstes Modell", "Next model")
            : AppLanguage.text("Vorheriges Modell", "Previous model")
    }

    private func confirmModelSelection() async {
        guard isModelMenuOpen, let context = currentContext(), let popUp = cachedModelPopUp else {
            isModelMenuOpen = false
            return
        }
        let previous = ClaudeAccessibilityControls.title(of: popUp)
        ClaudeAccessibilityControls.postKey(kVK_Return, to: context.pid)

        let collapsed = await poll(timeout: Self.closeTimeoutSeconds) {
            ClaudeAccessibilityControls.isExpanded(popUp) ? nil : true
        } != nil
        isModelMenuOpen = false
        guard collapsed else {
            await forceClose(context)
            status = AppLanguage.text(
                "Modellauswahl ließ sich nicht bestätigen – Menü wurde geschlossen.",
                "The model selection could not be confirmed — the menu was closed."
            )
            return
        }
        let current = ClaudeAccessibilityControls.title(of: popUp)
        status = current == previous
            ? AppLanguage.text("Modell unverändert: \(current)", "Model unchanged: \(current)")
            : AppLanguage.text("Modell: \(current)", "Model: \(current)")
        logger.info("Claude model \(previous, privacy: .public) → \(current, privacy: .public)")
    }

    // MARK: - Pop-up handling

    private struct Context {
        let application: AXUIElement
        let pid: pid_t
        let runningApplication: NSRunningApplication
    }

    private func currentContext() -> Context? {
        guard let claude = readyClaudeApplication() else { return nil }
        return Context(
            application: ClaudeAccessibilityControls.application(for: claude.processIdentifier),
            pid: claude.processIdentifier,
            runningApplication: claude
        )
    }

    private func openEffortPopover() async -> Context? {
        guard let context = currentContext() else { return nil }
        guard let popUp = resolveEffortPopUp(in: context.application) else {
            status = AppLanguage.text(
                "Claudes Aufwand-Auswahl wurde nicht gefunden.",
                "Claude's effort control was not found."
            )
            isEffortPopoverOpen = false
            return nil
        }
        await cancelIdleClose()
        guard await open(popUp, context: context) else {
            status = AppLanguage.text(
                "Claudes Aufwandmenü ließ sich nicht öffnen.",
                "Claude's effort menu did not open."
            )
            isEffortPopoverOpen = false
            return nil
        }
        isEffortPopoverOpen = true
        return context
    }

    /// Focus through Accessibility, then activate with a real key sent to
    /// Claude. `AXPress` is deliberately not used: on this control Chromium
    /// returns `.success` without ever expanding the pop-up.
    private func open(_ popUp: AXUIElement, context: Context) async -> Bool {
        if ClaudeAccessibilityControls.isExpanded(popUp) { return true }
        context.runningApplication.activate(options: [.activateAllWindows])
        ClaudeAccessibilityControls.focus(popUp)
        ClaudeAccessibilityControls.postKey(kVK_Space, to: context.pid)
        return await poll(timeout: Self.openTimeoutSeconds) {
            ClaudeAccessibilityControls.isExpanded(popUp) ? true : nil
        } != nil
    }

    private func closeEffortPopover(_ context: Context) async {
        await cancelIdleClose()
        defer { isEffortPopoverOpen = false }
        guard let popUp = cachedEffortPopUp, ClaudeAccessibilityControls.isExpanded(popUp) else { return }
        ClaudeAccessibilityControls.postKey(kVK_Escape, to: context.pid)
        let collapsed = await poll(timeout: Self.closeTimeoutSeconds) {
            ClaudeAccessibilityControls.isExpanded(popUp) ? nil : true
        } != nil
        if !collapsed { await forceClose(context) }
    }

    /// Last resort when a pop-up refuses to collapse. Two Escapes cover the
    /// case where the first one only dismissed a nested element.
    private func forceClose(_ context: Context) async {
        for _ in 0..<2 {
            ClaudeAccessibilityControls.postKey(kVK_Escape, to: context.pid)
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        isEffortPopoverOpen = false
        isModelMenuOpen = false
    }

    private func scheduleIdleClose(_ context: Context) {
        idleCloseTask?.cancel()
        idleCloseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleCloseSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isEffortPopoverOpen else { return }
            await self.closeEffortPopover(context)
        }
    }

    private func cancelIdleClose() async {
        idleCloseTask?.cancel()
        idleCloseTask = nil
    }

    /// Chromium hands out short-lived elements, so a cached control is only
    /// reused while it still answers queries.
    private func resolveEffortPopUp(in application: AXUIElement) -> AXUIElement? {
        if let cached = cachedEffortPopUp, ClaudeAccessibilityControls.isAlive(cached) { return cached }
        cachedEffortPopUp = ClaudeAccessibilityControls.effortPopUp(in: application)
        return cachedEffortPopUp
    }

    private func resolveModelPopUp(in application: AXUIElement) -> AXUIElement? {
        if let cached = cachedModelPopUp, ClaudeAccessibilityControls.isAlive(cached) { return cached }
        cachedModelPopUp = ClaudeAccessibilityControls.modelPopUp(in: application)
        return cachedModelPopUp
    }

    // MARK: - Sequencing

    /// Runs one Accessibility gesture at a time. Overlapping gestures are what
    /// produced arrow keys landing in a menu that was no longer open.
    private func run(_ work: @escaping () async -> Void) {
        guard !isSequenceInFlight else { return }
        isSequenceInFlight = true
        Task { @MainActor in
            await work()
            self.isSequenceInFlight = false
        }
    }

    private func poll<T>(timeout: TimeInterval, _ probe: () -> T?) async -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = probe() { return value }
            try? await Task.sleep(nanoseconds: UInt64(Self.pollIntervalSeconds * 1_000_000_000))
        } while Date() < deadline
        return probe()
    }

    // MARK: - Testing hooks

    /// Testing hooks for the assignment panel: skip the hold-timer wait so a
    /// button click can exercise the same state machine as a real long press.
    func testBeginHold() {
        encoderHoldTimer?.invalidate()
        isEncoderPressed = true
        suppressCurrentEncoderPress = false
        fireEncoderHold()
    }

    func testRotate(_ step: CodexModelListStep) {
        driveModelMenuHighlight(step)
    }

    func testEndHold() {
        encoderHoldFired = true
        endEncoderHold()
    }

    // MARK: - Effort vocabulary

    /// Claude labels the effort slider in the app's own language. The ranking
    /// is only used for display and tests — stepping itself never depends on
    /// it, because the slider is moved one detent at a time and read back.
    nonisolated static func effortRank(in text: String) -> Int? {
        let words = Set(
            text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        )
        if words.contains("max") || words.contains("maximum") || words.contains("maximal") { return 4 }
        if words.contains("extra") { return 3 }
        if words.contains("hoch") || words.contains("high") { return 2 }
        if words.contains("mittel") || words.contains("medium") { return 1 }
        if words.contains("niedrig") || words.contains("low") { return 0 }
        return nil
    }

    nonisolated static func targetEffortRank(current: Int, delta: Int) -> Int {
        min(max(current + delta, 0), 4)
    }

    // MARK: - Lifecycle

    private var claudeApplication: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: AutomationApp.claude.bundleIdentifier)
            .first(where: { $0.bundleURL?.lastPathComponent == "Claude.app" })
    }

    private func readyClaudeApplication() -> NSRunningApplication? {
        guard isEnabled else {
            status = AppLanguage.text("Encoder-Steuerung ist deaktiviert.", "Dial control is disabled.")
            return nil
        }
        guard hasAccessibilityPermission else {
            status = AppLanguage.text(
                "Bedienungshilfen fehlen. Bitte unten Berechtigungen anfordern.",
                "Accessibility permission is missing. Request permissions below."
            )
            return nil
        }
        guard isActiveProfile(), !isExternallySuspended() else {
            status = AppLanguage.text(
                "Claude-Automation pausiert: Profil oder Thread-Auswahl hat sich geändert.",
                "Claude automation paused: the profile or thread selection changed."
            )
            return nil
        }
        guard let claude = claudeApplication else {
            // Claude isn't running (or was quit/relaunched since we last
            // opened a menu): whatever we assumed about its UI state no
            // longer holds, so drop it rather than risk sending keys into a
            // menu that isn't there.
            resetState()
            status = AppLanguage.text("Claude läuft nicht.", "Claude is not running.")
            return nil
        }
        return claude
    }

    private func resetState() {
        encoderHoldTimer?.invalidate()
        encoderHoldTimer = nil
        encoderHoldFired = false
        isEncoderPressed = false
        suppressCurrentEncoderPress = false
        idleCloseTask?.cancel()
        idleCloseTask = nil
        isSequenceInFlight = false
        isEffortPopoverOpen = false
        isModelMenuOpen = false
        cachedEffortPopUp = nil
        cachedModelPopUp = nil
    }

    private func updateMonitoring() {
        stopMonitoring()
        resetState()
        guard isEnabled else {
            status = AppLanguage.text("Deaktiviert", "Disabled")
            return
        }

        guard hasAccessibilityPermission else {
            status = AppLanguage.text(
                "Bedienungshilfen fehlen – Agent Micro darf Claude nicht steuern.",
                "Accessibility permission is missing — Agent Micro may not control Claude."
            )
            return
        }

        guard hasInputMonitoringPermission || usesPhysicalEncoderEvents else {
            status = AppLanguage.text(
                "Input Monitoring fehlt – macOS blockiert das Drehrad. Bitte Agent Micro unten freigeben.",
                "Input Monitoring is missing — macOS is blocking the dial. Allow Agent Micro below."
            )
            return
        }

        guard !usesPhysicalEncoderEvents else {
            status = AppLanguage.text(
                "Bereit: Drehrad läuft über das direkte Pad-Protokoll. Nur Bedienungshilfen werden benötigt.",
                "Ready: the dial runs over the direct pad protocol. Only Accessibility is required."
            )
            return
        }

        status = AppLanguage.text(
            "Bereit: Drehen = Reasoning-Aufwand · Halten (>\(Int(Self.modelListHoldThresholdSeconds * 1000)) ms) + drehen = Modell wechseln.",
            "Ready: turn = reasoning effort · hold (>\(Int(Self.modelListHoldThresholdSeconds * 1000)) ms) + turn = switch model."
        )

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let keyboardIdentity: (Int, Int) -> [String: Any] = { vendorID, productID in
            [
                kIOHIDVendorIDKey as String: vendorID,
                kIOHIDProductIDKey as String: productID,
                kIOHIDPrimaryUsagePageKey as String: 0x01,
                kIOHIDPrimaryUsageKey as String: 0x06
            ]
        }
        let matching = [keyboardIdentity(0x1189, 0x8890), keyboardIdentity(0x4249, 0x4287)]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        IOHIDManagerRegisterInputValueCallback(manager, Self.inputCallback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            status = AppLanguage.text(
                "Drehrad konnte nicht geöffnet werden (\(result)).",
                "Could not open the dial (\(result))."
            )
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            return
        }
        hidManager = manager
    }

    private func stopMonitoring() {
        guard let hidManager else { return }
        IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.hidManager = nil
    }

    private func handleHIDValue(usagePage: Int, usage: Int, value: Int) {
        guard isActiveProfile(), !isExternallySuspended(),
              usagePage == 0x07, [0x71, 0x73].contains(usage) else { return }
        guard value != 0 else { return }
        // The vendor protocol already delivered this edge; taking it twice
        // would double every detent.
        guard !usesPhysicalEncoderEvents else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard inputDebouncer.accepts(usage: usage, at: now) else { return }
        recordInput(usage: usage, value: value)

        // Same direction mapping as `handlePhysicalEvent`: F22 is rotate left
        // (step down), F24 is rotate right (step up).
        switch usage {
        case 0x71: handleRotation(.previous)
        case 0x73: handleRotation(.next)
        default: break
        }
    }

    private func recordInput(usage: Int, value: Int) {
        lastInput = HIDInputEvent.functionKeyName(usage)
            .map { AppLanguage.text("Empfangen: \($0)", "Received: \($0)") }
            ?? String(format: AppLanguage.text("Empfangen: 0x%02X", "Received: 0x%02X"), usage)
        logger.info("HID input usage=\(usage, privacy: .public) value=\(value, privacy: .public)")
    }

    nonisolated private static let inputCallback: IOHIDValueCallback = { context, _, _, value in
        guard let context else { return }
        let element = IOHIDValueGetElement(value)
        let service = Unmanaged<ClaudeReasoningAutomationService>.fromOpaque(context).takeUnretainedValue()
        let usagePage = Int(IOHIDElementGetUsagePage(element))
        let elementUsage = Int(IOHIDElementGetUsage(element))
        let integerValue = Int(IOHIDValueGetIntegerValue(value))
        guard let normalized = HIDInputEvent.normalizedKeyboardValue(elementUsage: elementUsage, value: integerValue) else { return }
        DispatchQueue.main.async {
            service.handleHIDValue(usagePage: usagePage, usage: normalized.usage, value: normalized.value)
        }
    }
}
