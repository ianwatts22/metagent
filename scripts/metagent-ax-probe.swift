import AppKit
import ApplicationServices
import Foundation

private let maximumTraversalElements = 8_192
private let replacementSearchIntervalMilliseconds = 100.0
private let heartbeatIntervalMilliseconds = 1_000.0
private let reloadHelp = "Rescan skills, Doctor findings, and MCP configuration, and continue indexing session history"

private enum ProbeError: Error, CustomStringConvertible {
    case usage(String)
    case accessibility(String)
    case timeout(String)
    case state(String)

    var description: String {
        switch self {
        case let .usage(message), let .accessibility(message), let .timeout(message), let .state(message):
            return message
        }
    }
}

private struct MonotonicTimer {
    let started = DispatchTime.now().uptimeNanoseconds

    var elapsedMilliseconds: Double {
        Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    }
}

/// AppKit updates its running-application registry on the main run loop.
/// Sleeping or blocking on a semaphore alone leaves terminated PIDs cached.
/// Keep this outside the AX-gated probe so the real wait has headless tests.
@discardableResult
private func waitWithAppKitEvents(
    _ description: String,
    timeoutMilliseconds: Double,
    heartbeat: (String) -> Void = { _ in },
    predicate: () throws -> Bool
) throws -> Double {
    guard Thread.isMainThread else {
        throw ProbeError.state("AppKit lifecycle waits must run on the main thread.")
    }
    let timer = MonotonicTimer()
    var lastError: Error?
    while timer.elapsedMilliseconds <= timeoutMilliseconds {
        do {
            if try predicate() { return timer.elapsedMilliseconds }
            lastError = nil
        } catch {
            lastError = error
        }
        heartbeat(description)
        let remaining = (timeoutMilliseconds - timer.elapsedMilliseconds) / 1_000
        guard remaining > 0 else { break }
        let interval = min(0.01, remaining)
        let result = CFRunLoopRunInMode(.defaultMode, interval, true)
        if result == .finished {
            // A headless run loop may have no sources; do not busy-spin.
            Thread.sleep(forTimeInterval: interval)
        }
    }
    let detail = lastError.map { " Last bounded AX error: \($0)." } ?? ""
    throw ProbeError.timeout("Timed out after \(Int(timeoutMilliseconds))ms waiting for \(description).\(detail)")
}

private struct SortMeasurement {
    let elapsedMilliseconds: Double
    let direction: String
    let contentIdentifier: String
}

private struct FilterMeasurement {
    let totalMilliseconds: Double
    let pressCallMilliseconds: Double
    let controlReadyMilliseconds: Double
    let contentReadyMilliseconds: Double
}

private func monotonicMilliseconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
}

private func progress(_ message: String) {
    let data = Data("[metagent-perf] \(message)\n".utf8)
    FileHandle.standardError.write(data)
}

private func normalizedPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
}

private func axErrorName(_ error: AXError) -> String {
    switch error {
    case .success: return "success"
    case .failure: return "failure"
    case .illegalArgument: return "illegalArgument"
    case .invalidUIElement: return "invalidUIElement"
    case .invalidUIElementObserver: return "invalidUIElementObserver"
    case .cannotComplete: return "cannotComplete"
    case .attributeUnsupported: return "attributeUnsupported"
    case .actionUnsupported: return "actionUnsupported"
    case .notificationUnsupported: return "notificationUnsupported"
    case .notImplemented: return "notImplemented"
    case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
    case .notificationNotRegistered: return "notificationNotRegistered"
    case .apiDisabled: return "apiDisabled"
    case .noValue: return "noValue"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: return "notEnoughPrecision"
    @unknown default: return "unknown(\(error.rawValue))"
    }
}

private final class AccessibilityProbe {
    let appPath: String
    let expectedProcessName: String
    let timeoutMilliseconds: Double
    private let expectedExecutablePath: String
    private let callTimeoutSeconds: Float
    private var lastHeartbeatMilliseconds = 0.0

    init(appPath: String, processName: String, timeoutMilliseconds: Double) throws {
        self.appPath = normalizedPath(URL(fileURLWithPath: appPath))
        expectedProcessName = processName
        self.timeoutMilliseconds = timeoutMilliseconds
        expectedExecutablePath = normalizedPath(
            URL(fileURLWithPath: appPath).appendingPathComponent("Contents/MacOS/MetagentMenuBar")
        )
        callTimeoutSeconds = Float(min(1.0, max(0.1, timeoutMilliseconds / 10_000)))

        guard AXIsProcessTrusted() else {
            throw ProbeError.accessibility(
                "Accessibility access is not granted to this terminal/Codex host. Grant it in System Settings > Privacy & Security > Accessibility."
            )
        }
        let systemWide = AXUIElementCreateSystemWide()
        let timeoutError = AXUIElementSetMessagingTimeout(systemWide, callTimeoutSeconds)
        guard timeoutError == .success else {
            throw ProbeError.accessibility(
                "Could not set the process-wide Accessibility messaging timeout to \(callTimeoutSeconds)s: \(axErrorName(timeoutError))."
            )
        }
    }

    func contentReadyPrefix(_ section: String) -> String {
        section == "Overview"
            ? "metagent.overview.content.ready"
            : "metagent.\(section.lowercased()).content.ready."
    }

