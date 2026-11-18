import Foundation
import AppKit
import CoreGraphics

/// Reverse-engineered replica of Typeless's libInputHelper.dylib.
/// Performs lossless clipboard snapshot/restore around simulated Cmd+C (read selection) and Cmd+V (insert text).
@MainActor
public final class TextInjector {
    public static let shared = TextInjector()

    private struct ArchivedPasteboardItem {
        let entries: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private init() {}

    // MARK: - Pasteboard Snapshot & Restore (mirrors savePasteboard / restorePasteboard)

    private func savePasteboard(_ pasteboard: NSPasteboard) -> [ArchivedPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.compactMap { item in
            let entries: [(NSPasteboard.PasteboardType, Data)] = item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
            return entries.isEmpty ? nil : ArchivedPasteboardItem(entries: entries)
        }
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, from snapshot: [ArchivedPasteboardItem]) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items: [NSPasteboardItem] = snapshot.map { archived in
            let item = NSPasteboardItem()
            for (type, data) in archived.entries {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    // MARK: - Selected Text Retrieval (mirrors getSelectedText + getSelectedTextBySimulateCopyAsync)

    public func getSelectedTextWithFallback(
        targetApp: NSRunningApplication?,
        contextExtractor: ContextExtractor
    ) async -> String {
        let directAX = contextExtractor.readFocusedSelectedText(for: targetApp)
        if !directAX.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return directAX
        }

        guard AXIsProcessTrusted() else { return "" }

        let pasteboard = NSPasteboard.general
        let snapshot = savePasteboard(pasteboard)
        let initialChangeCount = pasteboard.changeCount

        simulateKeyCombo(virtualKey: 8, flags: .maskCommand) // Cmd + C

        // Poll briefly for target app to populate NSPasteboard
        var copied = ""
        for _ in 0..<7 {
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
            if pasteboard.changeCount != initialChangeCount {
                copied = pasteboard.string(forType: .string) ?? ""
                break
            }
        }

        restorePasteboard(pasteboard, from: snapshot)
        return copied
    }

    // MARK: - Text Insertion (mirrors performTextInsertion + simulatePasteCommand)

    @discardableResult
    public func insertText(_ text: String, targetApp: NSRunningApplication?) async -> Bool {
        guard !text.isEmpty else { return false }

        // Ensure target application has keyboard focus if it was deactivated (e.g., after clicking InteractiveCard)
        if let app = targetApp,
           let front = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != front.processIdentifier {
            app.activate(options: [])
            try? await Task.sleep(nanoseconds: 90_000_000)
        }

        let pasteboard = NSPasteboard.general
        let snapshot = savePasteboard(pasteboard)

        pasteboard.clearContents()
        let wrote = pasteboard.setString(text, forType: .string)
        guard wrote else { return false }

        let ourChangeCount = pasteboard.changeCount

        if AXIsProcessTrusted() {
            simulateKeyCombo(virtualKey: 9, flags: .maskCommand) // Cmd + V
            // Give target app (especially Electron/Chromium/WeChat) time to consume pasteboard before restoring
            try? await Task.sleep(nanoseconds: 220_000_000)
            if pasteboard.changeCount == ourChangeCount {
                restorePasteboard(pasteboard, from: snapshot)
            }
            return true
        }

        // Without Accessibility permission, keep text in clipboard so user can paste manually
        return false
    }

    // MARK: - CGEvent Key Simulation

    private func simulateKeyCombo(virtualKey: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
