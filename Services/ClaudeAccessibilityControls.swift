import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Accessibility primitives for Claude Desktop's composer controls.
///
/// Everything here is derived from a live capture of Claude 1.24012.9 (see
/// `ClaudeAccessibilityInspector`, which writes the dump these rules were read
/// from). Three observations shape the whole design:
///
/// 1. Effort and model are **two separate `AXPopUpButton`s**, not one combined
///    menu. Matching them by text alone is unsafe — a sidebar conversation
///    titled "…Modellauswahl", or a chat message containing the word "Max",
///    matches just as well. Every lookup here is therefore role-guarded.
/// 2. Chromium answers `AXPress` with `.success` and then **ignores it**; the
///    pop-up never expands. `AXShowMenu` opens the unrelated native context
///    menu. The only mechanism that actually opens a pop-up is focusing it
///    through Accessibility and sending a real key to Claude's process.
/// 3. The opened effort pop-up is an `AXApplicationDialog` containing an
///    `AXSlider` that exposes `AXIncrement`/`AXDecrement` and carries the
///    current level in `AXValue`. That makes both the step and its
///    verification exact, with no key counting and no rank arithmetic.
enum ClaudeAccessibilityControls {
    /// Electron can stall a query while the renderer is busy; without this a
    /// single slow node would block the encoder's main-actor work.
    static let messagingTimeoutSeconds: Float = 1.5
    private static let nodeBudget = 30_000
    private static let maximumDepth = 120

