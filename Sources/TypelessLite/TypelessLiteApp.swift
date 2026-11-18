import SwiftUI
import AppKit
import AVFoundation

@MainActor
public final class AppCoordinator: ObservableObject {
    public static let shared = AppCoordinator()

    @Published public var sessionState: SessionState = .idle
    @Published public var activeContext: AppContextInfo = AppContextInfo()
    @Published public var cardPayload: InteractiveCardPayload? = nil
    @Published public var playgroundText: String = """
    欢迎使用 TypelessLite（轻量原生 macOS 复刻版）！

    1. 直接把光标点在这里，点击上方「测试口述」（或按住全局热键说话）：
       试试说：“嗯，明天下午三点，不对，四点帮我发个会议纪要给团队”
    2. 选中下面这段话，点击「测试 AI 指令」（或按 ⌥ + Space）并说“润色得更专业一点”或“总结核心亮点”：
       我们通过 REA 逆向并重构了一个纯原生的 macOS 语音输入工具，体积极小而且不依赖绑定订阅。
    """

    private var floatingBarController: FloatingBarPanelController?
    private var cardController: InteractiveCardPanelController?

    private var savedTargetApp: NSRunningApplication?
    private var selectionFetchTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var resetPreviewTimer: Task<Void, Never>?
    private var currentMode: WorkMode = .dictation
    private var recordingSessionId = UUID()

    private let store = LocalStore.shared
    private let recorder = AudioRecorder.shared
    private let contextExtractor = ContextExtractor.shared
    private let textInjector = TextInjector.shared
    private let keyboardMonitor = KeyboardMonitor.shared

    public var statusBarUpdateHandler: ((SessionState) -> Void)?

    private init() {}

    public func bootstrapUI() {
        let barView = FloatingBarView(coordinator: self, recorder: recorder, store: store)
        floatingBarController = FloatingBarPanelController(rootView: barView)

        let cardView = InteractiveCardView(coordinator: self)
        cardController = InteractiveCardPanelController(rootView: cardView)

        keyboardMonitor.configure(
            settingsProvider: { [weak self] in
                self?.store.settings ?? AppSettings()
            },
            isSessionBusyProvider: { [weak self] in
                guard let self else { return false }
                return self.sessionState.isRecording || self.sessionState.isProcessing
            },
            onAction: { [weak self] action in
                self?.handleKeyboardAction(action)
            }
        )
        keyboardMonitor.start()
        syncFloatingBarState()
    }

    // MARK: - Keyboard Actions

    private func handleKeyboardAction(_ action: KeyboardMonitor.Action) {
        switch action {
        case .startRecording(let mode, let isHandsFree):
            startSession(mode: mode, isHandsFree: isHandsFree)
        case .upgradeToHandsFree(let mode):
            if case .recording(_, _, let startedAt) = sessionState {
                sessionState = .recording(mode: mode, isHandsFree: true, startedAt: startedAt)
                syncFloatingBarState()
            }
        case .finishRecording:
            finishSession()
        case .cancelRecording:
            cancelSession()
        }
    }

    public func toggleManualDictation() {
        if sessionState.isRecording {
            finishSession()
        } else if sessionState.isProcessing {
            cancelSession()
        } else {
            startSession(mode: .dictation, isHandsFree: true)
        }
    }

    public func triggerPlaygroundAction(_ mode: WorkMode) {
        if sessionState.isRecording {
            finishSession()
        } else if !sessionState.isProcessing {
            startSession(mode: mode, isHandsFree: true)
        }
    }

    // MARK: - Session Lifecycle

