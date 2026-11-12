import SwiftUI
import Cocoa
import ApplicationServices
import ServiceManagement

let kGitHubRepoURL = "https://github.com/yweiss/column-select"

struct RowItem {
    let frame: CGRect
}

struct DragSnapshot {
    let finderPID: pid_t
    let rows: [RowItem]
    let clickX: CGFloat
    let anchorIndex: Int
    let desiredIndex: Int
    let appliedOffset: Int
    let generation: UInt64
}

final class ColumnSelectEngine: ObservableObject, @unchecked Sendable {
    private static let enabledPrefKey = "ColumnSelect.isEnabled"

    @Published var isEnabled: Bool = false
    @Published var launchAtLogin: Bool = false
    @Published var isAccessibilityGranted: Bool = false
    @Published var statusLine: String = "Ready — Drag whitespace in any Finder column"
    @Published var appleVerifiedFixedBug: Bool = false
    @Published var detectedOSVersionString: String = ""

    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var permissionTimer: Timer?
    private var hasRunLaunchProbe: Bool = false

    private let lock = NSLock()
    private var isMonitoringWhitespaceGesture: Bool = false
    private var hasCommittedMouseUp: Bool = false
    private var anchorPoint: CGPoint = .zero
    private var activeFinderPID: pid_t = 0
    private var dragRows: [RowItem] = []
    private var anchorIndex: Int = 0
    private var desiredIndex: Int = 0
    private var appliedOffset: Int = 0
    private var generation: UInt64 = 0

    private var trackedColumnFrame: CGRect? = nil
    private var trackedSelectedRange: ClosedRange<Int>? = nil

    private let ipcQueue = DispatchQueue(label: "com.local.ColumnSelect.Worker", qos: .userInteractive)

    init() {
        let ver = ProcessInfo.processInfo.operatingSystemVersion
        self.detectedOSVersionString = "macOS \(ver.majorVersion).\(ver.minorVersion)\(ver.patchVersion > 0 ? ".\(ver.patchVersion)" : "")"

        if UserDefaults.standard.object(forKey: Self.enabledPrefKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.enabledPrefKey)
        }

        let wantsEnabled = UserDefaults.standard.bool(forKey: Self.enabledPrefKey)
        let trusted = AXIsProcessTrusted()

