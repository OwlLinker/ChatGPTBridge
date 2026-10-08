import AppKit
import ApplicationServices
import CryptoKit

private let nativeBundle = "com.openai.codex"
private let browserBundles: Set<String> = [
    "com.apple.Safari", "com.google.Chrome", "com.google.Chrome.beta",
    "com.google.Chrome.canary", "com.google.Chrome.dev", "org.chromium.Chromium",
    "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
    "company.thebrowser.Browser"
]
private let defaults = UserDefaults(suiteName: "org.chatgptbridge.monitor")!
private let hammerspoonDefaults = UserDefaults(suiteName: "org.hammerspoon.Hammerspoon")
private let hammerspoonCurrentStatusKey = "OwlLinkerHS.ChatGPTPatchMonitor.result"
private let hammerspoonPatchHistoryKey = "OwlLinkerHS.ChatGPTPatchMonitor.resultHistory"
private let hammerspoonConversationHistoryKey = "OwlLinkerHS.ChatGPTPatchMonitor.conversationResultHistory"
private let maxPatchBytes = 8 * 1024 * 1024
private let maxPatchDescendants = 512
private let lengthLimitMessage = "you've reached the maximum length for this conversation"

private func clipped(_ value: String, limit: Int) -> String {
    String(value.prefix(limit))
}

private func ax(_ element: AXUIElement, _ name: String) -> Any? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}

private func text(_ element: AXUIElement, role: String? = nil) -> String {
    let role = role ?? (ax(element, "AXRole") as? String ?? "")
    let attributes: [String]
    switch role {
    case "AXButton": attributes = ["AXTitle", "AXDescription", "AXHelp"]
    case "AXStaticText": attributes = ["AXValue", "AXTitle"]
    case "AXTextField", "AXTextArea": attributes = ["AXPlaceholderValue", "AXTitle", "AXDescription"]
    case "AXWebArea": attributes = ["AXTitle"]
    default: attributes = ["AXTitle"]
    }
    var parts: [String] = []
    for attribute in attributes {
        if let value = ax(element, attribute) as? String {
            if value.range(of: lengthLimitMessage, options: .caseInsensitive) != nil {
                return lengthLimitMessage
            }
            parts.append(clipped(value, limit: 512))
        }
    }
    return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func children(_ element: AXUIElement) -> [AXUIElement] {
    ax(element, "AXChildren") as? [AXUIElement] ?? []
}

private func isVisible(_ element: AXUIElement) -> Bool {
    (ax(element, "AXHidden") as? Bool) != true
}

private func axElement(_ value: Any?) -> AXUIElement? {
    guard let value else { return nil }
    let cfValue = value as CFTypeRef
    guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(cfValue, to: AXUIElement.self)
}

private func frame(_ element: AXUIElement) -> CGRect? {
    guard let rawPosition = ax(element, "AXPosition"),
          let rawSize = ax(element, "AXSize") else { return nil }
    let positionValue = rawPosition as CFTypeRef
    let sizeValue = rawSize as CFTypeRef
    guard CFGetTypeID(positionValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
    let p = unsafeBitCast(positionValue, to: AXValue.self)
    let s = unsafeBitCast(sizeValue, to: AXValue.self)
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(p, .cgPoint, &point),
          AXValueGetValue(s, .cgSize, &size),
          size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: point, size: size)
}

private func parameterized(_ element: AXUIElement, _ name: String, _ parameter: Any) -> Any? {
    var result: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
        element, name as CFString, parameter as CFTypeRef, &result
    ) == .success else { return nil }
    return result
}

private func matches(_ value: String, _ terms: [String]) -> Bool {
    let value = value.lowercased()
    return terms.contains { value.contains($0) }
}

private func buttonLabelMatches(_ value: String, _ terms: [String]) -> Bool {
    let normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    return terms.contains { term in
        normalized == term || normalized.hasPrefix(term + " ") ||
            normalized.hasPrefix(term + ",") || normalized.hasPrefix(term + ".")
    }
}

private func normalizedConversationTitle(_ value: String) -> String? {
    let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    guard !normalized.isEmpty, normalized.count <= 160,
          !["chatgpt", "new chat", "new conversation", "chat history", "open sidebar", "close sidebar"]
            .contains(normalized),
          !normalized.contains("said:"), !normalized.contains("generating"),
          !normalized.contains("stop generating") else { return nil }
    return normalized
}

private func hammerspoonRingStatus(_ status: String) -> String? {
    switch status {
    case "success": return "green"
    case "failure": return "red"
    case "monitoring": return "gold"
    default: return nil
    }
}

private func patchFingerprint(_ patch: String) -> String {
    var hash: UInt32 = 2_166_136_261
    let bytes = Array(patch.utf8)
    for byte in bytes { hash = (hash &* 16_777_619) &+ UInt32(byte) }
    return String(format: "%08x:%d", hash, bytes.count)
}