    func runningApplication(required: Bool = true) throws -> NSRunningApplication? {
        let matches = NSWorkspace.shared.runningApplications.filter { application in
            guard let bundleURL = application.bundleURL else { return false }
            return normalizedPath(bundleURL) == appPath
        }
        if matches.count > 1 {
            throw ProbeError.state(
                "Found \(matches.count) running processes from \(appPath); process identity is ambiguous. Stop duplicate instances and retry."
            )
        }
        guard let application = matches.first else {
            if required {
                throw ProbeError.state("No running app from the exact bundle path \(appPath) was found.")
            }
            return nil
        }
        guard let executableURL = application.executableURL else {
            throw ProbeError.state("PID \(application.processIdentifier) does not expose an executable path.")
        }
        let actualExecutable = normalizedPath(executableURL)
        guard actualExecutable == expectedExecutablePath else {
            throw ProbeError.state(
                "PID \(application.processIdentifier) came from \(actualExecutable), expected \(expectedExecutablePath)."
            )
        }
        if let localizedName = application.localizedName, localizedName != expectedProcessName {
            throw ProbeError.state(
                "PID \(application.processIdentifier) is named \(localizedName), expected \(expectedProcessName)."
            )
        }
        return application
    }

    func applicationElement(for application: NSRunningApplication) throws -> AXUIElement {
        let element = AXUIElementCreateApplication(application.processIdentifier)
        let error = AXUIElementSetMessagingTimeout(element, callTimeoutSeconds)
        guard error == .success else {
            throw ProbeError.accessibility(
                "Could not set the Accessibility timeout for PID \(application.processIdentifier): \(axErrorName(error))."
            )
        }
        return element
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) throws -> Any? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        switch error {
        case .success:
            return value
        case .noValue, .attributeUnsupported, .invalidUIElement:
            return nil
        default:
            throw ProbeError.accessibility(
                "AXUIElementCopyAttributeValue(\(attribute)) failed after a bounded call: \(axErrorName(error))."
            )
        }
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) throws -> String? {
        try copyAttribute(element, attribute) as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: String) throws -> Bool? {
        let raw = try copyAttribute(element, attribute)
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        return nil
    }

    private func children(_ element: AXUIElement) throws -> [AXUIElement] {
        try copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func role(_ element: AXUIElement) throws -> String? {
        try stringAttribute(element, kAXRoleAttribute)
    }

    private func identifier(_ element: AXUIElement) throws -> String? {
        try stringAttribute(element, kAXIdentifierAttribute)
    }

    private func title(_ element: AXUIElement) throws -> String? {
        try stringAttribute(element, kAXTitleAttribute)
    }

    private func value(_ element: AXUIElement) throws -> String? {
        guard let raw = try copyAttribute(element, kAXValueAttribute) else { return nil }
        return String(describing: raw)
    }

    private func actions(_ element: AXUIElement) throws -> [String] {
        var names: CFArray?
        let error = AXUIElementCopyActionNames(element, &names)
        switch error {
        case .success:
            return names as? [String] ?? []
        case .actionUnsupported, .invalidUIElement:
            return []
        default:
            throw ProbeError.accessibility(
                "AXUIElementCopyActionNames failed after a bounded call: \(axErrorName(error))."
            )
        }
    }

    private func hasPressAction(_ element: AXUIElement) throws -> Bool {
        try actions(element).contains(kAXPressAction)
    }

    private func performPress(_ element: AXUIElement, description: String) throws {
        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard error == .success else {
            throw ProbeError.accessibility(
                "Could not press \(description): \(axErrorName(error))."
            )
        }
    }

    private func heartbeat(_ description: String) {
        let now = monotonicMilliseconds()
        guard now - lastHeartbeatMilliseconds >= heartbeatIntervalMilliseconds else { return }
        progress("waiting for \(description)")
        lastHeartbeatMilliseconds = now
    }

    @discardableResult
    func waitUntil(
        _ description: String,
        timeout: Double? = nil,
        predicate: () throws -> Bool
    ) throws -> Double {
        try waitWithAppKitEvents(
            description,
            timeoutMilliseconds: timeout ?? timeoutMilliseconds,
            heartbeat: heartbeat,
            predicate: predicate
        )
    }

    func mainWindow(_ appElement: AXUIElement) throws -> AXUIElement {
        var result: AXUIElement?
        try waitUntil("the Metagent main window") {
            let windows = try self.copyAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []
            result = try windows.first { try self.title($0) == "Metagent" }
            return result != nil
        }
        guard let result else { throw ProbeError.state("Metagent window disappeared.") }
        return result
    }

    func findDescendant(
        of root: AXUIElement,
        maximumVisited: Int = maximumTraversalElements,
        matches: (AXUIElement) throws -> Bool
    ) throws -> AXUIElement? {
        var pending = [root]
        var cursor = 0
        while cursor < pending.count, cursor < maximumVisited {
            let current = pending[cursor]
            cursor += 1
            if try matches(current) { return current }
            pending.append(contentsOf: try children(current))
        }
        return nil
    }

    func findByIdentifier(_ root: AXUIElement, identifier expected: String) throws -> AXUIElement? {
        try findDescendant(of: root) { try self.identifier($0) == expected }
    }

    func findByIdentifierPrefix(_ root: AXUIElement, prefix: String) throws -> AXUIElement? {
        try findDescendant(of: root) { (try self.identifier($0))?.hasPrefix(prefix) == true }
    }

    func waitForIdentifier(_ root: AXUIElement, identifier: String) throws -> AXUIElement {
        var result: AXUIElement?
        try waitUntil("Accessibility identifier \(identifier)") {
            result = try self.findByIdentifier(root, identifier: identifier)
            return result != nil
        }
        guard let result else { throw ProbeError.state("Accessibility element \(identifier) disappeared.") }
        return result
    }

    func waitForIdentifierPrefix(_ root: AXUIElement, prefix: String) throws -> AXUIElement {
        var result: AXUIElement?
        try waitUntil("Accessibility identifier prefix \(prefix)") {
            result = try self.findByIdentifierPrefix(root, prefix: prefix)
            return result != nil
        }
        guard let result else { throw ProbeError.state("Accessibility prefix \(prefix) disappeared.") }
        return result
    }

    func navigationButton(_ window: AXUIElement, section: String) throws -> AXUIElement {
        try waitForIdentifier(window, identifier: "metagent.navigation.\(section.lowercased())")
    }

    func navigationButtonCount(_ window: AXUIElement) throws -> Int {
        var count = 0
        for section in ["overview", "skills", "mcps", "plugins", "projects", "history"] {
            if try findByIdentifier(window, identifier: "metagent.navigation.\(section)") != nil { count += 1 }
        }
        guard count >= 5 else {
            throw ProbeError.state("Only \(count) expected navigation controls were exposed; expected at least 5.")
        }
        return count
    }

    private func isSelected(_ element: AXUIElement) throws -> Bool {
        try boolAttribute(element, kAXSelectedAttribute) == true
    }

    func isTabSelected(window: AXUIElement, section: String) throws -> Bool {
        guard let button = try findByIdentifier(
            window,
            identifier: "metagent.navigation.\(section.lowercased())"
        ) else { return false }
        return try isSelected(button)
    }

    func selectTabToContentReady(
        window: AXUIElement,
        section: String
    ) throws -> (selected: Double, content: Double) {
        let button = try navigationButton(window, section: section)
        let timer = MonotonicTimer()
        try performPress(button, description: "\(section) navigation control")
        try waitUntil("\(section) selected state") {
            guard let current = try self.findByIdentifier(
                window,
                identifier: "metagent.navigation.\(section.lowercased())"
            ) else { return false }
            return try self.isSelected(current)
        }
        let selected = timer.elapsedMilliseconds
        _ = try waitForIdentifierPrefix(window, prefix: contentReadyPrefix(section))
        return (selected, timer.elapsedMilliseconds)
    }

    private func contentElement(_ window: AXUIElement, section: String) throws -> AXUIElement {
        try waitForIdentifierPrefix(window, prefix: contentReadyPrefix(section))
    }

    private func waitForContentChange(
        retained: AXUIElement,
        window: AXUIElement,
        section: String,
        previousIdentifier: String
    ) throws -> AXUIElement {
        let timer = MonotonicTimer()
        var result: AXUIElement?
        var nextReplacementSearch = replacementSearchIntervalMilliseconds
        try waitUntil("\(section) AX content-ready token to change") {
            let prefix = self.contentReadyPrefix(section)
            if let current = try self.identifier(retained), current.hasPrefix(prefix), current != previousIdentifier {
                result = retained
                return true
            }
            guard timer.elapsedMilliseconds >= nextReplacementSearch else { return false }
            nextReplacementSearch = timer.elapsedMilliseconds + replacementSearchIntervalMilliseconds
            if let replacement = try self.findByIdentifierPrefix(window, prefix: prefix),
               let current = try self.identifier(replacement), current != previousIdentifier {
                result = replacement
                return true
            }
            return false
        }
        guard let result else { throw ProbeError.state("\(section) content-ready element disappeared.") }
        return result
    }

    private func menuItem(_ appElement: AXUIElement, name: String) throws -> AXUIElement {
        var result: AXUIElement?
        try waitUntil("menu item \(name)") {
            result = try self.findDescendant(of: appElement) { element in
                try self.role(element) == kAXMenuItemRole && self.title(element) == name && self.hasPressAction(element)
            }
            return result != nil
        }
        guard let result else { throw ProbeError.state("Menu item \(name) disappeared.") }
        return result
    }

    func chooseMenuOption(
        appElement: AXUIElement,
        window: AXUIElement,
        section: String,
        controlIdentifier: String,
        option: String,
        expectedContentState: String,
        measured: Bool
    ) throws -> FilterMeasurement? {
        let control = try waitForIdentifier(window, identifier: controlIdentifier)
        if try value(control) == option { return nil }
        try performPress(control, description: "\(section) filter")
        let item = try menuItem(appElement, name: option)
        let content = try contentElement(window, section: section)
        guard let previous = try identifier(content) else {
            throw ProbeError.state("\(section) content-ready element has no AXIdentifier.")
        }
        let timer = MonotonicTimer()
        try performPress(item, description: "\(section) filter option \(option)")
        let pressCallMilliseconds = timer.elapsedMilliseconds
        var currentContent = content
        // A filter can replace a table with an empty-state container. Search
        // once immediately so the phase timestamp is not inflated by the
        // normal retry backoff, then keep later tree walks bounded.
        var nextReplacementSearch = 0.0
        var controlReadyMilliseconds: Double?
        var contentReadyMilliseconds: Double?
        try waitUntil("\(section) filter value and AX content-ready token \(option)") {
            guard let current = try self.findByIdentifier(
                window,
                identifier: controlIdentifier
            ) else { return false }
            let controlHasExpectedValue = try self.value(current) == option
            if controlHasExpectedValue, controlReadyMilliseconds == nil {
                controlReadyMilliseconds = timer.elapsedMilliseconds
            }

            let expectedPrefix = self.contentReadyPrefix(section)
                + expectedContentState + "."
            let retainedIdentifier = try self.identifier(currentContent)
            var contentHasExpectedState = retainedIdentifier != previous
                && retainedIdentifier?.hasPrefix(expectedPrefix) == true
            if !contentHasExpectedState {
                let elapsedMilliseconds = timer.elapsedMilliseconds
                if elapsedMilliseconds >= nextReplacementSearch {
                    nextReplacementSearch = elapsedMilliseconds
                        + replacementSearchIntervalMilliseconds
                    if let replacement = try self.findByIdentifierPrefix(
                        window,
                        prefix: self.contentReadyPrefix(section)
                    ) {
                        currentContent = replacement
                        let replacementIdentifier = try self.identifier(replacement)
                        contentHasExpectedState = replacementIdentifier != previous
                            && replacementIdentifier?.hasPrefix(expectedPrefix) == true
                    }
                }
            }
            if contentHasExpectedState, contentReadyMilliseconds == nil {
                contentReadyMilliseconds = timer.elapsedMilliseconds
            }
            return controlHasExpectedValue && contentHasExpectedState
        }
        guard measured else { return nil }
        guard let controlReadyMilliseconds, let contentReadyMilliseconds else {
            throw ProbeError.state("\(section) filter completed without phase observations.")
        }
        return FilterMeasurement(
            totalMilliseconds: timer.elapsedMilliseconds,
            pressCallMilliseconds: pressCallMilliseconds,
            controlReadyMilliseconds: controlReadyMilliseconds,
            contentReadyMilliseconds: contentReadyMilliseconds
        )
    }

    func normalizeSkillsSummary(window: AXUIElement) throws {
        let summary = try waitForIdentifier(window, identifier: "metagent.skills.view.summary")
        if try isSelected(summary) { return }
        let content = try contentElement(window, section: "Skills")
        guard let previous = try identifier(content) else {
            throw ProbeError.state("Skills content-ready element has no AXIdentifier.")
        }
        try performPress(summary, description: "Skills Summary view")
        try waitUntil("Skills Summary view selected state") {
            guard let current = try self.findByIdentifier(
                window,
                identifier: "metagent.skills.view.summary"
            ) else { return false }
            return try self.isSelected(current)
        }
        _ = try waitForContentChange(
            retained: content,
            window: window,
            section: "Skills",
            previousIdentifier: previous
        )
    }

    private func findSortableHeader(
        _ root: AXUIElement,
        name: String,
        maximumVisited: Int = 512
    ) throws -> AXUIElement? {
        var preferred = [root]
        var ordinary: [AXUIElement] = []
        var preferredCursor = 0
        var ordinaryCursor = 0
        var visited = 0
        while visited < maximumVisited,
              preferredCursor < preferred.count || ordinaryCursor < ordinary.count {
            let current: AXUIElement
            if preferredCursor < preferred.count {
                current = preferred[preferredCursor]
                preferredCursor += 1
            } else {
                current = ordinary[ordinaryCursor]
                ordinaryCursor += 1
            }
            visited += 1
            let currentRole = try role(current)
            if currentRole == kAXButtonRole,
               try title(current) == name,
               try hasPressAction(current) {
                return current
            }
            if currentRole == kAXRowRole { continue }
            let descendants = try children(current)
            for child in descendants.reversed() {
                let childRole = try role(child)
                if childRole == kAXButtonRole,
                   try title(child) == name,
                   try hasPressAction(child) {
                    return child
                }
                if childRole == kAXRowRole { continue }
                if [kAXGroupRole, kAXScrollAreaRole, kAXOutlineRole, kAXTableRole].contains(childRole ?? "") {
                    preferred.append(child)
                } else {
                    ordinary.append(child)
                }
            }
        }
        return nil
    }

    func sortDirection(window: AXUIElement, section: String, headerName: String) throws -> String {
        let content = try contentElement(window, section: section)
        guard let header = try findSortableHeader(content, name: headerName)
            ?? findSortableHeader(window, name: headerName)
        else {
            throw ProbeError.state("\(section) table header \(headerName) is not exposed with AXPress.")
        }
        guard let direction = try stringAttribute(header, kAXSortDirectionAttribute) else {
            throw ProbeError.state("\(section) table header \(headerName) has no AXSortDirection.")
        }
        return direction
    }

    func contentIdentifier(window: AXUIElement, section: String) throws -> String {
        let content = try contentElement(window, section: section)
        guard let identifier = try identifier(content) else {
            throw ProbeError.state("\(section) content-ready element has no AXIdentifier.")
        }
        return identifier
    }

    func measureSort(
        window: AXUIElement,
        section: String,
        headerName: String
    ) throws -> SortMeasurement {
        var content = try contentElement(window, section: section)
        var header = try findSortableHeader(content, name: headerName)
            ?? findSortableHeader(window, name: headerName)
        guard let initialHeader = header else {
            throw ProbeError.state("\(section) table header \(headerName) is not exposed with AXPress.")
        }
        header = initialHeader
        guard let previousIdentifier = try identifier(content) else {
            throw ProbeError.state("\(section) content-ready element has no AXIdentifier.")
        }
        guard let previousDirection = try stringAttribute(initialHeader, kAXSortDirectionAttribute) else {
            throw ProbeError.state("\(section) table header \(headerName) has no AXSortDirection.")
        }
        let timer = MonotonicTimer()
        try performPress(initialHeader, description: "\(section) \(headerName) sort header")
        var nextReplacementSearch = replacementSearchIntervalMilliseconds
        var completedDirection: String?
        var completedIdentifier: String?
        try waitUntil("\(section) sorted AX table content and direction to change") {
            if let currentIdentifier = try self.identifier(content),
               currentIdentifier.hasPrefix(self.contentReadyPrefix(section)),
               currentIdentifier != previousIdentifier,
               let currentHeader = header,
               let currentDirection = try self.stringAttribute(currentHeader, kAXSortDirectionAttribute),
               currentDirection != previousDirection {
                completedDirection = currentDirection
                completedIdentifier = currentIdentifier
                return true
            }
            guard timer.elapsedMilliseconds >= nextReplacementSearch else { return false }
            nextReplacementSearch = timer.elapsedMilliseconds + replacementSearchIntervalMilliseconds
            if let replacementContent = try self.findByIdentifierPrefix(
                window,
                prefix: self.contentReadyPrefix(section)
            ) {
                content = replacementContent
            }
            header = try self.findSortableHeader(content, name: headerName)
                ?? self.findSortableHeader(window, name: headerName)
            return false
        }
        guard let completedDirection, let completedIdentifier else {
            throw ProbeError.state("\(section) sort completed without observable state.")
        }
        return SortMeasurement(
            elapsedMilliseconds: timer.elapsedMilliseconds,
            direction: completedDirection,
            contentIdentifier: completedIdentifier
        )
    }

    func contentRole(window: AXUIElement, section: String) throws -> String? {
        try role(contentElement(window, section: section))
    }

    private func findReloadControl(_ window: AXUIElement) throws -> AXUIElement? {
        try findDescendant(of: window) { element in
            try self.role(element) == kAXButtonRole
                && self.stringAttribute(element, kAXHelpAttribute) == reloadHelp
        }
    }

    func measureRefresh(window: AXUIElement) throws -> Double {
        guard let control = try findReloadControl(window) else {
            throw ProbeError.state("Reload is not currently available; wait for existing app work to finish.")
        }
        let timer = MonotonicTimer()
        try performPress(control, description: "Reload")
        var transitionObserved = false
        try waitUntil("Reload to leave and return to its enabled ready state") {
            guard let current = try self.findReloadControl(window) else {
                transitionObserved = true
                return false
            }
            if try self.boolAttribute(current, kAXEnabledAttribute) != true {
                transitionObserved = true
                return false
            }
            return transitionObserved
        }
        guard transitionObserved else {
            throw ProbeError.state("Reload returned ready without an observed disabled/missing transition.")
        }
        return timer.elapsedMilliseconds
    }

    func terminate(_ application: NSRunningApplication) throws {
        guard application.terminate() else {
            throw ProbeError.state("PID \(application.processIdentifier) refused a normal terminate request.")
        }
        try waitUntil("\(expectedProcessName) to stop") {
            try self.runningApplication(required: false) == nil
        }
    }

    func launch() throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let completion = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var launchedApplication: NSRunningApplication?
        var launchError: Error?
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: appPath),
            configuration: configuration
        ) { application, error in
            lock.lock()
            launchedApplication = application
            launchError = error
            lock.unlock()
            completion.signal()
        }
        try waitUntil("NSWorkspace to launch \(expectedProcessName)") {
            completion.wait(timeout: .now()) == .success
        }
        lock.lock()
        let application = launchedApplication
        let error = launchError
        lock.unlock()
        if let error {
            throw ProbeError.state("NSWorkspace could not launch \(appPath): \(error.localizedDescription)")
        }
        guard let application else {
            throw ProbeError.state("NSWorkspace returned no app and no error while launching \(appPath).")
        }
        // Completion can arrive before AppKit publishes its registry update,
        // including when the completion semaphore was already signaled.
        var registeredApplication: NSRunningApplication?
        try waitUntil("exact launched process PID \(application.processIdentifier)") {
            guard let candidate = try self.runningApplication(required: false),
                  candidate.processIdentifier == application.processIdentifier
            else { return false }
            registeredApplication = candidate
            return true
        }
        guard let exact = registeredApplication else {
            throw ProbeError.state("Launch returned without an exact-path running process.")
        }
        return exact
    }
}