        self.isAccessibilityGranted = trusted
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)

        if trusted && wantsEnabled {
            self.isEnabled = true
            startBackgroundTap()
        } else {
            self.isEnabled = false
        }

        // Probe Finder on launch to verify whether the Column View full-row hit-box bug still exists
        if trusted {
            ipcQueue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.probeFinderColumnViewBehavior()
            }
        }

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.syncStateWithSystem()
        }
    }

    /// Inspects an active Finder Column View window on launch to verify whether row whitespace
    /// is still captured by full-width row drag targets (bug present) or has been fixed by Apple.
    func probeFinderColumnViewBehavior() {
        guard AXIsProcessTrusted() else { return }
        guard let finder = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.finder" }) else {
            return
        }

        let appElement = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.1)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            return
        }

        // Locate an AXBrowser (Column View) and inspect its first visible column AXScrollArea
        for win in windows {
            var queue: [AXUIElement] = [win]
            var visited = 0
            var foundBrowser: AXUIElement?

            while !queue.isEmpty && visited < 120 {
                let node = queue.removeFirst()
                visited += 1
                if getStringAttribute(node, kAXRoleAttribute) == kAXBrowserRole {
                    foundBrowser = node
                    break
                }
                if let children = getChildren(node) {
                    queue.append(contentsOf: children)
                }
            }

            guard let browser = foundBrowser else { continue }

            // Find first non-empty column scroll area inside the browser
            var bQueue: [AXUIElement] = [browser]
            var bVisited = 0
            while !bQueue.isEmpty && bVisited < 120 {
                let node = bQueue.removeFirst()
                bVisited += 1
                if getStringAttribute(node, kAXRoleAttribute) == kAXScrollAreaRole,
                   let colFrame = getFrame(node), colFrame.width > 80 {

                    // Check rows inside this column
                    var rQueue: [AXUIElement] = [node]
                    var rVisited = 0
                    var fullWidthRows = 0
                    var shortLabelRows = 0

                    while !rQueue.isEmpty && rVisited < 80 {
                        let rNode = rQueue.removeFirst()
                        rVisited += 1
                        let role = getStringAttribute(rNode, kAXRoleAttribute) ?? ""
                        if role == kAXRowRole || role == kAXCellRole || role == kAXGroupRole {
                            if let f = getFrame(rNode), f.height >= 16.0 && f.height <= 48.0 {
                                if f.width >= colFrame.width * 0.65 {
                                    fullWidthRows += 1
                                } else if f.width > 20.0 && f.width < colFrame.width * 0.55 {
                                    shortLabelRows += 1
                                }
                            }
                        }
                        if let children = getChildren(rNode) {
                            rQueue.append(contentsOf: children)
                        }
                    }

                    // Only conclude Apple fixed it if we see a populated column where rows no longer
                    // span full column width AND hit-testing the right-side whitespace hits the scroll area directly
                    if fullWidthRows == 0 && shortLabelRows >= 2 {
                        let testX = Float(colFrame.maxX - 24.0)
                        let testY = Float(colFrame.minY + 36.0)
                        var hitEl: AXUIElement?
                        if AXUIElementCopyElementAtPosition(appElement, testX, testY, &hitEl) == .success,
                           let hit = hitEl,
                           getStringAttribute(hit, kAXRoleAttribute) == kAXScrollAreaRole {
                            DispatchQueue.main.async {
                                self.hasRunLaunchProbe = true
                                self.appleVerifiedFixedBug = true
                            }
                            return
                        }
                    } else if fullWidthRows > 0 {
                        // Confirmed bug is still present in Finder
                        DispatchQueue.main.async {
                            self.hasRunLaunchProbe = true
                            self.appleVerifiedFixedBug = false
                        }
                        return
                    }
                }
                if let children = getChildren(node) {
                    bQueue.append(contentsOf: children)
                }
            }
        }
    }

    func setUserEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledPrefKey)
        if enabled {
            if AXIsProcessTrusted() {
                isEnabled = true
                startBackgroundTap()
            } else {
                checkAccessibility(prompt: true)
            }
        } else {
            isEnabled = false
            stopBackgroundTap()
        }
    }

    private func syncStateWithSystem() {
        let trusted = AXIsProcessTrusted()
        let loginEnabled = (SMAppService.mainApp.status == .enabled)
        let wantsEnabled = UserDefaults.standard.bool(forKey: Self.enabledPrefKey)

        if trusted && !hasRunLaunchProbe {
            hasRunLaunchProbe = true
            ipcQueue.async { [weak self] in
                self?.probeFinderColumnViewBehavior()
            }
        }

        DispatchQueue.main.async {
            if self.isAccessibilityGranted != trusted {
                self.isAccessibilityGranted = trusted
            }
            if self.launchAtLogin != loginEnabled {
                self.launchAtLogin = loginEnabled
            }

            if trusted && wantsEnabled {
                if !self.isEnabled {
                    self.isEnabled = true
                }
                if self.tapThread == nil {
                    self.startBackgroundTap()
                }
            } else if !trusted && self.isEnabled {
                self.isEnabled = false
                self.stopBackgroundTap()
            }
        }
    }

    func openGitHub() {
        if let url = URL(string: kGitHubRepoURL) {
            NSWorkspace.shared.open(url)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.statusLine = "Login item error: \(error.localizedDescription)"
            }
        }
        syncStateWithSystem()
    }

    func moveAppToTrashAndQuit() {
        setUserEnabled(false)
        setLaunchAtLogin(false)
        let bundleURL = Bundle.main.bundleURL
        NSWorkspace.shared.recycle([bundleURL]) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    func checkAccessibility(prompt: Bool) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        syncStateWithSystem()
    }

    func openAccessibilitySettings() {
        checkAccessibility(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startBackgroundTap() {
        guard tapThread == nil else { return }
        guard AXIsProcessTrusted() else { return }

        let thread = Thread { [weak self] in
            guard let self = self else { return }
            let eventMask = (1 << CGEventType.leftMouseDown.rawValue) |
                            (1 << CGEventType.leftMouseDragged.rawValue) |
                            (1 << CGEventType.leftMouseUp.rawValue) |
                            (1 << CGEventType.keyDown.rawValue)

            let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(eventMask),
                callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                    let engine = Unmanaged<ColumnSelectEngine>.fromOpaque(refcon).takeUnretainedValue()
                    return engine.handleEvent(proxy: proxy, type: type, event: event)
                },
                userInfo: selfPtr
            ) else {
                DispatchQueue.main.async {
                    self.isEnabled = false
                    self.statusLine = "Failed to initialize event tap"
                }
                return
            }

            self.eventTap = tap
            let rl = CFRunLoopGetCurrent()
            self.tapRunLoop = rl
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "com.local.ColumnSelect.EventTap"
        thread.qualityOfService = .userInteractive
        self.tapThread = thread
        thread.start()
    }

    private func stopBackgroundTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let rl = tapRunLoop { CFRunLoopStop(rl) }
        eventTap = nil
        tapRunLoop = nil
        tapThread = nil
        resetGestureState(clearSelectionMemory: true)
    }

    private func resetGestureState(clearSelectionMemory: Bool = false) {
        lock.lock()
        isMonitoringWhitespaceGesture = false
        hasCommittedMouseUp = false
        dragRows = []
        appliedOffset = 0
        generation &+= 1
        if clearSelectionMemory {
            trackedColumnFrame = nil
            trackedSelectedRange = nil
        }
        lock.unlock()
    }

    private func updateStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusLine = text
        }
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == 0xF1ED {
            return Unmanaged.passUnretained(event)
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier == "com.apple.finder" else {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            lock.lock()
            trackedSelectedRange = nil
            lock.unlock()
            return Unmanaged.passUnretained(event)
        }

        let location = event.location
        let pid = frontApp.processIdentifier

        switch type {
        case .leftMouseDown:
            resetGestureState(clearSelectionMemory: false)

            let flags = event.flags
            if event.getIntegerValueField(.mouseEventClickState) > 1 ||
               flags.contains(.maskCommand) || flags.contains(.maskShift) {
                lock.lock()
                trackedSelectedRange = nil
                lock.unlock()
                return Unmanaged.passUnretained(event)
            }

            if let setup = prepareColumnSelection(at: location, pid: pid) {
                if setup.isAlreadySelectedRow {
                    updateStatus("Dragging selected file(s)")
                    return Unmanaged.passUnretained(event)
                }

                let initialRange = setup.anchorIndex...setup.anchorIndex
                lock.lock()
                isMonitoringWhitespaceGesture = true
                hasCommittedMouseUp = false
                anchorPoint = location
                activeFinderPID = pid
                dragRows = setup.rows
                anchorIndex = setup.anchorIndex
                desiredIndex = setup.anchorIndex
                appliedOffset = 0
                trackedColumnFrame = setup.columnFrame
                trackedSelectedRange = initialRange
                generation &+= 1
                lock.unlock()

                updateStatus("Selected \(setup.anchorName.prefix(18))")
                return Unmanaged.passUnretained(event)
            } else {
                lock.lock()
                trackedSelectedRange = nil
                lock.unlock()
            }

        case .leftMouseDragged:
            lock.lock()
            let active = isMonitoringWhitespaceGesture
            var needInitialMouseUp = false
            var savedAnchorPoint = anchorPoint
            var targetChanged = false
            var newCount = 1

            if active {
                if !hasCommittedMouseUp {
                    hasCommittedMouseUp = true
                    needInitialMouseUp = true
                }
                if !dragRows.isEmpty {
                    let targetIdx = Self.closestRowIndex(forY: location.y, in: dragRows, fallback: anchorIndex)
                    if targetIdx != desiredIndex {
                        desiredIndex = targetIdx
                        targetChanged = true
                        let lower = min(anchorIndex, targetIdx)
                        let upper = max(anchorIndex, targetIdx)
                        let range = lower...upper
                        trackedSelectedRange = range
                        newCount = range.count
                    }
                }
            }
            lock.unlock()

            if active {
                if needInitialMouseUp {
                    postSyntheticMouseUp(at: savedAnchorPoint)
                }
                if targetChanged {
                    scheduleCoalescedSync(clearAfter: false)
                    updateStatus("Selected \(newCount) items")
                }
                return nil
            }

        case .leftMouseUp:
            lock.lock()
            let wasActive = isMonitoringWhitespaceGesture
            let alreadyReleased = hasCommittedMouseUp
            let finalCount = abs(desiredIndex - anchorIndex) + 1
            if wasActive {
                isMonitoringWhitespaceGesture = false
            }
            lock.unlock()

            if wasActive {
                if !alreadyReleased {
                    resetGestureState(clearSelectionMemory: false)
                    return Unmanaged.passUnretained(event)
                } else {
                    scheduleCoalescedSync(clearAfter: true)
                    updateStatus("Selected \(finalCount) item(s)")
                    return nil
                }
            }

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private func postSyntheticMouseUp(at point: CGPoint) {
        if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.setIntegerValueField(.eventSourceUserData, value: 0xF1ED)
            up.post(tap: .cghidEventTap)
        }
    }

    private func scheduleCoalescedSync(clearAfter: Bool) {
        ipcQueue.async { [weak self] in
            guard let self = self else { return }

            self.lock.lock()
            let snapshot = DragSnapshot(
                finderPID: self.activeFinderPID,
                rows: self.dragRows,
                clickX: self.anchorPoint.x,
                anchorIndex: self.anchorIndex,
                desiredIndex: self.desiredIndex,
                appliedOffset: self.appliedOffset,
                generation: self.generation
            )
            self.lock.unlock()

            let targetOffset = snapshot.desiredIndex - snapshot.anchorIndex
            let delta = targetOffset - snapshot.appliedOffset

            if delta != 0 {
                let keyCode: CGKeyCode = delta > 0 ? 125 : 126
                let steps = abs(delta)
                let source = CGEventSource(stateID: .privateState)
                for _ in 0..<steps {
                    self.postShiftArrow(source: source, pid: snapshot.finderPID, keyCode: keyCode)
                }

                self.lock.lock()
                if self.generation == snapshot.generation {
                    self.appliedOffset = targetOffset
                }
                self.lock.unlock()
            }

            if clearAfter {
                self.resetGestureState(clearSelectionMemory: false)
            }
        }
    }

    private func postShiftArrow(source: CGEventSource?, pid: pid_t, keyCode: CGKeyCode) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = .maskShift
        up.flags = .maskShift
        down.setIntegerValueField(.eventSourceUserData, value: 0xF1ED)
        up.setIntegerValueField(.eventSourceUserData, value: 0xF1ED)
        down.postToPid(pid)
        up.postToPid(pid)
    }

    private struct DragSetup {
        let rows: [RowItem]
        let columnFrame: CGRect
        let anchorIndex: Int
        let anchorName: String
        let isAlreadySelectedRow: Bool
    }

    private func prepareColumnSelection(at point: CGPoint, pid: pid_t) -> DragSetup? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.04)

        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(appElement, Float(point.x), Float(point.y), &hitElement) == .success,
              let element = hitElement else {
            return nil
        }

        let role = getStringAttribute(element, kAXRoleAttribute) ?? ""
        if role == kAXImageRole || role == kAXButtonRole {
            updateStatus("On icon -> Normal file drag")
            return nil
        }

        var current: AXUIElement? = element
        var scrollArea: AXUIElement?
        var scrollFrame: CGRect?
        var inBrowser = false

        for _ in 0..<12 {
            guard let node = current else { break }
            let r = getStringAttribute(node, kAXRoleAttribute) ?? ""
            if r == kAXScrollAreaRole, scrollArea == nil {
                scrollArea = node
                scrollFrame = getFrame(node)
            }
            if r == kAXBrowserRole {
                inBrowser = true
                break
            }
            current = getParent(node)
        }

        guard inBrowser, let columnScroll = scrollArea, let colFrame = scrollFrame, colFrame.width > 0 else {
            return nil
        }

        if point.x > (colFrame.maxX - 16.0) {
            return nil
        }

        var candidateRows: [(element: AXUIElement, frame: CGRect)] = []
        var queue: [AXUIElement] = [columnScroll]
        var visited = 0
        let minRowWidth = colFrame.width * 0.65

        while !queue.isEmpty && visited < 180 {
            let node = queue.removeFirst()
            visited += 1
            let r = getStringAttribute(node, kAXRoleAttribute) ?? ""

            if r != kAXScrollAreaRole && r != kAXScrollBarRole && r != kAXImageRole && r != kAXStaticTextRole {
                if let f = getFrame(node), f.width >= minRowWidth, f.height >= 16.0, f.height <= 48.0 {
                    candidateRows.append((node, f))
                }
            }

            if let children = getChildren(node) {
                queue.append(contentsOf: children)
            }
        }

        var uniqueRows: [(element: AXUIElement, frame: CGRect)] = []
        for candidate in candidateRows {
            if let existingIdx = uniqueRows.firstIndex(where: { abs($0.frame.minY - candidate.frame.minY) < 2.0 }) {
                uniqueRows[existingIdx] = candidate
            } else {
                uniqueRows.append(candidate)
            }
        }
        uniqueRows.sort { $0.frame.minY < $1.frame.minY }

        guard let matchedIdx = uniqueRows.firstIndex(where: { point.y >= $0.frame.minY && point.y <= $0.frame.maxY }) else {
            updateStatus("Below file list -> Native marquee")
            return nil
        }

        lock.lock()
        let savedCol = trackedColumnFrame
        let savedRange = trackedSelectedRange
        lock.unlock()

        if let sCol = savedCol, let sRange = savedRange,
           abs(sCol.minX - colFrame.minX) < 4.0 && abs(sCol.width - colFrame.width) < 4.0,
           sRange.contains(matchedIdx) {
            let simplifiedRows = uniqueRows.map { RowItem(frame: $0.frame) }
            return DragSetup(
                rows: simplifiedRows,
                columnFrame: colFrame,
                anchorIndex: matchedIdx,
                anchorName: "",
                isAlreadySelectedRow: true
            )
        }

        let matched = uniqueRows[matchedIdx]
        let row = matched.element
        let rowFrame = matched.frame

        var filenameText = ""
        var textStartX: CGFloat = rowFrame.minX + 34.0
        var iconMaxX: CGFloat = rowFrame.minX + 28.0

        var rowQueue: [AXUIElement] = [row]
        var rowVisited = 0
        while !rowQueue.isEmpty && rowVisited < 20 {
            let node = rowQueue.removeFirst()
            rowVisited += 1
            let r = getStringAttribute(node, kAXRoleAttribute) ?? ""

            if r == kAXImageRole, let f = getFrame(node), f.width > 0 {
                iconMaxX = max(iconMaxX, f.maxX)
                textStartX = max(textStartX, f.maxX + 4.0)
            }

            if filenameText.isEmpty {
                for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel"] {
                    if let str = getStringAttribute(node, attr), !str.isEmpty {
                        filenameText = str
                        break
                    }
                }
            }

            if let children = getChildren(node) {
                rowQueue.append(contentsOf: children)
            }
        }

        let textEndX: CGFloat
        if !filenameText.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13.0)]
            let renderedWidth = ceil((filenameText as NSString).size(withAttributes: attrs).width)
            textEndX = textStartX + renderedWidth + 6.0
        } else {
            textEndX = max(iconMaxX + 8.0, rowFrame.minX + 90.0)
        }

        if point.x <= textEndX {
            updateStatus("On filename -> Normal file drag")
            return nil
        }

        let simplifiedRows = uniqueRows.map { RowItem(frame: $0.frame) }
        return DragSetup(
            rows: simplifiedRows,
            columnFrame: colFrame,
            anchorIndex: matchedIdx,
            anchorName: filenameText.isEmpty ? "item" : filenameText,
            isAlreadySelectedRow: false
        )
    }

    private static func closestRowIndex(forY y: CGFloat, in rows: [RowItem], fallback: Int) -> Int {
        if let first = rows.first, y <= first.frame.minY { return 0 }
        if let last = rows.last, y >= last.frame.maxY { return rows.count - 1 }

        for (idx, item) in rows.enumerated() {
            if y >= item.frame.minY && y <= item.frame.maxY {
                return idx
            }
        }

        var bestIdx = fallback
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (idx, item) in rows.enumerated() {
            let dist = abs(item.frame.midY - y)
            if dist < bestDist {
                bestDist = dist
                bestIdx = idx
            }
        }
        return bestIdx
    }

    private func getChildren(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private func getStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func getParent(_ element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success else { return nil }
        return (value as! AXUIElement)
    }

    private func getFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct ContentView: View {
    @ObservedObject var engine: ColumnSelectEngine

    var body: some View {
        VStack(spacing: 14) {
            if engine.appleVerifiedFixedBug {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Apple Fixed This Bug in \(engine.detectedOSVersionString)")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Finder Column View whitespace selection is working natively again. You can disable the login item, turn off Accessibility access, and trash this app.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack(spacing: 8) {
                        Button("Accessibility Settings") {
                            engine.openAccessibilitySettings()
                        }
                        .controlSize(.small)

                        Spacer()

                        Button("Disable & Trash App", role: .destructive) {
                            engine.moveAppToTrashAndQuit()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.14)))
            }

            HStack(spacing: 12) {
                if let appIcon = NSImage(named: NSImage.applicationIconName) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 48, height: 48)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Column Select")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Drag whitespace in Finder columns")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { engine.isEnabled },
                    set: { engine.setUserEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!engine.isAccessibilityGranted)
            }

            Divider()

            HStack {
                Text("Launch at Login")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { engine.launchAtLogin },
                    set: { engine.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }

            Divider()

            if engine.isAccessibilityGranted {
                HStack(spacing: 6) {
                    Circle()
                        .fill(engine.isEnabled ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(engine.isEnabled ? engine.statusLine : "Paused — Toggle switch above to enable")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        engine.openGitHub()
                    } label: {
                        HStack(spacing: 3) {
                            Text("GitHub")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.link)
                }
            } else {
                HStack {
                    Label("Accessibility permission required", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Grant Access") {
                        engine.openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(VisualEffectBackground())
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let engine = ColumnSelectEngine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        let contentView = ContentView(engine: engine)
        let hostingView = NSHostingView(rootView: contentView)
        let fittingSize = hostingView.fittingSize

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: fittingSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Column Select")
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "About Column Select", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())

        let githubItem = NSMenuItem(title: "Visit GitHub Repository…", action: #selector(openGitHubRepo), keyEquivalent: "g")
        githubItem.target = self
        appMenu.addItem(githubItem)

        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Column Select", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Column Select", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

        NSApp.mainMenu = mainMenu
    }

    @objc func openGitHubRepo() {
        engine.openGitHub()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
