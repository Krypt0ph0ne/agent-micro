import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import Observation
import OSLog

/// Read-only Accessibility inspector for the installed Claude Desktop build.
///
/// The encoder automation has to drive a control whose Accessibility shape
/// changes between Claude releases, and a blind keyboard path through that
/// control cannot be validated from the outside: `AXShowMenu` reporting
/// `.success` proves only that the action was accepted, not that an Electron
/// popover actually mounted and took focus. This inspector captures the real
/// tree before, during and after the menu is opened, so the automation can be
/// written against observed structure instead of assumptions.
///
/// It never types, clicks or changes a value. The only actions it performs are
/// the popup's own open action and a final Escape-equivalent close, so a run
/// leaves Claude in the state it found it in.
@MainActor
@Observable
final class ClaudeAccessibilityInspector {
    private let logger = Logger(subsystem: "io.github.krypt0ph0ne.agentmicro", category: "claude-ax-inspector")

    /// Electron can stall an Accessibility query while the renderer is busy.
    /// Without an explicit timeout a single bad node freezes the whole dump.
    private static let messagingTimeoutSeconds: Float = 1.5
    /// Upper bound on visited nodes. A fully realized Electron tree is large
    /// but finite; this only guards against a cyclic parent/child relation.
    nonisolated private static let nodeBudget = 40_000
    nonisolated private static let maximumDepth = 120
    /// Claude mounts its popover asynchronously after the open action.
    private static let menuSettleSeconds: TimeInterval = 0.6

    private(set) var isRunning = false
    private(set) var status = AppLanguage.text(
        "Noch nicht ausgeführt.",
        "Not run yet."
    )
    private(set) var summary: [String] = []
    private(set) var lastDumpURL: URL?

    private let dumpDirectory: URL

    init(dumpDirectory: URL? = nil) {
        self.dumpDirectory = dumpDirectory ?? Self.applicationSupportDirectory()
    }