    public func startSession(mode: WorkMode, isHandsFree: Bool) {
        resetPreviewTimer?.cancel()
        cardController?.hide()

        Task {
            let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            if micStatus == .notDetermined {
                let granted = await recorder.requestMicrophonePermission()
                if !granted {
                    showTransientError("需要麦克风权限才能进行语音输入")
                    keyboardMonitor.resetState()
                    return
                }
            } else if micStatus != .authorized {
                showTransientError("麦克风权限未开启，请在设置中授权")
                keyboardMonitor.resetState()
                return
            }

            let captured = contextExtractor.captureCurrentContext()
            self.activeContext = captured.context
            self.savedTargetApp = captured.targetApp
            self.recordingSessionId = UUID()
            let currentSessionId = self.recordingSessionId

            // If user is testing inside TypelessLite's own Playground without Accessibility permission, read selection directly from NSTextView
            if self.activeContext.selectedText.isEmpty,
               captured.targetApp?.bundleIdentifier == Bundle.main.bundleIdentifier,
               let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
                let sel = textView.selectedRange()
                if sel.length > 0 {
                    let nsStr = textView.string as NSString
                    if sel.location != NSNotFound && sel.location + sel.length <= nsStr.length {
                        self.activeContext.selectedText = nsStr.substring(with: sel)
                    }
                }
            }

            var effectiveMode = mode
            if mode == .dictation && store.settings.autoAskWhenTextSelected && !self.activeContext.selectedText.isEmpty {
                effectiveMode = .askAnything
            }
            self.currentMode = effectiveMode

            // Start recording immediately to prevent clipping the user's first word
            do {
                _ = try recorder.startRecording()
            } catch {
                showTransientError(error.localizedDescription)
                keyboardMonitor.resetState()
                return
            }

            self.sessionState = .recording(mode: effectiveMode, isHandsFree: isHandsFree, startedAt: Date())
            self.syncFloatingBarState()

            // Concurrently attempt Cmd+C fallback selection extraction if AX didn't yield selected text
            if self.activeContext.selectedText.isEmpty && (effectiveMode == .askAnything || store.settings.autoAskWhenTextSelected) {
                let target = captured.targetApp
                selectionFetchTask?.cancel()
                selectionFetchTask = Task { [weak self] in
                    guard let self else { return }
                    let fallbackSelected = await self.textInjector.getSelectedTextWithFallback(
                        targetApp: target,
                        contextExtractor: self.contextExtractor
                    )
                    guard self.recordingSessionId == currentSessionId else { return }
                    if !fallbackSelected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.activeContext.selectedText = fallbackSelected
                        if mode == .dictation && self.store.settings.autoAskWhenTextSelected {
                            self.currentMode = .askAnything
                            if case .recording(_, let hf, let startedAt) = self.sessionState {
                                self.sessionState = .recording(mode: .askAnything, isHandsFree: hf, startedAt: startedAt)
                                self.syncFloatingBarState()
                            }
                        }
                    }
                }
            }
        }
    }

    public func finishSession() {
        guard case .recording(let mode, _, _) = sessionState else { return }
        selectionFetchTask?.cancel()

        guard let recording = recorder.stopRecording() else {
            sessionState = .idle
            syncFloatingBarState()
            return
        }

        if recording.duration < 0.25 {
            try? FileManager.default.removeItem(at: recording.url)
            sessionState = .idle
            syncFloatingBarState()
            return
        }

        let capturedContext = activeContext
        let targetApp = savedTargetApp
        let settings = store.settings
        let dictionary = store.dictionary

        sessionState = .processing(mode: mode, stage: "正在识别语音...")
        syncFloatingBarState()

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: recording.url)
            }

            do {
                let result = try await AIVoiceFlowEngine.shared.processVoiceFlow(
                    audioURL: recording.url,
                    duration: recording.duration,
                    mode: mode,
                    context: capturedContext,
                    settings: settings,
                    dictionary: dictionary
                )
                try Task.checkCancellation()

                if result.delivery == .noOp || result.refinedText.isEmpty {
                    self.showTransientError(result.warningMessage ?? "未检测到有效语音内容")
                    return
                }

                let record = HistoryRecord(
                    mode: mode,
                    rawText: result.rawTranscript,
                    refinedText: result.refinedText,
                    selectedContextText: capturedContext.selectedText,
                    appName: capturedContext.appName,
                    bundleId: capturedContext.bundleId,
                    durationSeconds: result.durationSeconds,
                    delivery: result.delivery.rawValue,
                    asrEngine: result.asrEngineUsed,
                    llmEngine: result.llmEngineUsed
                )
                self.store.addHistory(record)

                switch result.delivery {
                case .replaceOrInsert:
                    let inserted = await self.deliverTextToFocusedTarget(result.refinedText, targetApp: targetApp)
                    if inserted {
                        let preview = result.warningMessage.map { "\($0) · \(result.refinedText)" } ?? result.refinedText
                        self.showTransientCompleted(preview)
                    } else {
                        self.showTransientCompleted("已复制（开启辅助功能可自动上屏）: \(result.refinedText)")
                    }

                case .card:
                    self.cardPayload = InteractiveCardPayload(
                        selectedText: capturedContext.selectedText,
                        voicePrompt: result.rawTranscript,
                        answer: result.refinedText,
                        appName: capturedContext.appName
                    )
                    self.sessionState = .idle
                    self.syncFloatingBarState()
                    if let barFrame = self.floatingBarController?.currentFrame {
                        self.cardController?.show(above: barFrame)
                    }

                case .noOp:
                    self.showTransientError(result.warningMessage ?? "无输出")
                }
            } catch is CancellationError {
                self.sessionState = .idle
                self.syncFloatingBarState()
            } catch {
                self.showTransientError(error.localizedDescription)
            }
        }
    }

    public func cancelSession() {
        selectionFetchTask?.cancel()
        processingTask?.cancel()
        AIVoiceFlowEngine.shared.cancelCurrent()
        recorder.cancelRecording()
        keyboardMonitor.resetState()
        sessionState = .idle
        syncFloatingBarState()
    }

    // MARK: - Delivery Helpers

    private func deliverTextToFocusedTarget(_ text: String, targetApp: NSRunningApplication?) async -> Bool {
        // If user is testing inside TypelessLite's own Playground TextEditor, insert directly via firstResponder even without Accessibility permission
        if targetApp?.bundleIdentifier == Bundle.main.bundleIdentifier,
           let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            textView.insertText(text, replacementRange: textView.selectedRange())
            return true
        }
        return await textInjector.insertText(text, targetApp: targetApp)
    }

    public func insertCardAnswerToTargetApp() {
        guard let payload = cardPayload else { return }
        let answer = payload.answer
        let target = savedTargetApp
        dismissCard()
        Task {
            let inserted = await deliverTextToFocusedTarget(answer, targetApp: target)
            if inserted {
                showTransientCompleted("已插入回答")
            } else {
                showTransientCompleted("已复制到剪贴板")
            }
        }
    }

    public func dismissCard() {
        cardController?.hide()
        cardPayload = nil
    }

    // MARK: - Floating Bar & Feedback Timers

    public func syncFloatingBarState() {
        statusBarUpdateHandler?(sessionState)
        guard let floatingBarController else { return }
        switch sessionState {
        case .idle:
            floatingBarController.updateVisibility(visible: store.settings.showFloatingBarWhenIdle, expanded: false)
        case .recording, .processing, .completedPreview, .error:
            floatingBarController.updateVisibility(visible: true, expanded: true)
        }
    }

    private func showTransientCompleted(_ text: String) {
        sessionState = .completedPreview(text: text)
        syncFloatingBarState()
        scheduleResetToIdle(afterSeconds: 2.2)
    }

    private func showTransientError(_ message: String) {
        sessionState = .error(message: message)
        syncFloatingBarState()
        scheduleResetToIdle(afterSeconds: 3.4)
    }

    private func scheduleResetToIdle(afterSeconds seconds: Double) {
        resetPreviewTimer?.cancel()
        resetPreviewTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if case .completedPreview = self.sessionState {
                self.sessionState = .idle
                self.syncFloatingBarState()
            } else if case .error = self.sessionState {
                self.sessionState = .idle
                self.syncFloatingBarState()
            }
        }
    }
}

