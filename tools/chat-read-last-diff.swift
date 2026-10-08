import AppKit
import ApplicationServices

private let nativeBundleIdentifier = "com.openai.codex"
private let safariBundleIdentifier = "com.apple.Safari"
private let chromiumBundleIdentifiers = [
    "com.google.Chrome",
    "com.google.Chrome.beta",
    "com.google.Chrome.canary",
    "com.google.Chrome.dev",
    "org.chromium.Chromium",
    "com.microsoft.edgemac",
    "com.brave.Browser",
    "com.vivaldi.Vivaldi",
    "company.thebrowser.Browser"
]

private func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

private func attribute(_ element: AXUIElement, _ name: String) -> Any? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard error == .success else { return nil }
    return value
}

private func parameterizedAttribute(
    _ element: AXUIElement,
    _ name: String,
    parameter: Any
) -> Any? {
    var value: CFTypeRef?
    let error = AXUIElementCopyParameterizedAttributeValue(
        element,
        name as CFString,
        parameter as CFTypeRef,
        &value
    )
    guard error == .success else { return nil }
    return value
}

private func role(_ element: AXUIElement) -> String? {
    attribute(element, "AXRole") as? String
}

private func title(_ element: AXUIElement) -> String? {
    attribute(element, "AXTitle") as? String
}

private func value(_ element: AXUIElement) -> String? {
    attribute(element, "AXValue") as? String
}

private func axElement(_ value: Any?) -> AXUIElement? {
    guard let value else { return nil }
    let typeID = CFGetTypeID(value as CFTypeRef)
    guard typeID == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}

private func parent(_ element: AXUIElement) -> AXUIElement? {
    axElement(attribute(element, "AXParent"))
}

private func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, "AXChildren") as? [AXUIElement] ?? []
}