private let stopTerms = ["stop generating", "stop response", "stop streaming", "停止生成", "停止回答", "停止"]
private let sendTerms = ["send prompt", "send message", "send", "submit", "发送", "提交"]
private let workTerms = ["work with chatgpt", "start a task", "工作区", "开始任务"]

private struct ScanResult {
    let window: AXUIElement
    let pid: pid_t
    let bundle: String
    let conversationTitle: String?
    let sendButton: AXUIElement?
    let stopButton: AXUIElement?
    let composer: AXUIElement?
    let conversationKey: String
    let isWork: Bool
    let lengthLimitReached: Bool
    let hasConversation: Bool
    let latestDiff: String?
}

private enum TranscriptSpeaker {
    case assistant, user, unknown
}

private func transcriptSpeaker(_ label: String) -> TranscriptSpeaker {
    let value = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "：", with: ":")
    switch value {
    case "assistant said:", "chatgpt said:", "assistant:", "chatgpt 说:", "助手说:":
        return .assistant
    case "you said:", "user said:", "user:", "你说:", "用户说:":
        return .user
    default:
        return .unknown
    }
}

private enum GenerationTransition {
    case none, started, completed
}

private func generationTransition(from previous: Bool?, to current: Bool) -> GenerationTransition {
    if previous == false && current { return .started }
    if previous == true && !current { return .completed }
    return .none
}

private func isolatedPatchText(_ value: String) -> String? {
    guard value.utf8.count <= maxPatchBytes,
          value.contains("diff --git a/"), value.contains("+++ ") else { return nil }
    var headingCount = 0
    var containsOtherMessage = false
    value.enumerateLines { line, stop in
        let speaker = transcriptSpeaker(line)
        if speaker != .unknown {
            headingCount += 1
            if speaker == .user || headingCount > 1 {
                containsOtherMessage = true
                stop = true
            }
        }
    }
    guard !containsOtherMessage else { return nil }
    return value
}

private func patchText(near element: AXUIElement) -> String? {
    var current: AXUIElement? = element
    for _ in 0..<12 {
        guard let node = current else { break }
        let role = ax(node, "AXRole") as? String ?? ""
        if role == "AXStaticText" || role == "AXTextArea",
           let markerRange = parameterized(node, "AXTextMarkerRangeForUIElement", node),
           let markerText = parameterized(node, "AXStringForTextMarkerRange", markerRange) as? String,
           let patch = isolatedPatchText(markerText) {
            return patch
        }
        if role == "AXStaticText" || role == "AXTextArea",
           let direct = ax(node, "AXValue") as? String,
           let patch = isolatedPatchText(direct) { return patch }
        if role == "AXTextArea" || role == "AXGroup" {
            var lines: [String] = []
            var count = 0
            var capturedBytes = 0
            var overBudget = false
            var incomplete = false
            var headingCount = 0
            func gather(_ item: AXUIElement, _ depth: Int) {
                guard !overBudget, !incomplete else { return }
                guard isVisible(item) else { return }
                guard count < maxPatchDescendants else {
                    incomplete = true
                    return
                }
                count += 1
                let itemRole = ax(item, "AXRole") as? String ?? ""
                if itemRole == "AXHeading" || itemRole == "AXStaticText" {
                    let speaker = transcriptSpeaker(text(item, role: itemRole))
                    if speaker != .unknown {
                        headingCount += 1
                        if speaker == .user || headingCount > 1 {
                            incomplete = true
                            return
                        }
                    }
                }
                if itemRole == "AXStaticText" || itemRole == "AXTextArea",
                   let value = ax(item, "AXValue") as? String, !value.isEmpty {
                    let byteCount = value.utf8.count
                    guard byteCount <= maxPatchBytes - capturedBytes else {
                        overBudget = true
                        return
                    }
                    capturedBytes += byteCount
                    lines.append(value)
                }
                let descendants = children(item)
                if depth >= 7 {
                    incomplete = !descendants.isEmpty
                    return
                }
                for child in descendants {
                    gather(child, depth + 1)
                    if overBudget || incomplete { break }
                }
            }
            gather(node, 0)
            if !overBudget && !incomplete {
                let candidate = lines.joined(separator: "\n")
                if let patch = isolatedPatchText(candidate) { return patch }
            }
        }
        if role == "AXWebArea" || role == "AXScrollArea" { break }
        current = axElement(ax(node, "AXParent"))
    }
    return nil
}