private func sample(
    metric: String,
    interaction: String,
    iteration: Int,
    value: Double,
    extra: [String: Any] = [:]
) -> [String: Any] {
    var result: [String: Any] = [
        "metric": metric,
        "interaction": interaction,
        "iteration": iteration,
        "value_ms": value,
    ]
    result.merge(extra) { _, new in new }
    return result
}

private func runTabs(
    probe: AccessibilityProbe,
    window: AXUIElement,
    iterations: Int
) throws -> [String: Any] {
    if try !probe.isTabSelected(window: window, section: "Overview") {
        _ = try probe.selectTabToContentReady(window: window, section: "Overview")
    }
    var samples: [[String: Any]] = []
    for iteration in 1...iterations {
        for destination in ["Skills", "MCPs", "Plugins", "Projects"] {
            progress("tabs \(iteration)/\(iterations): Overview to \(destination)")
            let forward = try probe.selectTabToContentReady(window: window, section: destination)
            let backward = try probe.selectTabToContentReady(window: window, section: "Overview")
            progress(
                "tabs \(iteration)/\(iterations): \(destination) round trip ready "
                    + "(\(Int(forward.content.rounded()))ms forward, \(Int(backward.content.rounded()))ms back)"
            )
            for (interaction, measurement) in [
                ("Overview to \(destination)", forward),
                ("\(destination) to Overview", backward),
            ] {
                samples.append(sample(
                    metric: "tab_input_to_selected_state_ms",
                    interaction: interaction,
                    iteration: iteration,
                    value: measurement.selected,
                    extra: ["selected_state_observed": true, "presentation_observed": false]
                ))
                samples.append(sample(
                    metric: "tab_input_to_ax_content_ready_ms",
                    interaction: interaction,
                    iteration: iteration,
                    value: measurement.content,
                    extra: [
                        "ax_content_ready_observed": true,
                        "presentation_observed": true,
                        "presentation_fidelity": "accessibility_content_ready",
                    ]
                ))
            }
        }
    }
    return [
        "navigation_button_count": try probe.navigationButtonCount(window),
        "samples": samples,
        "coverage_gaps": [
            "AX content-ready proves SwiftUI exposed the destination state through Accessibility; it does not observe the first painted or composited pixel."
        ],
    ]
}