// MARK: - AppDelegate & Menu Bar Status Item

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private weak var hubWindow: NSWindow?
    public var openHubClosure: (() -> Void)?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let showInDock = LocalStore.shared.settings.showInDock
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)

        setupMenuBar()
        AppCoordinator.shared.bootstrapUI()
        AppCoordinator.shared.statusBarUpdateHandler = { [weak self] state in
            self?.updateStatusIcon(for: state)
        }

        // Remember Hub window so menu bar can always summon it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.hubWindow = NSApp.windows.first(where: { $0.title.contains("TypelessLite") })
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in menu bar like Typeless
        return false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openHubWindow()
        }
        return true
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: "TypelessLite")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开控制台 (Hub)", action: #selector(openHubAction), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "开始 / 结束口述", action: #selector(toggleDictationAction), keyEquivalent: "d"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "检查辅助功能权限", action: #selector(checkAccessibilityAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 TypelessLite", action: #selector(quitAction), keyEquivalent: "q"))

        for menuItem in menu.items {
            menuItem.target = self
        }
        item.menu = menu
        self.statusItem = item
    }

    private func updateStatusIcon(for state: SessionState) {
        guard let button = statusItem?.button else { return }
        let symbolName: String
        switch state {
        case .recording:
            symbolName = "mic.circle.fill"
        case .processing:
            symbolName = "ellipsis.circle"
        default:
            symbolName = "waveform.and.mic"
        }
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "TypelessLite")
        button.image?.isTemplate = true
    }

    @objc private func openHubAction() {
        openHubWindow()
    }

    @objc private func toggleDictationAction() {
        AppCoordinator.shared.toggleManualDictation()
    }

    @objc private func checkAccessibilityAction() {
        ContextExtractor.shared.requestAccessibilityPermission()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    public func openHubWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let openHubClosure {
            openHubClosure()
        } else if let win = hubWindow ?? NSApp.windows.first(where: { !($0 is NSPanel) }) {
            win.makeKeyAndOrderFront(nil)
        }
    }
}

@main
struct TypelessLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var coordinator = AppCoordinator.shared
    @StateObject private var store = LocalStore.shared
    @StateObject private var contextExtractor = ContextExtractor.shared
    @StateObject private var recorder = AudioRecorder.shared
    @StateObject private var keyboardMonitor = KeyboardMonitor.shared

    var body: some Scene {
        Window("TypelessLite 控制台", id: "hub") {
            HubWindowView(
                coordinator: coordinator,
                store: store,
                contextExtractor: contextExtractor,
                recorder: recorder,
                keyboardMonitor: keyboardMonitor
            )
            .onAppear {
                appDelegate.openHubClosure = {
                    openWindow(id: "hub")
                }
            }
        }
        .defaultSize(width: 900, height: 640)
    }
}