private func scan(_ window: AXUIElement, bundle: String, pid: pid_t) -> ScanResult {
    let title = ax(window, "AXTitle") as? String ?? ""
    let document = ax(window, "AXDocument") as? String ?? ""
    let key = "\(bundle)|\(document.isEmpty ? title : document)"
    var send: AXUIElement?
    var stop: AXUIElement?
    var composer: AXUIElement?
    var isWork = matches("\(title) \(document)", ["/work/", "/codex/"]) ||
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "work with chatgpt"
    var lengthLimitReached = false
    var hasConversation = false
    var lastDiff: AXUIElement?
    var speaker = TranscriptSpeaker.unknown
    var visited = 0
    var truncated = false

    func walk(_ node: AXUIElement, _ depth: Int) {
        guard !lengthLimitReached, !truncated else { return }
        guard depth < 100, visited < 6000 else { truncated = true; return }
        visited += 1
        let nodeRole = ax(node, "AXRole") as? String ?? ""
        let nodeText = text(node, role: nodeRole)
        let lower = nodeText.lowercased()
        if lower.contains(lengthLimitMessage) {
            lengthLimitReached = true
            return
        }
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXPopUpButton"].contains(nodeRole) {
            let modeLabel = ["AXPlaceholderValue", "AXDescription", "AXTitle"]
                .compactMap { ax(node, $0) as? String }.joined(separator: " ")
            if matches(modeLabel, workTerms) { isWork = true }
        }
        let heading = transcriptSpeaker(lower)
        if heading != .unknown && isVisible(node) {
            hasConversation = true
            speaker = heading
            lastDiff = nil
        }
        if speaker == .assistant &&
            (lower == "diff" || lower == "unified diff" || lower == "patch" ||
             lower.hasPrefix("diff --git a/")) && isVisible(node) {
            lastDiff = node
        }

        if nodeRole == "AXButton" && isVisible(node) {
            if buttonLabelMatches(nodeText, stopTerms) { stop = node }
            else if buttonLabelMatches(nodeText, sendTerms) { send = node }
        }
        if ["AXTextArea", "AXTextField"].contains(nodeRole) && isVisible(node) {
            let placeholder = ["AXPlaceholderValue", "AXDescription", "AXTitle", "AXIdentifier"]
                .compactMap { ax(node, $0) as? String }.joined(separator: " ")
            if matches(placeholder, ["message", "ask anything", "回复", "发送消息", "prompt"]) {
                composer = node
            }
        }
        for child in children(node) {
            walk(child, depth + 1)
            if lengthLimitReached || truncated { return }
        }
    }
    walk(window, 0)
    let diff = !truncated && speaker == .assistant ? lastDiff.flatMap { patchText(near: $0) } : nil
    let verifiedBrowser = !browserBundles.contains(bundle) ||
        document.lowercased().contains("chatgpt.com") || document.lowercased().contains("chat.openai.com") ||
        title.lowercased().contains("chatgpt")
    return ScanResult(window: window, pid: pid, bundle: bundle,
                      conversationTitle: normalizedConversationTitle(title),
                      sendButton: send, stopButton: stop, composer: composer,
                      conversationKey: key, isWork: isWork || !verifiedBrowser,
                      lengthLimitReached: lengthLimitReached,
                      hasConversation: hasConversation && !truncated, latestDiff: diff)
}

private final class RingView: NSView {
    var color = NSColor(calibratedRed: 0.92, green: 0.66, blue: 0.16, alpha: 0.96)
    var visiblePulse = true
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard visiblePulse else { return }
        let rect = bounds.insetBy(dx: 3, dy: 3)
        color.setStroke()
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = 4
        path.stroke()
    }
}

private final class RingOverlay {
    private let window = NSWindow(contentRect: .zero, styleMask: .borderless,
                                  backing: .buffered, defer: false)
    private let ring = RingView(frame: .zero)
    private var pulseTimer: Timer?
    private var colorName = ""
    private var pulseOn = true

    init() {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = ring
        setColor("gold")
    }

    private func updatePulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseOn = true
        ring.visiblePulse = true
        guard colorName == "gold", window.isVisible else {
            ring.needsDisplay = true
            return
        }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pulseOn.toggle()
            self.ring.visiblePulse = self.pulseOn
            self.ring.needsDisplay = true
        }
        ring.needsDisplay = true
    }

    func setColor(_ name: String) {
        guard colorName != name else { return }
        colorName = name
        switch name {
        case "green": ring.color = NSColor(calibratedRed: 0.12, green: 0.78, blue: 0.37, alpha: 0.96)
        case "red": ring.color = NSColor(calibratedRed: 0.92, green: 0.20, blue: 0.22, alpha: 0.96)
        default: ring.color = NSColor(calibratedRed: 0.92, green: 0.66, blue: 0.16, alpha: 0.96)
        }
        updatePulse()
    }

    func show(around axFrame: CGRect) {
        guard let screen = NSScreen.screens.first else { return }
        let diameter = max(axFrame.width, axFrame.height) + 12
        let centerX = axFrame.midX
        let centerY = screen.frame.maxY - axFrame.midY
        let frame = CGRect(x: centerX - diameter / 2, y: centerY - diameter / 2,
                           width: diameter, height: diameter)
        if window.frame != frame { window.setFrame(frame, display: true) }
        if !window.isVisible {
            window.orderFrontRegardless()
            updatePulse()
        }
    }

    func hide() {
        guard window.isVisible else { return }
        window.orderOut(nil)
        updatePulse()
    }
}