private func runCommonInteractions(
    probe: AccessibilityProbe,
    appElement: AXUIElement,
    window: AXUIElement,
    iterations: Int
) throws -> [String: Any] {
    let tabResult = try runTabs(probe: probe, window: window, iterations: iterations)
    var samples = tabResult["samples"] as? [[String: Any]] ?? []
    var skippedSections: [[String: Any]] = []
    let filters = [
        (
            "Skills", "metagent.skills.usage-filter",
            (label: "All skills", state: "usage-all"),
            (label: "Observed", state: "usage-observed")
        ),
        (
            "MCPs", "metagent.mcps.status-filter",
            (label: "All", state: "filter-all"),
            (label: "Needs attention", state: "filter-attention")
        ),
        (
            "Plugins", "metagent.plugins.show-filter",
            (label: "All", state: "filter-all"),
            (label: "Manual updates", state: "filter-manual")
        ),
    ]
    for (section, identifier, baseline, alternate) in filters {
        _ = try probe.selectTabToContentReady(window: window, section: section)
        if section == "Skills" { try probe.normalizeSkillsSummary(window: window) }
        _ = try probe.chooseMenuOption(
            appElement: appElement,
            window: window,
            section: section,
            controlIdentifier: identifier,
            option: baseline.label,
            expectedContentState: baseline.state,
            measured: false
        )
        for iteration in 1...iterations {
            for option in [alternate, baseline] {
                progress("filters \(section) \(iteration)/\(iterations): \(option.label)")
                guard let measurement = try probe.chooseMenuOption(
                    appElement: appElement,
                    window: window,
                    section: section,
                    controlIdentifier: identifier,
                    option: option.label,
                    expectedContentState: option.state,
                    measured: true
                ) else {
                    throw ProbeError.state(
                        "\(section) filter did not leave \(option.label); the scenario cannot produce a truthful state transition."
                    )
                }
                samples.append(sample(
                    metric: "filter_input_to_ax_content_ready_ms",
                    interaction: "\(section) filter to \(option.label)",
                    iteration: iteration,
                    value: measurement.totalMilliseconds,
                    extra: [
                        "ax_content_ready_observed": true,
                        "presentation_observed": true,
                        "presentation_fidelity": "accessibility_content_ready",
                    ]
                ))
                samples.append(sample(
                    metric: "filter_ax_press_call_ms",
                    interaction: "\(section) filter to \(option.label)",
                    iteration: iteration,
                    value: measurement.pressCallMilliseconds,
                    extra: ["presentation_observed": false]
                ))
                samples.append(sample(
                    metric: "filter_press_return_to_control_state_ms",
                    interaction: "\(section) filter to \(option.label)",
                    iteration: iteration,
                    value: max(
                        0,
                        measurement.controlReadyMilliseconds
                            - measurement.pressCallMilliseconds
                    ),
                    extra: ["presentation_observed": false]
                ))
                samples.append(sample(
                    metric: "filter_press_return_to_semantic_content_ready_ms",
                    interaction: "\(section) filter to \(option.label)",
                    iteration: iteration,
                    value: max(
                        0,
                        measurement.contentReadyMilliseconds
                            - measurement.pressCallMilliseconds
                    ),
                    extra: [
                        "ax_content_ready_observed": true,
                        "presentation_observed": true,
                        "presentation_fidelity": "accessibility_content_ready",
                    ]
                ))
                progress(
                    "filters \(section) \(iteration)/\(iterations): \(option.label) ready "
                        + "(\(Int(measurement.totalMilliseconds.rounded()))ms total, "
                        + "\(Int(measurement.pressCallMilliseconds.rounded()))ms AXPress)"
                )
            }
        }
    }

    let sorts = [
        ("Skills", "Skill"),
        ("MCPs", "MCP"),
        ("Plugins", "Plugin"),
        ("Projects", "Project"),
    ]
    var observedSortSamples = 0
    for (section, header) in sorts {
        _ = try probe.selectTabToContentReady(window: window, section: section)
        if section == "Skills" { try probe.normalizeSkillsSummary(window: window) }
        let readyRole = try probe.contentRole(window: window, section: section)
        guard readyRole == kAXTableRole || readyRole == kAXOutlineRole else {
            skippedSections.append([
                "interaction": "sort",
                "section": section,
                "reason": "ready content role \(readyRole ?? "unknown") is neither AXTable nor AXOutline",
            ])
            continue
        }
        let preflightDirection = try probe.sortDirection(
            window: window,
            section: section,
            headerName: header
        )
        guard ["AXAscendingSortDirection", "AXDescendingSortDirection"]
            .contains(preflightDirection)
        else {
            skippedSections.append([
                "interaction": "sort",
                "section": section,
                "reason": "primary header \(header) is not the active sort; preserving retained user state",
            ])
            continue
        }
        for iteration in 1...iterations {
            let initialDirection = try probe.sortDirection(
                window: window,
                section: section,
                headerName: header
            )
            guard ["AXAscendingSortDirection", "AXDescendingSortDirection"]
                .contains(initialDirection)
            else { throw ProbeError.state("\(section) active primary sort changed during measurement.") }
            let initialContentIdentifier = try probe.contentIdentifier(
                window: window,
                section: section
            )
            var pair: [[String: Any]] = []
            for direction in ["toggle", "restore"] {
                progress("sorts \(section) \(iteration)/\(iterations): \(direction)")
                let measurement = try probe.measureSort(
                    window: window,
                    section: section,
                    headerName: header
                )
                if direction == "restore" {
                    guard measurement.direction == initialDirection,
                          measurement.contentIdentifier == initialContentIdentifier
                    else {
                        throw ProbeError.state(
                            "\(section) \(header) did not restore its complete initial sort presentation."
                        )
                    }
                }
                pair.append(sample(
                    metric: "sort_input_to_ax_content_ready_ms",
                    interaction: "\(section) \(header) \(direction)",
                    iteration: iteration,
                    value: measurement.elapsedMilliseconds,
                    extra: [
                        "ax_content_ready_observed": true,
                        "presentation_observed": true,
                        "presentation_fidelity": "accessibility_content_ready",
                    ]
                ))
                progress(
                    "sorts \(section) \(iteration)/\(iterations): \(direction) ready "
                        + "(\(Int(measurement.elapsedMilliseconds.rounded()))ms)"
                )
            }
            // Never publish a toggle without its successful restore.
            samples.append(contentsOf: pair)
            observedSortSamples += pair.count
        }
    }
    guard observedSortSamples > 0 else {
        let details = skippedSections.map {
            "\($0["section"] ?? "unknown"): \($0["reason"] ?? "unknown")"
        }.joined(separator: "; ")
        throw ProbeError.state(
            "Common interactions observed no real sortable AXTable/AXOutline transition. Fixture gap: \(details)."
        )
    }
    return [
        "navigation_button_count": try probe.navigationButtonCount(window),
        "samples": samples,
        "skipped_sections": skippedSections,
        "coverage_gaps": [
            "AX content-ready proves SwiftUI exposed the destination state through Accessibility; it does not observe the first painted or composited pixel."
        ] + skippedSections.map {
            "\($0["section"] ?? "unknown") sort skipped: \($0["reason"] ?? "unknown")."
        },
    ]
}