    private static func applicationSupportDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return root
            .appendingPathComponent("Agent Micro", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    func inspect() {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else {
            status = AppLanguage.text(
                "Bedienungshilfen fehlen – ohne sie ist Claudes UI unsichtbar.",
                "Accessibility permission missing — Claude's UI is invisible without it."
            )
            return
        }
        guard let claude = NSRunningApplication
            .runningApplications(withBundleIdentifier: AutomationApp.claude.bundleIdentifier)
            .first(where: { $0.bundleURL?.lastPathComponent == "Claude.app" })
        else {
            status = AppLanguage.text("Claude läuft nicht.", "Claude is not running.")
            return
        }

        isRunning = true
        summary = []
        status = AppLanguage.text("Claude-UI wird untersucht …", "Inspecting Claude's UI …")
        Task { await run(for: claude) }
    }

    /// Exercises exactly the primitives the encoder automation uses, one step
    /// up and one step back down, and reports the observed value transitions.
    /// This is the check that distinguishes "Claude accepted the action" from
    /// "the effort actually changed" — the distinction the automation used to
    /// get wrong. It restores the original level before it finishes.
    func verifyEffortWritePath() {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else {
            status = AppLanguage.text(
                "Bedienungshilfen fehlen – ohne sie ist Claudes UI unsichtbar.",
                "Accessibility permission missing — Claude's UI is invisible without it."
            )
            return
        }
        guard let claude = NSRunningApplication
            .runningApplications(withBundleIdentifier: AutomationApp.claude.bundleIdentifier)
            .first(where: { $0.bundleURL?.lastPathComponent == "Claude.app" })
        else {
            status = AppLanguage.text("Claude läuft nicht.", "Claude is not running.")
            return
        }
        isRunning = true
        summary = []
        status = AppLanguage.text("Aufwand-Schreibpfad wird geprüft …", "Verifying effort write path …")
        Task { await runWriteVerification(for: claude) }
    }

    private func runWriteVerification(for claude: NSRunningApplication) async {
        defer { isRunning = false }
        var steps: [String] = []
        let application = ClaudeAccessibilityControls.application(for: claude.processIdentifier)
        let pid = claude.processIdentifier

        guard let popUp = ClaudeAccessibilityControls.effortPopUp(in: application) else {
            summary = [AppLanguage.text("Aufwand-Auswahl nicht gefunden", "Effort control not found")]
            status = AppLanguage.text(
                "Fehlgeschlagen: Claudes Aufwand-Auswahl wurde nicht gefunden.",
                "Failed: Claude's effort control was not found."
            )
            return
        }
        steps.append(AppLanguage.text(
            "Steuerelement: \(ClaudeAccessibilityControls.title(of: popUp))",
            "Control: \(ClaudeAccessibilityControls.title(of: popUp))"
        ))

        claude.activate(options: [.activateAllWindows])
        try? await Task.sleep(nanoseconds: 300_000_000)
        if !ClaudeAccessibilityControls.isExpanded(popUp) {
            ClaudeAccessibilityControls.focus(popUp)
            ClaudeAccessibilityControls.postKey(kVK_Space, to: pid)
        }
        let opened = await waitUntil(timeout: 1.0) { ClaudeAccessibilityControls.isExpanded(popUp) }
        steps.append(AppLanguage.text(
            "Öffnen: \(opened ? "AXExpanded=1" : "FEHLGESCHLAGEN")",
            "Open: \(opened ? "AXExpanded=1" : "FAILED")"
        ))
        guard opened, let slider = ClaudeAccessibilityControls.effortSlider(in: application) else {
            summary = steps + [AppLanguage.text("Regler nicht erreichbar", "Slider not reachable")]
            status = AppLanguage.text(
                "Fehlgeschlagen: Aufwandmenü ließ sich nicht öffnen.",
                "Failed: the effort menu did not open."
            )
            await closeEffortPopUp(popUp, pid: pid)
            return
        }

        let original = ClaudeAccessibilityControls.stringValue(of: slider)
        steps.append(AppLanguage.text("Startwert: \(original)", "Initial value: \(original)"))

        let up = await step(slider, increment: true, from: original, pid: pid)
        steps.append(AppLanguage.text("Schritt hoch: \(up.description)", "Step up: \(up.description)"))

        let afterUp = ClaudeAccessibilityControls.stringValue(of: slider)
        let down = await step(slider, increment: false, from: afterUp, pid: pid)
        steps.append(AppLanguage.text("Schritt zurück: \(down.description)", "Step back: \(down.description)"))

        let restored = ClaudeAccessibilityControls.stringValue(of: slider)
        steps.append(AppLanguage.text(
            "Endwert: \(restored)\(restored == original ? " (wiederhergestellt)" : " (ABWEICHEND)")",
            "Final value: \(restored)\(restored == original ? " (restored)" : " (DIVERGED)")"
        ))

        await closeEffortPopUp(popUp, pid: pid)
        let collapsed = !ClaudeAccessibilityControls.isExpanded(popUp)
        steps.append(AppLanguage.text(
            "Schließen: \(collapsed ? "AXExpanded=0" : "FEHLGESCHLAGEN")",
            "Close: \(collapsed ? "AXExpanded=0" : "FAILED")"
        ))

        summary = steps
        let changed = up.changed || down.changed
        status = changed && collapsed && restored == original
            ? AppLanguage.text(
                "Bestätigt: Aufwand wurde nachweislich verändert und wiederhergestellt.",
                "Confirmed: effort provably changed and was restored."
            )
            : AppLanguage.text(
                "Nicht bestätigt – Details unten.",
                "Not confirmed — details below."
            )
    }

    private struct StepResult {
        let changed: Bool
        let description: String
    }

    /// Mirrors `ClaudeReasoningAutomationService.adjust`: Accessibility action
    /// first, arrow key on the focused slider as the fallback, each judged by
    /// re-reading the value rather than by its own return code.
    private func step(
        _ slider: AXUIElement,
        increment: Bool,
        from previous: String,
        pid: pid_t
    ) async -> StepResult {
        let action = increment ? kAXIncrementAction : kAXDecrementAction
        let accepted = ClaudeAccessibilityControls.perform(action, on: slider)
        if let value = await waitForValue(of: slider, changedFrom: previous) {
            return StepResult(changed: true, description: "\(previous) → \(value) via \(action)")
        }
        ClaudeAccessibilityControls.postKey(increment ? kVK_RightArrow : kVK_LeftArrow, to: pid)
        if let value = await waitForValue(of: slider, changedFrom: previous) {
            return StepResult(
                changed: true,
                description: AppLanguage.text(
                    "\(previous) → \(value) via Pfeiltaste (\(action) akzeptiert=\(accepted), aber wirkungslos)",
                    "\(previous) → \(value) via arrow key (\(action) accepted=\(accepted), but had no effect)"
                )
            )
        }
        return StepResult(changed: false, description: AppLanguage.text(
            "\(previous) unverändert (Ende der Skala oder blockiert)",
            "\(previous) unchanged (end of the scale or blocked)"
        ))
    }

    private func waitForValue(of slider: AXUIElement, changedFrom previous: String) async -> String? {
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            let current = ClaudeAccessibilityControls.stringValue(of: slider)
            if !current.isEmpty, current != previous { return current }
        }
        return nil
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
        return condition()
    }