private func trimmed(_ text: String?) -> String {
    text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

private func elementText(_ element: AXUIElement) -> String {
    trimmed(value(element) ?? title(element))
}

private func isPatchText(_ text: String) -> Bool {
    text.contains("diff --git a/") && text.contains("+++ ")
}

private func isBrowserBundle(_ bundleIdentifier: String?) -> Bool {
    guard let bundleIdentifier else { return false }
    return bundleIdentifier == safariBundleIdentifier ||
        chromiumBundleIdentifiers.contains(bundleIdentifier)
}

private func isNativeBundle(_ bundleIdentifier: String?) -> Bool {
    bundleIdentifier == nativeBundleIdentifier
}

private func isChatGPTWindow(_ window: AXUIElement) -> Bool {
    let windowTitle = trimmed(title(window)).lowercased()
    let document = (attribute(window, "AXDocument") as? String ?? "").lowercased()

    return windowTitle.contains("chatgpt") ||
        document.contains("chatgpt.com") ||
        document.contains("chat.openai.com")
}

private func candidateWindows(
    for application: NSRunningApplication,
    isBrowser: Bool
) -> [AXUIElement] {
    let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
    var windows: [AXUIElement] = []

    if let focused = axElement(attribute(applicationElement, "AXFocusedWindow")) {
        windows.append(focused)
    }

    if let allWindows = attribute(applicationElement, "AXWindows") as? [AXUIElement] {
        windows.append(contentsOf: allWindows)
    }

    let matching = windows.filter(isChatGPTWindow)
    if !matching.isEmpty {
        return matching
    }

    // Never inspect an unverified browser window: it may be another tab or
    // another site, and applying its Diff would be unsafe.
    return []
}

private enum Speaker {
    case assistant
    case user
    case unknown
}

private func latestAssistantDiff(in window: AXUIElement) -> AXUIElement? {
    var assistantCandidates: [AXUIElement] = []
    func walk(_ element: AXUIElement, depth: Int, speaker: Speaker) {
        guard depth <= 200 else { return }

        var currentSpeaker = speaker
        switch elementText(element).lowercased() {
        case "chatgpt said:", "assistant said:", "assistant:":
            currentSpeaker = .assistant
        case "you said:", "user said:", "user:":
            currentSpeaker = .user
        default:
            break
        }

        if elementText(element).caseInsensitiveCompare("Diff") == .orderedSame {
            if currentSpeaker == .assistant {
                assistantCandidates.append(element)
            }
        }

        for child in children(element) {
            walk(child, depth: depth + 1, speaker: currentSpeaker)
        }
    }

    walk(window, depth: 0, speaker: .unknown)
    return assistantCandidates.last
}

private func textMarkerText(_ element: AXUIElement) -> String? {
    guard let markerRange = parameterizedAttribute(
        element,
        "AXTextMarkerRangeForUIElement",
        parameter: element
    ) else {
        return nil
    }

    return parameterizedAttribute(
        element,
        "AXStringForTextMarkerRange",
        parameter: markerRange
    ) as? String
}

private func descendantText(_ element: AXUIElement, depth: Int) -> String {
    if let direct = value(element), !direct.isEmpty {
        return direct
    }

    guard depth < 5 else { return "" }
    return children(element)
        .map { descendantText($0, depth: depth + 1) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

private func patchText(from diff: AXUIElement) -> String? {
    var current: AXUIElement? = diff

    for _ in 0..<12 {
        guard let element = current else { break }

        if let text = textMarkerText(element), isPatchText(text) {
            return text
        }

        let text = descendantText(element, depth: 0)
        if isPatchText(text) {
            return text
        }

        current = parent(element)
    }

    return nil
}

private func orderedApplications(
    preference: String,
    explicitBundleIdentifier: String?
) -> [NSRunningApplication] {
    let running = NSWorkspace.shared.runningApplications
        .filter { $0.bundleIdentifier != nil }
        .sorted(by: { (left: NSRunningApplication, right: NSRunningApplication) -> Bool in
            if left.isActive != right.isActive {
                return left.isActive && !right.isActive
            }
            return left.processIdentifier < right.processIdentifier
        })

    if let explicitBundleIdentifier, !explicitBundleIdentifier.isEmpty {
        return running.filter { $0.bundleIdentifier == explicitBundleIdentifier }
    }

    switch preference {
    case "native", "app", "codex":
        return running.filter { isNativeBundle($0.bundleIdentifier) }
    case "safari":
        return running.filter { $0.bundleIdentifier == safariBundleIdentifier }
    case "chrome", "chromium", "browser":
        return running.filter {
            guard let bundleIdentifier = $0.bundleIdentifier else { return false }
            return chromiumBundleIdentifiers.contains(bundleIdentifier)
        }
    default:
        return running.filter {
            isNativeBundle($0.bundleIdentifier) || isBrowserBundle($0.bundleIdentifier)
        }
    }
}

let permissionOptions = [
    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
] as CFDictionary
guard AXIsProcessTrustedWithOptions(permissionOptions) else {
    fail("需要在系统设置 → 隐私与安全性 → 辅助功能中授权当前 chat-read-last-diff 程序，然后重新运行。", code: 1)
}

let preference = (
    ProcessInfo.processInfo.environment["CHATGPT_SOURCE"] ??
    ProcessInfo.processInfo.environment["CHATGPT_APP"] ??
    "auto"
).lowercased()
let explicitBundleIdentifier = ProcessInfo.processInfo.environment["CHATGPT_BUNDLE_ID"]
let applications = orderedApplications(
    preference: preference,
    explicitBundleIdentifier: explicitBundleIdentifier
)

guard !applications.isEmpty else {
    let target = explicitBundleIdentifier ?? preference
    fail("找不到正在运行的 ChatGPT/Codex 目标应用：\(target)", code: 2)
}

var foundWindow = false
for application in applications {
    let browser = isBrowserBundle(application.bundleIdentifier)
    for window in candidateWindows(for: application, isBrowser: browser) {
        foundWindow = true
        guard let diff = latestAssistantDiff(in: window),
              let text = patchText(from: diff) else {
            continue
        }

        print(text, terminator: "")
        exit(0)
    }
}

if !foundWindow {
    fail("找不到 ChatGPT 页面或窗口，请先打开 ChatGPT 对话。", code: 3)
}

fail("没有找到最后一个助手回复中的 Diff 代码块。", code: 4)