private func runSkillsCycle(
    probe: AccessibilityProbe,
    window: AXUIElement,
    iterations: Int
) throws -> [String: Any] {
    _ = try probe.selectTabToContentReady(window: window, section: "Overview")
    var samples: [[String: Any]] = []
    for iteration in 1...iterations {
        let forward = try probe.selectTabToContentReady(window: window, section: "Skills")
        try probe.normalizeSkillsSummary(window: window)
        _ = try probe.waitForIdentifierPrefix(window, prefix: probe.contentReadyPrefix("Skills"))
        Thread.sleep(forTimeInterval: 1)
        let backward = try probe.selectTabToContentReady(window: window, section: "Overview")
        samples.append(sample(
            metric: "skills_cycle_selected_state_ms",
            interaction: "Overview to Skills",
            iteration: iteration,
            value: forward.selected,
            extra: ["selected_state_observed": true, "presentation_observed": false]
        ))
        samples.append(sample(
            metric: "skills_cycle_selected_state_ms",
            interaction: "Skills to Overview",
            iteration: iteration,
            value: backward.selected,
            extra: ["selected_state_observed": true, "presentation_observed": false]
        ))
    }
    return [
        "navigation_button_count": try probe.navigationButtonCount(window),
        "samples": samples,
        "coverage_gaps": [
            "The Skills cycle observes the canonical Summary table through a stable Accessibility identifier, but does not scroll every lazy row into view."
        ],
    ]
}

