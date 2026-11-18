import Foundation
import AppKit
import ApplicationServices

/// Reverse-engineered replica of Typeless's libContextHelper.dylib.
/// Extracts focused app identity, browser URL/domain, selected text, and surrounding text via AXUIElement.
@MainActor
public final class ContextExtractor: ObservableObject {
    public static let shared = ContextExtractor()

    @Published public private(set) var isAccessibilityTrusted: Bool = AXIsProcessTrusted()
    public private(set) var lastExternalApp: NSRunningApplication?

    private var workspaceObserver: NSObjectProtocol?
    private var trustPollTimer: Timer?

    private init() {
        refreshTrustStatus()
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApp = front
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                if app.bundleIdentifier != Bundle.main.bundleIdentifier {
                    self?.lastExternalApp = app
                }
            }
        }

        trustPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTrustStatus()
            }
        }
    }

    @discardableResult
    public func refreshTrustStatus() -> Bool {
        let trusted = AXIsProcessTrusted()
        if trusted != isAccessibilityTrusted {
            isAccessibilityTrusted = trusted
        }
        return trusted
    }

    /// Prompts macOS System Settings Accessibility dialog (mirrors macosCheckAccessibility / checkAccessibilityPermission)
    public func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshTrustStatus()
    }

    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Capture context of the currently focused application and input element
    public func captureCurrentContext() -> (context: AppContextInfo, targetApp: NSRunningApplication?) {
        refreshTrustStatus()

        let frontApp = NSWorkspace.shared.frontmostApplication
        let targetApp = frontApp ?? lastExternalApp
        let appName = targetApp?.localizedName ?? "Unknown"
        let bundleId = targetApp?.bundleIdentifier ?? ""

        var windowTitle = ""
        var selectedText = ""
        var beforeText = ""
        var afterText = ""
        var webURL: String? = nil
        var webDomain: String? = nil

        if isAccessibilityTrusted, let pid = targetApp?.processIdentifier {
            let appElement = AXUIElementCreateApplication(pid)

            // Mirror libContextHelper.setFocusedWindowEnhancedUserInterface() for Electron/Chromium apps
            if isChromiumOrElectronLikely(bundleId: bundleId, appName: appName) {
                AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }

            // Focused window title
            if let focusedWindow = copyElementAttribute(appElement, attribute: kAXFocusedWindowAttribute) {
                windowTitle = copyStringAttribute(focusedWindow, attribute: kAXTitleAttribute) ?? ""
            }

            // Focused UI element text & selection
            if let focusedElement = copyElementAttribute(appElement, attribute: kAXFocusedUIElementAttribute) {
                selectedText = copyStringAttribute(focusedElement, attribute: kAXSelectedTextAttribute) ?? ""

                if let fullValue = copyStringAttribute(focusedElement, attribute: kAXValueAttribute), !fullValue.isEmpty {
                    let nsValue = fullValue as NSString
                    if let range = copyRangeAttribute(focusedElement, attribute: kAXSelectedTextRangeAttribute),
                       range.location != kCFNotFound,
                       range.location >= 0,
                       range.location <= nsValue.length {
                        let beforeStart = max(0, range.location - 300)
                        let beforeLen = range.location - beforeStart
                        if beforeLen > 0 {
                            beforeText = nsValue.substring(with: NSRange(location: beforeStart, length: beforeLen))
                        }

                        let afterStart = min(nsValue.length, range.location + max(0, range.length))
                        let afterLen = min(150, nsValue.length - afterStart)
                        if afterLen > 0 {
                            afterText = nsValue.substring(with: NSRange(location: afterStart, length: afterLen))
                        }

                        if selectedText.isEmpty, range.length > 0, range.location + range.length <= nsValue.length {
                            selectedText = nsValue.substring(with: NSRange(location: range.location, length: range.length))
                        }
                    } else {
                        // Fallback slice when range isn't exposed
                        beforeText = String(fullValue.suffix(300))
                    }
                }

                // Traverse upward for browser URL (mirrors findWebInfoByTraversingUp)
                if isBrowserApp(bundleId: bundleId) {
                    if let foundURL = findWebURL(startingFrom: focusedElement) {
                        webURL = foundURL
                        webDomain = URL(string: foundURL)?.host
                    }
                }
            }
        }

        let tone = AppContextInfo.inferTone(bundleId: bundleId, appName: appName, webDomain: webDomain)
        let info = AppContextInfo(
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            webURL: webURL,
            webDomain: webDomain,
            selectedText: selectedText,
            beforeText: beforeText,
            afterText: afterText,
            detectedTone: tone
        )
        return (info, targetApp)
    }

    public func readFocusedSelectedText(for app: NSRunningApplication?) -> String {
        guard isAccessibilityTrusted, let pid = app?.processIdentifier else { return "" }
        let appElement = AXUIElementCreateApplication(pid)
        guard let focusedElement = copyElementAttribute(appElement, attribute: kAXFocusedUIElementAttribute) else {
            return ""
        }
        if let direct = copyStringAttribute(focusedElement, attribute: kAXSelectedTextAttribute), !direct.isEmpty {
            return direct
        }
        if let fullValue = copyStringAttribute(focusedElement, attribute: kAXValueAttribute),
           let range = copyRangeAttribute(focusedElement, attribute: kAXSelectedTextRangeAttribute),
           range.location != kCFNotFound,
           range.length > 0 {
            let nsValue = fullValue as NSString
            if range.location >= 0 && range.location + range.length <= nsValue.length {
                return nsValue.substring(with: NSRange(location: range.location, length: range.length))
            }
        }
        return ""
    }

    // MARK: - AXUIElement Helpers

    private func copyElementAttribute(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyStringAttribute(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let value else { return nil }
        if let str = value as? String {
            return str
        }
        if CFGetTypeID(value) == CFURLGetTypeID() {
            let url = unsafeDowncast(value, to: CFURL.self) as URL
            return url.absoluteString
        }
        return nil
    }

    private func copyRangeAttribute(_ element: AXUIElement, attribute: String) -> CFRange? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var range = CFRange(location: kCFNotFound, length: 0)
        if AXValueGetValue(axValue, .cfRange, &range) {
            return range
        }
        return nil
    }

    private func isChromiumOrElectronLikely(bundleId: String, appName: String) -> Bool {
        let lower = bundleId.lowercased()
        let nameLower = appName.lowercased()
        return lower.contains("chrome") || lower.contains("electron") || lower.contains("vscode") ||
            lower.contains("cursor") || lower.contains("slack") || lower.contains("lark") ||
            lower.contains("feishu") || lower.contains("notion") || lower.contains("discord") ||
            nameLower.contains("chrome") || nameLower.contains("arc") || nameLower.contains("edge")
    }

    private func isBrowserApp(bundleId: String) -> Bool {
        let lower = bundleId.lowercased()
        return [
            "com.apple.safari", "com.google.chrome", "company.thebrowser.browser",
            "com.microsoft.edgemac", "com.brave.browser", "org.mozilla.firefox",
            "com.operasoftware.opera", "com.vivaldi.vivaldi"
        ].contains(where: { lower.contains($0) })
    }

    private func findWebURL(startingFrom element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<10 {
            guard let el = current else { break }
            if let urlString = copyStringAttribute(el, attribute: kAXURLAttribute), !urlString.isEmpty {
                return urlString
            }
            current = copyElementAttribute(el, attribute: kAXParentAttribute)
        }
        return nil
    }
}