    static func application(for pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeoutSeconds)
        return element
    }

    // MARK: - Lookup

    /// The composer's effort pop-up, e.g. `AXPopUpButton title="Aufwand: Hoch"`.
    /// The role guard is the important part: without it the first match is
    /// whatever conversation or message happens to mention the word.
    static func effortPopUp(in application: AXUIElement) -> AXUIElement? {
        firstDescendant(of: application) { element in
            isEffortPopUp(role: role(of: element), text: searchableText(of: element))
        }
    }

    /// The composer's model pop-up, e.g. `AXPopUpButton title="Opus 5"`.
    static func modelPopUp(in application: AXUIElement) -> AXUIElement? {
        firstDescendant(of: application) { element in
            isModelPopUp(role: role(of: element), text: searchableText(of: element))
        }
    }

    /// Role and text are matched together on purpose. Text alone is not a
    /// sufficient test: a chat message reading "Claude-Aufwand angepasst"
    /// contains the same word as the control, and a conversation titled
    /// "…Modellauswahl" contains the same word as the model selector. Both
    /// really did outrank the composer controls, which is how effort steps
    /// ended up being typed into the sidebar.
    static func isEffortPopUp(role: String, text: String) -> Bool {
        guard role == kAXPopUpButtonRole, !isForeignOptionsControl(text) else { return false }
        return text.contains("aufwand") || text.contains("effort")
    }

    static func isModelPopUp(role: String, text: String) -> Bool {
        guard role == kAXPopUpButtonRole, !isForeignOptionsControl(text) else { return false }
        return text.contains("opus") || text.contains("sonnet")
            || text.contains("haiku") || text.contains("fable")
    }

    /// Every conversation row carries a "Weitere Optionen für <title>" pop-up.
    /// Those are real pop-up buttons, so the role guard alone does not exclude
    /// them when the conversation happens to be named after a model.
    private static func isForeignOptionsControl(_ text: String) -> Bool {
        text.contains("weitere optionen") || text.contains("more options")
    }

    /// The slider inside the opened effort dialog. Only exists while the
    /// pop-up is expanded, which is exactly why its presence doubles as proof
    /// that the pop-up really opened.
    static func effortSlider(in application: AXUIElement) -> AXUIElement? {
        firstDescendant(of: application) { element in
            guard role(of: element) == kAXSliderRole else { return false }
            let text = searchableText(of: element)
            return text.contains("aufwand") || text.contains("effort")
        }
    }

    /// The rows of the opened model menu, in visual order.
    static func modelMenuItems(in application: AXUIElement) -> [AXUIElement] {
        descendants(of: application) { element in
            role(of: element) == kAXMenuItemRole && isEnabled(element) && hasArea(element)
        }
        .sorted { frame(of: $0).origin.y < frame(of: $1).origin.y }
    }

    // MARK: - State

    static func isExpanded(_ element: AXUIElement) -> Bool {
        (copyAttribute(kAXExpandedAttribute, of: element) as? NSNumber)?.boolValue == true
    }

    static func stringValue(of element: AXUIElement) -> String {
        string(kAXValueAttribute, of: element)
    }

    static func title(of element: AXUIElement) -> String {
        let title = string(kAXTitleAttribute, of: element)
        return title.isEmpty ? string(kAXDescriptionAttribute, of: element) : title
    }

    /// True while the element still answers Accessibility queries. Chromium
    /// hands out short-lived elements, so a cached reference has to be
    /// revalidated before it is used again.
    static func isAlive(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
    }

    // MARK: - Actions

    @discardableResult
    static func perform(_ action: String, on element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }

    static func focus(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// Keys go to Claude's process, never through the global event tap: a
    /// global post would land in whatever application the user is typing in if
    /// Claude lost focus between two encoder detents.
    static func postKey(_ keyCode: Int, to pid: pid_t) {
        let source = CGEventSource(stateID: .privateState)
        CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)?.postToPid(pid)
        CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)?.postToPid(pid)
    }

    // MARK: - Tree walking

    private struct ElementKey: Hashable {
        let element: AXUIElement
        static func == (lhs: ElementKey, rhs: ElementKey) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    static func firstDescendant(
        of root: AXUIElement,
        matching predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        walk(root) { predicate($0) ? .stop($0) : .continue }
    }

    static func descendants(
        of root: AXUIElement,
        matching predicate: (AXUIElement) -> Bool
    ) -> [AXUIElement] {
        var found: [AXUIElement] = []
        _ = walk(root) { element in
            if predicate(element) { found.append(element) }
            return .continue
        }
        return found
    }

    private enum Visit {
        case `continue`
        case stop(AXUIElement)
    }

    private static func walk(_ root: AXUIElement, _ visit: (AXUIElement) -> Visit) -> AXUIElement? {
        var seen: Set<ElementKey> = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var inspected = 0
        while let (element, depth) = stack.popLast(), inspected < nodeBudget {
            guard seen.insert(ElementKey(element: element)).inserted else { continue }
            inspected += 1
            if case let .stop(match) = visit(element) { return match }
            guard depth < maximumDepth else { continue }
            let children = childElements(of: element)
            for child in children.reversed() {
                stack.append((child, depth + 1))
            }
        }
        return nil
    }

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var seen: Set<ElementKey> = []
        // Claude has moved the composer controls between these relationships
        // across releases, so their union is queried rather than one of them.
        for attribute in [
            kAXChildrenAttribute,
            kAXWindowsAttribute,
            "AXContents",
            "AXVisibleChildren",
            "AXChildrenInNavigationOrder"
        ] {
            for child in elementArray(copyAttribute(attribute, of: element))
            where seen.insert(ElementKey(element: child)).inserted {
                result.append(child)
            }
        }
        return result
    }

    // MARK: - Attribute reading

    static func copyAttribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ name: String, of element: AXUIElement) -> String {
        guard let value = copyAttribute(name, of: element) else { return "" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func role(of element: AXUIElement) -> String {
        string(kAXRoleAttribute, of: element)
    }

    private static func isEnabled(_ element: AXUIElement) -> Bool {
        (copyAttribute(kAXEnabledAttribute, of: element) as? NSNumber)?.boolValue != false
    }

    /// Menu items that belong to a collapsed native menu report a zero frame.
    /// Filtering them out keeps Claude's own menu bar out of the model list.
    private static func hasArea(_ element: AXUIElement) -> Bool {
        let rect = frame(of: element)
        return rect.width > 0 && rect.height > 0
    }

    static func frame(of element: AXUIElement) -> CGRect {
        guard let positionValue = copyAttribute(kAXPositionAttribute, of: element),
              let sizeValue = copyAttribute(kAXSizeAttribute, of: element),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return .zero }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &origin)
        AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    static func searchableText(of element: AXUIElement) -> String {
        [
            string(kAXTitleAttribute, of: element),
            string(kAXDescriptionAttribute, of: element),
            string(kAXValueAttribute, of: element),
            string(kAXIdentifierAttribute, of: element)
        ]
        .joined(separator: " ")
        .lowercased()
    }

    private static func elementArray(_ value: CFTypeRef?) -> [AXUIElement] {
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = unsafeDowncast(value, to: CFArray.self)
        return (0..<CFArrayGetCount(array)).compactMap { index in
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { return nil }
            let child = unsafeBitCast(pointer, to: AXUIElement.self)
            return CFGetTypeID(child) == AXUIElementGetTypeID() ? child : nil
        }
    }
}