private func runRefresh(
    probe: AccessibilityProbe,
    window: AXUIElement,
    iterations: Int
) throws -> [String: Any] {
    _ = try probe.selectTabToContentReady(window: window, section: "Overview")
    var samples: [[String: Any]] = []
    for iteration in 1...iterations {
        let elapsed = try probe.measureRefresh(window: window)
        samples.append(sample(
            metric: "manual_refresh_to_ready_ms",
            interaction: "Reload",
            iteration: iteration,
            value: elapsed,
            extra: [
                "ready_state_observed": true,
                "transition_observed": true,
                "presentation_observed": true,
            ]
        ))
    }
    return [
        "navigation_button_count": try probe.navigationButtonCount(window),
        "samples": samples,
        "coverage_gaps": [],
    ]
}

private func launchToNavigationReady(
    probe: AccessibilityProbe
) throws -> ([String: Double], Int, NSRunningApplication) {
    let timer = MonotonicTimer()
    let application = try probe.launch()
    let processReady = timer.elapsedMilliseconds
    let appElement = try probe.applicationElement(for: application)
    let window = try probe.mainWindow(appElement)
    let windowReady = max(processReady, timer.elapsedMilliseconds)
    _ = try probe.waitForIdentifier(window, identifier: "metagent.navigation.container")
    let navigationReady = max(windowReady, timer.elapsedMilliseconds)
    let count = try probe.navigationButtonCount(window)
    let diagnosticReady = max(navigationReady, timer.elapsedMilliseconds)
    return ([
        "process_ready_ms": processReady,
        "window_ready_ms": windowReady,
        "navigation_ready_ms": navigationReady,
        "diagnostic_ready_ms": diagnosticReady,
    ], count, application)
}