    private func closeEffortPopUp(_ popUp: AXUIElement, pid: pid_t) async {
        guard ClaudeAccessibilityControls.isExpanded(popUp) else { return }
        ClaudeAccessibilityControls.postKey(kVK_Escape, to: pid)
        _ = await waitUntil(timeout: 0.6) { !ClaudeAccessibilityControls.isExpanded(popUp) }
    }

    private func run(for claude: NSRunningApplication) async {
        var report = Report()
        report.appendHeader(for: claude)

        let root = AXUIElementCreateApplication(claude.processIdentifier)
        AXUIElementSetMessagingTimeout(root, Self.messagingTimeoutSeconds)

        claude.activate(options: [.activateAllWindows])
        try? await Task.sleep(nanoseconds: 400_000_000)

        // Phase 1 — closed state, plus a full inventory of every pop-up button
        // in the app. The inventory is what distinguishes "the control moved"
        // from "the matcher picked the wrong node": a sidebar chat row whose
        // title happens to contain "Modell" is a text match but not a control.
        let closedNodes = Self.walk(root)
        report.appendPhase("1 · CLOSED", nodes: closedNodes)
        report.appendPopupInventory(closedNodes)
        report.appendCandidates(closedNodes.filter { $0.looksLikeModelPopup })

        var probed: [String] = []
        let targets: [(String, Node?, (Node) -> Bool)] = [
            ("EFFORT", closedNodes.first(where: \.isEffortPopup), { node in
                ClaudeReasoningAutomationService.effortRank(in: node.searchableText) != nil
            }),
            ("MODEL", closedNodes.first(where: \.isModelSelectorPopup), { node in
                let text = node.searchableText
                return text.contains("opus") || text.contains("sonnet") || text.contains("haiku")
            })
        ]
        for (label, node, rowMatches) in targets {
            guard let node else {
                report.append("")
                report.append("=== \(label) POPUP: not found ===")
                continue
            }
            let opened = await probeMenu(
                node,
                label: label,
                root: root,
                closedNodes: closedNodes,
                rowMatches: rowMatches,
                report: &report
            )
            probed.append("\(label): \(opened ?? AppLanguage.text("kein Weg gefunden", "no way found"))")
        }

        summary = ["Claude \(Self.claudeVersion(for: claude) ?? "?")"] + probed
        finish(report: report, status: AppLanguage.text(
            "Untersuchung abgeschlossen. Dump geschrieben.",
            "Inspection complete. Dump written."
        ))
    }