private final class Monitor: NSObject {
    private static let logDateFormatter = ISO8601DateFormatter()
    private let bridgeRoot: String
    private let defaultsPrefix: String
    private let overlay = RingOverlay()
    private var timer: Timer?
    private var cached: ScanResult?
    private var lastRefresh = Date.distantPast
    private var nextControlRetry = Date.distantPast
    private var lastWindowKey = ""
    private var previousGenerating: Bool?
    private var applying = false
    private var foregroundBundle: String?
    private var activeConversationKey: String?
    private var previousConversationKey: String?
    private var generationEpoch: [String: Int] = [:]
    private var pendingDiffHashes: [String: String] = [:]
    private var pendingDiffAttempts: [String: Int] = [:]
    private var queuedPatch: (text: String, conversation: String)?
    private var observedButtons: [pid_t: AXUIElement] = [:]
    private var observedApplications: [pid_t: AXUIElement] = [:]
    private var lastToastAt = Date.distantPast
    private var observers: [pid_t: AXObserver] = [:]
    private var observedWindows: [pid_t: AXUIElement] = [:]
    private var needsRefresh = false
    private let refreshLock = NSLock()
    private var refreshQueued = false

    init(root: String) {
        bridgeRoot = root
        let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        let rootDigest = SHA256.hash(data: Data(normalizedRoot.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16)
        defaultsPrefix = "project.\(rootDigest)"
        super.init()
    }

    private func defaultsKey(_ name: String) -> String {
        "\(defaultsPrefix).\(name)"
    }

    func start() -> Bool {
        let permissionOptions = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        guard AXIsProcessTrustedWithOptions(permissionOptions) else {
            log("需要在系统设置 → 隐私与安全性 → 辅助功能中授权当前 chat-monitor 程序，然后重新启动监控")
            return false
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appChanged(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appChanged(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appChanged(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        log("原生监控已启动")
        tick(force: true)
        return true
    }

    @objc private func appChanged(_ notification: Notification) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if notification.name == NSWorkspace.didLaunchApplicationNotification ||
            notification.name == NSWorkspace.didTerminateApplicationNotification {
            let changed = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let bundle = changed?.bundleIdentifier,
                  bundle == nativeBundle || browserBundles.contains(bundle) else { return }
        }
        foregroundBundle = front
        if front != nativeBundle && !browserBundles.contains(front ?? "") { overlay.hide() }
        tick(force: true)
    }

    fileprivate func accessibilityChanged() {
        refreshLock.lock()
        guard !refreshQueued else { refreshLock.unlock(); return }
        refreshQueued = true
        refreshLock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.needsRefresh = true
            self.refreshLock.lock()
            self.refreshQueued = false
            self.refreshLock.unlock()
        }
    }

    private func observe(_ element: AXUIElement, pid: pid_t, notifications: [String]) {
        if observers[pid] == nil {
            var observer: AXObserver?
            let result = AXObserverCreate(pid, monitorAXCallback, &observer)
            guard result == .success, let observer else { return }
            observers[pid] = observer
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        guard let observer = observers[pid] else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for notification in notifications {
            _ = AXObserverAddNotification(observer, element, notification as CFString, context)
        }
    }

    private func observeApplication(_ element: AXUIElement, pid: pid_t) {
        if let previous = observedApplications[pid] {
            if CFEqual(previous, element) { return }
            if let observer = observers[pid] {
                _ = AXObserverRemoveNotification(observer, previous,
                                                 kAXFocusedWindowChangedNotification as CFString)
                _ = AXObserverRemoveNotification(observer, previous,
                                                 kAXWindowCreatedNotification as CFString)
            }
        }
        observedApplications[pid] = element
        observe(element, pid: pid,
                notifications: [kAXFocusedWindowChangedNotification as String,
                                kAXWindowCreatedNotification as String])
    }

    private func log(_ message: String) {
        let line = "[ChatGPTBridge Monitor] \(Self.logDateFormatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: bridgeRoot).appendingPathComponent(".chatgpt/chat-monitor.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
           size > 1_000_000 {
            try? Data().write(to: url, options: .atomic)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else { try? data.write(to: url, options: .atomic) }
    }

    private func tick(force requestedForce: Bool = false) {
        var force = requestedForce || needsRefresh
        needsRefresh = false
        let frontApp = NSWorkspace.shared.frontmostApplication
        let front = frontApp?.bundleIdentifier
        if front != foregroundBundle {
            foregroundBundle = front
            if front == nativeBundle || browserBundles.contains(front ?? "") { force = true }
            else { overlay.hide() }
        }
        let currentTime = Date()
        var selected: ScanResult?
        if let previous = cached {
            let buttonState = currentButton(in: previous)?.0
            let title = ax(previous.window, "AXTitle") as? String ?? ""
            let document = ax(previous.window, "AXDocument") as? String ?? ""
            let key = "\(previous.bundle)|\(previous.pid)|\(document)|\(title)"
            let workComposer = previous.composer.map { matches(text($0), workTerms) } ?? false
            let fallback: TimeInterval = browserBundles.contains(previous.bundle)
                ? (previousGenerating == true ? 30 : 60)
                : (previousGenerating == true ? 15 : 30)
            let stable = buttonState != nil && buttonState == previousGenerating &&
                currentTime.timeIntervalSince(lastRefresh) < fallback
            let waitingForControl = previousGenerating == nil &&
                currentTime < nextControlRetry
            if !force, key == lastWindowKey, !workComposer,
               stable || waitingForControl {
                selected = previous
            }
        }
        if selected == nil && (force || cached != nil ||
                               currentTime.timeIntervalSince(lastRefresh) >= 10) {
            lastRefresh = currentTime
            let running = NSWorkspace.shared.runningApplications.filter {
                guard let id = $0.bundleIdentifier else { return false }
                return id == nativeBundle || browserBundles.contains(id)
            }.sorted { left, right in
                let leftIsFront = left.processIdentifier == frontApp?.processIdentifier
                let rightIsFront = right.processIdentifier == frontApp?.processIdentifier
                if leftIsFront != rightIsFront { return leftIsFront }
                return left.processIdentifier < right.processIdentifier
            }
            let runningPIDs = Set(running.map(\.processIdentifier))
            for pid in Array(observers.keys) where !runningPIDs.contains(pid) {
                if let observer = observers.removeValue(forKey: pid) {
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                }
                observedApplications[pid] = nil
                observedButtons[pid] = nil
                observedWindows[pid] = nil
            }
            for app in running {
                let bundle = app.bundleIdentifier ?? ""
                let pid = app.processIdentifier
                let appElement = AXUIElementCreateApplication(pid)
                var windows = (ax(appElement, "AXWindows") as? [AXUIElement]) ?? []
                if let focused = axElement(ax(appElement, "AXFocusedWindow")) {
                    windows.removeAll { CFEqual($0, focused) }
                    windows.insert(focused, at: 0)
                }
                observeApplication(appElement, pid: pid)
                for window in windows {
                    let title = ax(window, "AXTitle") as? String ?? ""
                    let document = ax(window, "AXDocument") as? String ?? ""
                    let verified = bundle == nativeBundle ||
                        document.lowercased().contains("chatgpt.com") ||
                        document.lowercased().contains("chat.openai.com") ||
                        title.lowercased().contains("chatgpt")
                    guard verified else { continue }
                    let result = scan(window, bundle: bundle, pid: pid)
                    observeWindow(window, pid: pid)
                    guard !result.isWork, !result.lengthLimitReached,
                          result.hasConversation else {
                        clearObservedButton(pid: pid)
                        continue
                    }
                    if let button = result.stopButton ?? result.sendButton {
                        observeButton(button, pid: pid)
                    } else {
                        clearObservedButton(pid: pid)
                    }
                    lastWindowKey = "\(bundle)|\(pid)|\(document)|\(title)"
                    cached = result
                    selected = result
                    break
                }
                if selected != nil { break }
            }
        }

        guard let info = selected, !info.isWork, !info.lengthLimitReached, info.hasConversation,
              let (isGenerating, button) = currentButton(in: info),
              let buttonFrame = frame(button) else {
            overlay.hide()
            previousGenerating = nil
            activeConversationKey = nil
            nextControlRetry = Date().addingTimeInterval(5)
            if selected == nil { cached = nil; lastWindowKey = "" }
            return
        }
        nextControlRetry = .distantPast

        if previousConversationKey != info.conversationKey {
            previousConversationKey = info.conversationKey
            previousGenerating = nil
        }
        activeConversationKey = info.conversationKey

        let transition = generationTransition(from: previousGenerating, to: isGenerating)
        if previousGenerating == nil {
            if isGenerating {
                setStatus("gold", for: info.conversationKey)
            } else {
                restoreHammerspoonStatus(for: info)
            }
        } else if transition == .started {
            generationEpoch[info.conversationKey, default: 0] += 1
            pendingDiffHashes[info.conversationKey] = nil
            pendingDiffAttempts[info.conversationKey] = nil
            setStatus("gold", for: info.conversationKey)
        } else if transition == .completed {
            if let diff = info.latestDiff { confirmDiff(diff, conversation: info.conversationKey) }
            else { scheduleDiffRetry(conversation: info.conversationKey) }
        }
        previousGenerating = isGenerating

        let status = statusFor(info.conversationKey)
        overlay.setColor(status)
        if frontApp?.processIdentifier == info.pid,
           let focused = axElement(ax(AXUIElementCreateApplication(info.pid), "AXFocusedWindow")),
           CFEqual(focused, info.window) {
            overlay.show(around: buttonFrame)
        } else { overlay.hide() }
    }

    private func currentButton(in info: ScanResult) -> (Bool, AXUIElement)? {
        for button in [info.stopButton, info.sendButton].compactMap({ $0 }) {
            guard isVisible(button) else { continue }
            let label = text(button)
            if buttonLabelMatches(label, stopTerms) { return (true, button) }
            if buttonLabelMatches(label, sendTerms) { return (false, button) }
        }
        return nil
    }

    private func observeButton(_ button: AXUIElement, pid: pid_t) {
        if let previous = observedButtons[pid], CFEqual(previous, button) { return }
        if let previous = observedButtons[pid], !CFEqual(previous, button), let observer = observers[pid] {
            _ = AXObserverRemoveNotification(observer, previous, kAXValueChangedNotification as CFString)
            _ = AXObserverRemoveNotification(observer, previous, kAXTitleChangedNotification as CFString)
        }
        observedButtons[pid] = button
        observe(button, pid: pid,
                notifications: [kAXValueChangedNotification as String,
                                kAXTitleChangedNotification as String])
    }

    private func clearObservedButton(pid: pid_t) {
        guard let previous = observedButtons.removeValue(forKey: pid),
              let observer = observers[pid] else { return }
        _ = AXObserverRemoveNotification(observer, previous, kAXValueChangedNotification as CFString)
        _ = AXObserverRemoveNotification(observer, previous, kAXTitleChangedNotification as CFString)
    }

    private func observeWindow(_ window: AXUIElement, pid: pid_t) {
        if let previous = observedWindows[pid], CFEqual(previous, window) { return }
        if let previous = observedWindows[pid], !CFEqual(previous, window), let observer = observers[pid] {
            _ = AXObserverRemoveNotification(observer, previous, kAXFocusedUIElementChangedNotification as CFString)
        }
        observedWindows[pid] = window
        observe(window, pid: pid, notifications: [kAXFocusedUIElementChangedNotification as String])
    }

    private func statusFor(_ key: String) -> String {
        (defaults.dictionary(forKey: defaultsKey("conversationStatus")) as? [String: String])?[key] ?? "gold"
    }

    private func restoreHammerspoonStatus(for info: ScanResult) {
        let key = info.conversationKey
        let saved = defaults.dictionary(forKey: defaultsKey("conversationStatus")) as? [String: String]
        guard saved?[key] == nil, let hammerspoonDefaults else { return }

        var restored: String?
        if let title = info.conversationTitle,
           let history = hammerspoonDefaults.array(forKey: hammerspoonConversationHistoryKey) as? [[String: Any]] {
            let normalizedTitle = normalizedConversationTitle(title)
            restored = history.reversed().first { row in
                guard let rowTitle = row["title"] as? String,
                      normalizedTitle == normalizedConversationTitle(rowTitle),
                      let status = row["status"] as? String else { return false }
                return hammerspoonRingStatus(status) != nil
            }.flatMap { row in
                (row["status"] as? String).flatMap(hammerspoonRingStatus)
            }
        }

        if restored == nil, let patch = info.latestDiff,
           let history = hammerspoonDefaults.array(forKey: hammerspoonPatchHistoryKey) as? [[String: Any]] {
            let fingerprint = patchFingerprint(patch)
            restored = history.reversed().first { row in
                guard row["fingerprint"] as? String == fingerprint,
                      let status = row["status"] as? String else { return false }
                return hammerspoonRingStatus(status) != nil
            }.flatMap { row in
                (row["status"] as? String).flatMap(hammerspoonRingStatus)
            }
        }

        if restored == nil {
            restored = hammerspoonDefaults.string(forKey: hammerspoonCurrentStatusKey)
                .flatMap(hammerspoonRingStatus)
        }

        if let restored {
            setStatus(restored, for: key)
            log("已从 Hammerspoon 恢复当前会话的终态圆环")
        }
    }

    private func setStatus(_ status: String, for key: String) {
        var values = defaults.dictionary(forKey: defaultsKey("conversationStatus")) as? [String: String] ?? [:]
        var order = defaults.stringArray(forKey: defaultsKey("conversationStatusOrder")) ?? values.keys.sorted()
        order.removeAll { $0 == key }
        order.append(key)
        values[key] = status
        if order.count > 100 {
            for expired in order.prefix(order.count - 100) { values[expired] = nil }
            order = Array(order.suffix(100))
        }
        defaults.set(values, forKey: defaultsKey("conversationStatus"))
        defaults.set(order, forKey: defaultsKey("conversationStatusOrder"))
        let retained = Set(order)
        generationEpoch = generationEpoch.filter { retained.contains($0.key) }
        pendingDiffHashes = pendingDiffHashes.filter { retained.contains($0.key) }
        pendingDiffAttempts = pendingDiffAttempts.filter { retained.contains($0.key) }
        if activeConversationKey == key { overlay.setColor(status) }
    }

    private func handle(_ patch: String, conversation: String) {
        guard patch.contains("diff --git a/"), patch.contains("+++ ") else { return }
        let digest = SHA256.hash(data: Data(patch.utf8)).map { String(format: "%02x", $0) }.joined()
        var hashes = defaults.stringArray(forKey: defaultsKey("processedPatchHashes")) ?? []
        guard !hashes.contains(digest) else { return }
        if applying {
            queuedPatch = (patch, conversation)
            return
        }
        hashes.append(digest)
        defaults.set(Array(hashes.suffix(256)), forKey: defaultsKey("processedPatchHashes"))
        applying = true
        let epoch = generationEpoch[conversation, default: 0]
        let root = bridgeRoot
        setStatus("gold", for: conversation)
        log("检测到新的完整 Diff，开始安全校验与应用")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.apply(patch, root: root)
            DispatchQueue.main.async {
                guard let self else { return }
                self.applying = false
                let ok = result.status == 0
                let wasDuplicate = result.output.contains("无需重复修改") || result.output.contains("Patch已应用")
                if self.generationEpoch[conversation, default: 0] == epoch && !wasDuplicate {
                    self.setStatus(ok ? "green" : "red", for: conversation)
                    self.toast(ok ? "修改成功" : "Patch 应用失败")
                }
                if !result.output.isEmpty { self.log(result.output) }
                self.log(wasDuplicate ? "Patch 已应用过，本次跳过" : (ok ? "Patch 应用成功" : "Patch 应用失败"))
                if !ok && !wasDuplicate {
                    self.autoSendFailureReport(result.report, conversation: conversation, epoch: epoch) { [weak self] in
                        self?.resumeQueuedPatch()
                    }
                } else {
                    self.resumeQueuedPatch()
                }
            }
        }
    }

    private func resumeQueuedPatch() {
        guard !applying, let queued = queuedPatch else { return }
        queuedPatch = nil
        handle(queued.text, conversation: queued.conversation)
    }

    private func confirmDiff(_ patch: String, conversation: String) {
        guard patch.contains("diff --git a/"), patch.contains("+++ ") else { return }
        let digest = SHA256.hash(data: Data(patch.utf8)).map { String(format: "%02x", $0) }.joined()
        let previous = pendingDiffHashes[conversation]
        if previous == digest {
            pendingDiffAttempts[conversation] = nil
            pendingDiffHashes[conversation] = nil
            handle(patch, conversation: conversation)
            return
        }
        pendingDiffHashes[conversation] = digest
        scheduleDiffRetry(conversation: conversation)
    }

    private func scheduleDiffRetry(conversation: String) {
        let attempt = pendingDiffAttempts[conversation, default: 0] + 1
        pendingDiffAttempts[conversation] = attempt
        guard attempt <= 4 else {
            pendingDiffAttempts[conversation] = nil
            pendingDiffHashes[conversation] = nil
            log("回复完成后未能稳定读取最后一个 Diff；未执行 Patch")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.previousGenerating == false,
                  self.previousConversationKey == conversation else { return }
            self.needsRefresh = true
            self.tick(force: true)
            guard let latest = self.cached, latest.conversationKey == conversation,
                  !latest.isWork, let diff = latest.latestDiff else {
                self.scheduleDiffRetry(conversation: conversation)
                return
            }
            self.confirmDiff(diff, conversation: conversation)
        }
    }

    private static func apply(_ patch: String, root: String) ->
        (status: Int32, output: String, report: String?) {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chatbridge-\(UUID().uuidString).patch")
        let outputFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chatbridge-\(UUID().uuidString).log")
        let reportFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chatbridge-\(UUID().uuidString).report")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: outputFile)
            try? FileManager.default.removeItem(at: reportFile)
        }
        do { try patch.write(to: file, atomically: true, encoding: .utf8) }
        catch { return (1, "无法写入临时 Patch：\(error.localizedDescription)", nil) }
        guard FileManager.default.createFile(atPath: outputFile.path, contents: nil),
              let outputHandle = try? FileHandle(forWritingTo: outputFile) else {
            return (1, "无法创建 Patch 诊断临时文件", nil)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "\(root)/tools/chat-apply-hammerspoon.sh")
        process.arguments = ["--patch-file", file.path]
        var environment = ProcessInfo.processInfo.environment
        environment["CHAT_BRIDGE_REPORT_FILE"] = reportFile.path
        environment["CHAT_BRIDGE_NO_ACTIVATE"] = "1"
        process.environment = environment
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        do { try process.run() }
        catch { try? outputHandle.close(); return (1, error.localizedDescription, nil) }
        process.waitUntilExit()
        try? outputHandle.close()
        let reader = try? FileHandle(forReadingFrom: outputFile)
        let length = (try? FileManager.default.attributesOfItem(atPath: outputFile.path)[.size] as? NSNumber)?.intValue ?? 0
        try? reader?.seek(toOffset: UInt64(max(0, length - 65_536)))
        let data = (try? reader?.read(upToCount: 65_536)) ?? nil
        try? reader?.close()
        let reportLength = (try? FileManager.default.attributesOfItem(atPath: reportFile.path)[.size] as? NSNumber)?.intValue ?? 0
        let report = reportLength > 0 && reportLength <= 4_000_000
            ? (try? String(contentsOf: reportFile, encoding: .utf8)) : nil
        return (process.terminationStatus, String(data: data ?? Data(), encoding: .utf8) ?? "", report)
    }

    private func toast(_ message: String) {
        guard Date().timeIntervalSince(lastToastAt) > 2 else { return }
        lastToastAt = Date()
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \"\(escaped)\" with title \"ChatGPTBridge\""]
        try? process.run()
    }

    private func autoSendFailureReport(_ report: String?, conversation: String,
                                       epoch: Int, completion: @escaping () -> Void) {
        let configURL = URL(fileURLWithPath: bridgeRoot).appendingPathComponent(".chatgpt/chat-monitor.json")
        guard let configData = try? Data(contentsOf: configURL),
              let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              config["autoSendFailureReport"] as? Bool == true else { completion(); return }
        guard generationEpoch[conversation, default: 0] == epoch else { completion(); return }
        tick(force: true)
        guard let info = cached, info.conversationKey == conversation, !info.isWork,
              !info.lengthLimitReached,
              let composer = info.composer, info.sendButton != nil,
              previousGenerating == false else {
            log("自动提交失败报告已启用，但无法安全确认原 Chat 输入框；报告保留在剪贴板")
            completion()
            return
        }
        guard let report,
              report.hasPrefix("下面是本地 ChatGPTBridge 自动生成的最新一次 Patch 失败诊断。"),
              report.utf8.count <= 4_000_000 else {
            log("失败报告未自动提交：本次诊断不可用")
            completion()
            return
        }
        let existing = (ax(composer, "AXValue") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard existing.isEmpty else {
            log("失败报告未自动提交：输入框已有内容，为保护草稿未覆盖")
            completion()
            return
        }
        guard AXUIElementSetAttributeValue(composer, kAXValueAttribute as CFString, report as CFString) == .success else {
            log("失败报告未自动提交：无法安全填写输入框")
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            defer { completion() }
            guard let self, !self.applying,
                  self.generationEpoch[conversation, default: 0] == epoch else { return }
            self.tick(force: true)
            guard let current = self.cached,
                  current.conversationKey == conversation, !current.isWork,
                  self.previousGenerating == false,
                  let button = current.sendButton,
                  let filled = ax(current.composer ?? composer, "AXValue") as? String,
                  filled == report else {
                self.log("失败报告已填写但未提交：会话或输入状态发生变化")
                return
            }
            guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                self.log("失败报告已填写但提交按钮操作失败")
                return
            }
            self.setStatus("gold", for: conversation)
            self.log("失败报告已通过当前普通 Chat 自动提交")
        }
    }
}

private let monitorAXCallback: AXObserverCallback = { _, _, _, context in
    guard let context else { return }
    let monitor = Unmanaged<Monitor>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { monitor.accessibilityChanged() }
}

if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--self-test" {
    let valid = transcriptSpeaker("ChatGPT said:") == .assistant &&
        transcriptSpeaker("You said:") == .user &&
        generationTransition(from: nil, to: false) == .none &&
        generationTransition(from: nil, to: true) == .none &&
        generationTransition(from: false, to: true) == .started &&
        generationTransition(from: true, to: false) == .completed &&
        patchFingerprint("abc") == "13a1f429:3" &&
        hammerspoonRingStatus("success") == "green" &&
        hammerspoonRingStatus("failure") == "red" &&
        isolatedPatchText("diff --git a/a b/a\n--- a/a\n+++ b/a\n") != nil &&
        isolatedPatchText("You said:\ndiff --git a/a b/a\n+++ b/a\n") == nil
    guard valid else {
        fputs("ChatGPTBridge monitor self-test failed\n", stderr)
        exit(1)
    }
    print("ChatGPTBridge monitor self-test passed")
    exit(0)
}

guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--bridge-root" else {
    fputs("Usage: chat-monitor --bridge-root <ChatGPTBridge project path>\n", stderr)
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
private let monitor = Monitor(root: CommandLine.arguments[2])
guard monitor.start() else { exit(3) }
app.run()