private func runLaunch(
    probe: AccessibilityProbe,
    scenario: String,
    iterations: Int
) throws -> [String: Any] {
    if scenario == "launch-cold", iterations != 1 {
        throw ProbeError.usage("launch-cold requires exactly one iteration; every later launch would be warm.")
    }
    if scenario == "launch-cold", try probe.runningApplication(required: false) != nil {
        throw ProbeError.state("\(probe.expectedProcessName) must be stopped before launch-cold.")
    }
    if scenario == "launch-warm" {
        if let running = try probe.runningApplication(required: false) { try probe.terminate(running) }
        let (_, _, warmup) = try launchToNavigationReady(probe: probe)
        try probe.terminate(warmup)
    }
    var samples: [[String: Any]] = []
    var navigationCount = 0
    for iteration in 1...iterations {
        let (phases, count, application) = try launchToNavigationReady(probe: probe)
        navigationCount = count
        let metric = scenario == "launch-warm"
            ? "warm_launch_to_navigation_ready_ms"
            : "cold_launch_to_navigation_ready_ms"
        var extra: [String: Any] = phases
        extra["navigation_ready_observed"] = true
        extra["presentation_observed"] = true
        extra["os_cache_state_controlled"] = false
        samples.append(sample(
            metric: metric,
            interaction: scenario,
            iteration: iteration,
            value: phases["navigation_ready_ms"] ?? 0,
            extra: extra
        ))
        if iteration < iterations { try probe.terminate(application) }
    }
    return [
        "navigation_button_count": navigationCount,
        "samples": samples,
        "coverage_gaps": [
            "The harness proves a stopped process reached an Accessibility-ready main window but cannot flush or prove macOS filesystem and dynamic-linker cache state."
        ],
    ]
}