    /// Opens one pop-up button with each action it advertises and records what
    /// actually happened: the `AXExpanded` state transition, the nodes that
    /// appeared, and whether they carry a pressable row per effort level. This
    /// is the evidence the automation needs — `AXShowMenu` returning `.success`
    /// says nothing about whether an Electron popover mounted.
    private func probeMenu(
        _ node: Node,
        label: String,
        root: AXUIElement,
        closedNodes: [Node],
        rowMatches: (Node) -> Bool,
        report: inout Report
    ) async -> String? {
        report.append("")
        report.append("=== \(label) POPUP ===")
        report.append("  \(node.oneLine)")
        report.append("  attributes: \(node.allAttributes.joined(separator: ", "))")
        report.append("  AXExpanded before: \(Self.string("AXExpanded", of: node.element))")
        report.append("  AXPopupValue: \(Self.string("AXPopupValue", of: node.element))")
        report.append("  effortRank from title: \(ClaudeReasoningAutomationService.effortRank(in: node.searchableText).map(String.init) ?? "nil")")

        // Ordered cheapest/least intrusive first. Chromium answers `.success`
        // to an Accessibility action it then ignores, so every mechanism has to
        // be judged by the observed `AXExpanded` transition, never by its own
        // return code.
        let pid = Self.pid(of: node.element)
        for mechanism in Self.openMechanisms(for: node, pid: pid) {
            guard mechanism.isApplicable else {
                report.append("  \(mechanism.name): not applicable")
                continue
            }
            Self.dismissStrayMenus(root)
            try? await Task.sleep(nanoseconds: 200_000_000)

            report.append("")
            report.append("  --- \(mechanism.name) → \(mechanism.run()) ---")

            // Poll instead of sleeping once: the point is to learn how long
            // Claude actually needs before the menu is addressable.
            var expandedAfter = ""
            for step in 1...8 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                expandedAfter = Self.string("AXExpanded", of: node.element)
                report.append("    +\(step * 150)ms AXExpanded=\(expandedAfter.isEmpty ? "n/a" : expandedAfter) AXFocused=\(Self.string(kAXFocusedAttribute, of: node.element))")
                if expandedAfter == "1" { break }
            }

            let opened = Self.walk(root)
            // A grown node count is NOT proof: `AXShowMenu` mounts Chromium's
            // native "Kopieren / Alles auswählen" context menu, which grows the
            // tree by four nodes while the actual popover stays closed. Only an
            // expanded pop-up, or new rows that carry the levels this menu is
            // supposed to offer, count as mounted.
            let newRows = Self.newRows(in: opened, comparedTo: closedNodes)
            let matchingRows = newRows.filter(rowMatches)
            report.append("    node count \(closedNodes.count) → \(opened.count), new rows \(newRows.count), matching \(matchingRows.count)")
            let mounted = expandedAfter == "1" || matchingRows.count >= 2
            if mounted {
                report.appendMenuAnalysis(opened, closedNodes: closedNodes)
                report.appendSelectableRows(opened, closedNodes: closedNodes)
                report.appendFocus(root)
                await close(node, root: root, report: &report)
                return mechanism.name
            }
            report.append("    → nothing mounted")
            await close(node, root: root, report: &report)
        }
        Self.dismissStrayMenus(root)
        return nil
    }

    private struct OpenMechanism {
        let name: String
        let isApplicable: Bool
        let run: () -> String
    }

    /// The candidate ways to open a Chromium-hosted pop-up, from the ones that
    /// leave the machine untouched to the ones that need a real pointer event.
    /// `postToPid` keeps synthetic input inside Claude instead of injecting it
    /// wherever the user happens to be typing, and never moves the cursor.
    nonisolated private static func openMechanisms(for node: Node, pid: pid_t) -> [OpenMechanism] {
        let element = node.element
        return [
            OpenMechanism(name: "AXPress", isApplicable: node.actions.contains(kAXPressAction)) {
                "AXError \(AXUIElementPerformAction(element, kAXPressAction as CFString).rawValue)"
            },
            OpenMechanism(name: "AXShowMenu", isApplicable: node.actions.contains(kAXShowMenuAction)) {
                "AXError \(AXUIElementPerformAction(element, kAXShowMenuAction as CFString).rawValue)"
            },
            OpenMechanism(name: "AXFocused=true + Space→pid", isApplicable: node.allAttributes.contains(kAXFocusedAttribute)) {
                let focus = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                postKeyToPid(UInt16(kVK_Space), pid: pid)
                return "focus AXError \(focus.rawValue)"
            },
            OpenMechanism(name: "AXFocused=true + Return→pid", isApplicable: node.allAttributes.contains(kAXFocusedAttribute)) {
                let focus = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                postKeyToPid(UInt16(kVK_Return), pid: pid)
                return "focus AXError \(focus.rawValue)"
            },
            OpenMechanism(name: "synthetic click→pid", isApplicable: !node.frame.isEmpty) {
                postClickToPid(at: center(of: element), pid: pid)
                return "clicked at \(center(of: element))"
            }
        ]
    }

    /// Nodes present in the opened tree that were not there while closed.
    /// Compared by rendered description rather than element identity: Chromium
    /// hands out fresh `AXUIElement`s for the same node across queries.
    nonisolated private static func newRows(in opened: [Node], comparedTo closed: [Node]) -> [Node] {
        let closedKeys = Set(closed.map(\.oneLine))
        return opened.filter { !closedKeys.contains($0.oneLine) }
    }

    nonisolated private static func center(of element: AXUIElement) -> CGPoint {
        guard let positionValue = copyAttribute(kAXPositionAttribute, of: element),
              let sizeValue = copyAttribute(kAXSizeAttribute, of: element),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return .zero }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &origin)
        AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
        return CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }

    nonisolated private static func pid(of element: AXUIElement) -> pid_t {
        var value: pid_t = 0
        AXUIElementGetPid(element, &value)
        return value
    }

    nonisolated private static func postKeyToPid(_ keyCode: UInt16, pid: pid_t) {
        let source = CGEventSource(stateID: .privateState)
        CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)?.postToPid(pid)
        CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)?.postToPid(pid)
    }

    nonisolated private static func postClickToPid(at point: CGPoint, pid: pid_t) {
        let source = CGEventSource(stateID: .privateState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            )
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            event?.postToPid(pid)
        }
    }

    /// A native context menu left over from an `AXShowMenu` attempt would
    /// swallow every following mechanism, so each attempt starts from a clean
    /// window state.
    nonisolated private static func dismissStrayMenus(_ root: AXUIElement) {
        for window in elementArray(copyAttribute(kAXWindowsAttribute, of: root)) {
            for child in elementArray(copyAttribute(kAXChildrenAttribute, of: window))
            where string(kAXRoleAttribute, of: child) == kAXMenuRole {
                _ = AXUIElementPerformAction(child, kAXCancelAction as CFString)
            }
        }
    }

    /// Closing has to be verified too — a menu left open would swallow the
    /// next gesture. Records which mechanism actually collapsed the pop-up.
    private func close(_ node: Node, root: AXUIElement, report: inout Report) async {
        guard Self.string("AXExpanded", of: node.element) == "1" else { return }
        for mechanism in ["AXCancel-on-popup", "AXCancel-on-focus"] {
            switch mechanism {
            case "AXCancel-on-popup":
                _ = AXUIElementPerformAction(node.element, kAXCancelAction as CFString)
            default:
                Self.closeMenu(root)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            let expanded = Self.string("AXExpanded", of: node.element)
            report.append("    close via \(mechanism): AXExpanded=\(expanded.isEmpty ? "n/a" : expanded)")
            if expanded != "1" { return }
        }
    }

    private func finish(report: Report, status: String) {
        isRunning = false
        do {
            try FileManager.default.createDirectory(at: dumpDirectory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let url = dumpDirectory.appendingPathComponent("ClaudeAccessibility-\(stamp).txt")
            try Data(report.text.utf8).write(to: url, options: .atomic)
            lastDumpURL = url
            self.status = "\(status) → \(url.path)"
            logger.info("Claude AX dump written to \(url.path, privacy: .public)")
        } catch {
            self.status = AppLanguage.text(
                "\(status) (Datei konnte nicht geschrieben werden: \(error.localizedDescription))",
                "\(status) (the file could not be written: \(error.localizedDescription))"
            )
            logger.error("Claude AX dump could not be written: \(error.localizedDescription, privacy: .public)")
        }
    }

    func revealLastDump() {
        guard let lastDumpURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastDumpURL])
    }

    // MARK: - Tree walking

    /// Identity wrapper: the same Electron node is reachable through several
    /// relationships, so the walk must deduplicate or it explodes.
    private struct ElementKey: Hashable {
        let element: AXUIElement
        static func == (lhs: ElementKey, rhs: ElementKey) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    struct Node {
        let element: AXUIElement
        let depth: Int
        let path: String
        let role: String
        let subrole: String
        let roleDescription: String
        let title: String
        let describedValue: String
        let value: String
        let identifier: String
        let help: String
        let actions: [String]
        let isEnabled: Bool?
        let isSelected: Bool?
        let isFocused: Bool?
        let frame: String
        let allAttributes: [String]

        var searchableText: String {
            [title, describedValue, value, identifier, help, roleDescription]
                .joined(separator: " ")
                .lowercased()
        }

        var oneLine: String {
            var parts = ["\(role)"]
            if !subrole.isEmpty { parts.append("<\(subrole)>") }
            if !roleDescription.isEmpty { parts.append("rd=\u{201C}\(roleDescription)\u{201D}") }
            if !title.isEmpty { parts.append("title=\u{201C}\(title)\u{201D}") }
            if !describedValue.isEmpty { parts.append("desc=\u{201C}\(describedValue)\u{201D}") }
            if !value.isEmpty { parts.append("value=\u{201C}\(value)\u{201D}") }
            if !identifier.isEmpty { parts.append("id=\u{201C}\(identifier)\u{201D}") }
            if !help.isEmpty { parts.append("help=\u{201C}\(help)\u{201D}") }
            if !actions.isEmpty { parts.append("actions=[\(actions.joined(separator: ","))]") }
            if let isEnabled { parts.append("enabled=\(isEnabled)") }
            if let isSelected { parts.append("selected=\(isSelected)") }
            if let isFocused, isFocused { parts.append("FOCUSED") }
            if !frame.isEmpty { parts.append(frame) }
            return parts.joined(separator: " ")
        }

        /// Same predicate shape the automation uses, so the dump shows exactly
        /// which nodes the live matcher would pick and in which order.
        var looksLikeModelPopup: Bool {
            guard actions.contains(kAXPressAction)
                    || actions.contains(kAXShowMenuAction)
                    || role == kAXPopUpButtonRole
            else { return false }
            let text = searchableText
            return text.contains("modell") || text.contains("model")
                || text.contains("opus") || text.contains("sonnet") || text.contains("haiku")
        }

        /// Claude 1.24012 exposes the composer's effort control as a real
        /// `AXPopUpButton` whose title already carries the current level
        /// ("Aufwand: Hoch"). Requiring the pop-up role is what keeps sidebar
        /// chat rows and message bodies — which are only text — out.
        var isEffortPopup: Bool {
            guard role == kAXPopUpButtonRole else { return false }
            let text = searchableText
            guard !text.contains("weitere optionen"), !text.contains("more options") else { return false }
            return text.contains("aufwand") || text.contains("effort")
        }

        var isModelSelectorPopup: Bool {
            guard role == kAXPopUpButtonRole else { return false }
            let text = searchableText
            guard !text.contains("weitere optionen"), !text.contains("more options") else { return false }
            return text.contains("opus") || text.contains("sonnet") || text.contains("haiku")
        }

        var isMenuish: Bool {
            role.lowercased().contains("menu")
                || subrole.lowercased().contains("menu")
                || roleDescription.lowercased().contains("menu")
                || roleDescription.lowercased().contains("menü")
        }

        var mentionsEffort: Bool {
            ClaudeReasoningAutomationService.effortRank(in: searchableText) != nil
                || searchableText.contains("effort")
                || searchableText.contains("aufwand")
                || searchableText.contains("reasoning")
                || searchableText.contains("denk")
                || searchableText.contains("thinking")
        }
    }

    nonisolated private static func walk(_ root: AXUIElement) -> [Node] {
        var seen: Set<ElementKey> = []
        var result: [Node] = []
        var stack: [(AXUIElement, Int, String)] = [(root, 0, "root")]
        while let (element, depth, path) = stack.popLast(), result.count < nodeBudget {
            guard seen.insert(ElementKey(element: element)).inserted else { continue }
            let node = describe(element, depth: depth, path: path)
            result.append(node)
            guard depth < maximumDepth else { continue }
            let children = childElements(of: element)
            for (index, child) in children.enumerated().reversed() {
                stack.append((child, depth + 1, "\(path)/\(index)"))
            }
        }
        return result
    }

    nonisolated private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var seen: Set<ElementKey> = []
        for attribute in [
            kAXChildrenAttribute,
            kAXWindowsAttribute,
            "AXContents",
            "AXVisibleChildren",
            "AXChildrenInNavigationOrder",
            "AXRows",
            kAXMenuBarAttribute
        ] {
            for child in elementArray(copyAttribute(attribute, of: element)) where seen.insert(ElementKey(element: child)).inserted {
                result.append(child)
            }
        }
        return result
    }

    nonisolated private static func describe(_ element: AXUIElement, depth: Int, path: String) -> Node {
        var names: CFArray?
        let allAttributes = AXUIElementCopyAttributeNames(element, &names) == .success
            ? (names as? [String] ?? [])
            : []
        var actionNames: CFArray?
        let actions = AXUIElementCopyActionNames(element, &actionNames) == .success
            ? (actionNames as? [String] ?? [])
            : []
        return Node(
            element: element,
            depth: depth,
            path: path,
            role: string(kAXRoleAttribute, of: element),
            subrole: string(kAXSubroleAttribute, of: element),
            roleDescription: string(kAXRoleDescriptionAttribute, of: element),
            title: string(kAXTitleAttribute, of: element),
            describedValue: string(kAXDescriptionAttribute, of: element),
            value: string(kAXValueAttribute, of: element),
            identifier: string(kAXIdentifierAttribute, of: element),
            help: string(kAXHelpAttribute, of: element),
            actions: actions,
            isEnabled: bool(kAXEnabledAttribute, of: element),
            isSelected: bool(kAXSelectedAttribute, of: element),
            isFocused: bool(kAXFocusedAttribute, of: element),
            frame: frameDescription(of: element),
            allAttributes: allAttributes
        )
    }

    nonisolated private static func copyAttribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    nonisolated private static func string(_ name: String, of element: AXUIElement) -> String {
        guard let value = copyAttribute(name, of: element) else { return "" }
        if let text = value as? String { return text.replacingOccurrences(of: "\n", with: "\\n") }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    nonisolated private static func bool(_ name: String, of element: AXUIElement) -> Bool? {
        (copyAttribute(name, of: element) as? NSNumber)?.boolValue
    }

    nonisolated private static func frameDescription(of element: AXUIElement) -> String {
        guard let positionValue = copyAttribute(kAXPositionAttribute, of: element),
              let sizeValue = copyAttribute(kAXSizeAttribute, of: element),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return "" }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
        else { return "" }
        return String(format: "@(%.0f,%.0f %.0fx%.0f)", origin.x, origin.y, size.width, size.height)
    }

    nonisolated private static func elementArray(_ value: CFTypeRef?) -> [AXUIElement] {
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = unsafeDowncast(value, to: CFArray.self)
        return (0..<CFArrayGetCount(array)).compactMap { index in
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { return nil }
            let child = unsafeBitCast(pointer, to: AXUIElement.self)
            return CFGetTypeID(child) == AXUIElementGetTypeID() ? child : nil
        }
    }

    /// Escape is posted at the application, not globally, so a run cannot
    /// dismiss something in whatever app happens to be frontmost.
    nonisolated private static func closeMenu(_ root: AXUIElement) {
        guard let focused = copyAttribute(kAXFocusedUIElementAttribute, of: root),
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        _ = AXUIElementPerformAction(element, kAXCancelAction as CFString)
    }

    nonisolated private static func claudeVersion(for application: NSRunningApplication) -> String? {
        guard let url = application.bundleURL,
              let bundle = Bundle(url: url)
        else { return nil }
        return bundle.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    // MARK: - Report

    private struct Report {
        private(set) var text = ""

        mutating func append(_ line: String) {
            text += line
            text += "\n"
        }

        mutating func appendHeader(for application: NSRunningApplication) {
            append("Agent Micro · Claude Accessibility dump")
            append("generated: \(ISO8601DateFormatter().string(from: Date()))")
            append("Claude version: \(ClaudeAccessibilityInspector.claudeVersion(for: application) ?? "unknown")")
            append("Claude pid: \(application.processIdentifier)")
            append("bundle: \(application.bundleURL?.path ?? "unknown")")
        }

        mutating func appendPhase(_ name: String, nodes: [Node]) {
            append("")
            append("=== \(name) · \(nodes.count) nodes ===")
            for node in nodes where node.hasContent {
                append(String(repeating: "  ", count: min(node.depth, 40)) + "[\(node.path)] " + node.oneLine)
            }
        }

        /// Every real pop-up control in the app, so a future Claude release
        /// that renames or moves the effort selector can be diagnosed by
        /// comparing two dumps instead of by guessing.
        mutating func appendPopupInventory(_ nodes: [Node]) {
            let popups = nodes.filter { $0.role == kAXPopUpButtonRole }
            append("")
            append("=== POPUP BUTTON INVENTORY · \(popups.count) ===")
            for popup in popups {
                let marker = popup.isEffortPopup ? " <<< EFFORT" : popup.isModelSelectorPopup ? " <<< MODEL" : ""
                append("  [\(popup.path)] \(popup.oneLine)\(marker)")
            }
        }

        mutating func appendCandidates(_ candidates: [Node]) {
            append("")
            append("=== POPUP CANDIDATES (current matcher order) · \(candidates.count) ===")
            for (index, candidate) in candidates.enumerated() {
                append("  #\(index) \(candidate.oneLine)")
                append("     attributes: \(candidate.allAttributes.joined(separator: ", "))")
                append("     effortRank: \(ClaudeReasoningAutomationService.effortRank(in: candidate.searchableText).map(String.init) ?? "nil")")
            }
        }

        /// The nodes that only exist once the menu is open are the selection
        /// targets the automation should press directly.
        mutating func appendMenuAnalysis(_ opened: [Node], closedNodes: [Node]) {
            let closedPaths = Set(closedNodes.map(\.oneLine))
            let newNodes = opened.filter { !closedPaths.contains($0.oneLine) }
            append("")
            append("--- NEW NODES vs closed state · \(newNodes.count) ---")
            for node in newNodes where node.hasContent {
                append("  [\(node.path)] \(node.oneLine)")
                append("     attributes: \(node.allAttributes.joined(separator: ", "))")
            }
            let menuish = opened.filter(\.isMenuish)
            append("")
            append("--- MENU-ROLE NODES · \(menuish.count) ---")
            for node in menuish {
                append("  [\(node.path)] \(node.oneLine)")
            }
            let effort = opened.filter(\.mentionsEffort)
            append("")
            append("--- EFFORT-RELATED NODES · \(effort.count) ---")
            for node in effort {
                append("  [\(node.path)] \(node.oneLine)")
                append("     attributes: \(node.allAttributes.joined(separator: ", "))")
                append("     effortRank: \(ClaudeReasoningAutomationService.effortRank(in: node.searchableText).map(String.init) ?? "nil")")
            }
        }

        /// The rows the automation would press once the menu is open: every
        /// newly appeared node that is pressable and carries a recognizable
        /// effort or model label.
        mutating func appendSelectableRows(_ opened: [Node], closedNodes: [Node]) {
            let closedKeys = Set(closedNodes.map(\.oneLine))
            let rows = opened.filter { node in
                guard !closedKeys.contains(node.oneLine) else { return false }
                return node.actions.contains(kAXPressAction) || node.role == kAXMenuItemRole
            }
            append("")
            append("--- SELECTABLE NEW ROWS · \(rows.count) ---")
            for row in rows {
                let rank = ClaudeReasoningAutomationService.effortRank(in: row.searchableText)
                append("  [\(row.path)] rank=\(rank.map(String.init) ?? "nil") \(row.oneLine)")
                append("     attributes: \(row.allAttributes.joined(separator: ", "))")
            }
        }

        mutating func appendFocus(_ root: AXUIElement) {
            append("")
            append("--- FOCUS ---")
            guard let focused = ClaudeAccessibilityInspector.copyAttribute(kAXFocusedUIElementAttribute, of: root),
                  CFGetTypeID(focused) == AXUIElementGetTypeID()
            else {
                append("  AXFocusedUIElement: none")
                return
            }
            let element = unsafeDowncast(focused, to: AXUIElement.self)
            append("  AXFocusedUIElement: \(ClaudeAccessibilityInspector.describe(element, depth: 0, path: "focus").oneLine)")
        }
    }
}

private extension ClaudeAccessibilityInspector.Node {
    /// Electron emits a large number of empty layout wrappers. They carry no
    /// information for this purpose and would bury the meaningful rows.
    var hasContent: Bool {
        !title.isEmpty || !describedValue.isEmpty || !value.isEmpty
            || !identifier.isEmpty || !help.isEmpty || !actions.isEmpty
            || isMenuish || role == kAXPopUpButtonRole || role == kAXWindowRole
    }
}