private func run(arguments: [String]) throws -> [String: Any] {
    guard arguments.count == 5 else {
        throw ProbeError.usage("Expected app path, process name, scenario, iterations, and timeout milliseconds.")
    }
    let appPath = arguments[0]
    let processName = arguments[1]
    let scenario = arguments[2]
    guard let iterations = Int(arguments[3]), iterations > 0 else {
        throw ProbeError.usage("Iterations must be a positive integer.")
    }
    guard let timeout = Double(arguments[4]), timeout > 0 else {
        throw ProbeError.usage("Timeout milliseconds must be positive.")
    }
    let probe = try AccessibilityProbe(
        appPath: appPath,
        processName: processName,
        timeoutMilliseconds: timeout
    )
    let result: [String: Any]
    if scenario == "launch-warm" || scenario == "launch-cold" {
        result = try runLaunch(probe: probe, scenario: scenario, iterations: iterations)
    } else {
        guard let application = try probe.runningApplication() else {
            throw ProbeError.state("The exact app process is not running.")
        }
        let appElement = try probe.applicationElement(for: application)
        let window = try probe.mainWindow(appElement)
        switch scenario {
        case "tabs":
            result = try runTabs(probe: probe, window: window, iterations: iterations)
        case "common-interactions":
            result = try runCommonInteractions(
                probe: probe,
                appElement: appElement,
                window: window,
                iterations: iterations
            )
        case "skills-cycle":
            result = try runSkillsCycle(probe: probe, window: window, iterations: iterations)
        case "refresh":
            result = try runRefresh(probe: probe, window: window, iterations: iterations)
        default:
            throw ProbeError.usage("Unsupported interaction scenario: \(scenario)")
        }
    }
    return [
        "schema_version": 1,
        "scenario": scenario,
        "process_name": processName,
        // Keep the artifact contract stable; the driver records the native implementation.
        "automation": "macos_accessibility",
        "automation_driver": "native_swift_axui_element",
    ].merging(result) { _, new in new }
}

private func selfTest() throws {
    let timer = MonotonicTimer()
    Thread.sleep(forTimeInterval: 0.002)
    guard timer.elapsedMilliseconds > 0 else {
        throw ProbeError.state("Monotonic timer did not advance.")
    }
    let delivered = DispatchSemaphore(value: 0)
    RunLoop.main.perform(inModes: [.default]) { delivered.signal() }
    try waitWithAppKitEvents("queued main-run-loop callback", timeoutMilliseconds: 1_000) {
        delivered.wait(timeout: .now()) == .success
    }
    let deadlineTimer = MonotonicTimer()
    do {
        try waitWithAppKitEvents("false predicate", timeoutMilliseconds: 20) { false }
        throw ProbeError.state("A false predicate bypassed the wait deadline.")
    } catch ProbeError.timeout {
        guard deadlineTimer.elapsedMilliseconds >= 20,
              deadlineTimer.elapsedMilliseconds < 5_000
        else { throw ProbeError.state("The monotonic wait deadline was not respected.") }
    }
    let object: [String: Any] = ["schema_version": 1, "self_test": true]
    guard JSONSerialization.isValidJSONObject(object) else {
        throw ProbeError.state("JSON self-test payload is invalid.")
    }
    print("metagent-ax-probe self-test passed")
}

do {
    if CommandLine.arguments.dropFirst() == ["--self-test"] {
        try selfTest()
    } else {
        let result = try run(arguments: Array(CommandLine.arguments.dropFirst()))
        guard JSONSerialization.isValidJSONObject(result) else {
            throw ProbeError.state("Probe produced a non-JSON result.")
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
} catch {
    let data = Data("metagent-ax-probe: \(error)\n".utf8)
    FileHandle.standardError.write(data)
    exit(1)
}
