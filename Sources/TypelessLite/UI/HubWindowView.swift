import SwiftUI
import AppKit

public enum HubSection: String, CaseIterable, Identifiable {
    case home = "工作台"
    case engines = "AI 与语音引擎"
    case shortcuts = "快捷键与行为"
    case dictionaryAndHistory = "词典与历史"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .home: return "house.fill"
        case .engines: return "cpu"
        case .shortcuts: return "command"
        case .dictionaryAndHistory: return "book.closed.fill"
        }
    }
}

/// Lightweight native Hub console (replaces Typeless 265MB Electron hub.html).
public struct HubWindowView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var store: LocalStore
    @ObservedObject var contextExtractor: ContextExtractor
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject var keyboardMonitor: KeyboardMonitor

    @State private var selectedSection: HubSection = .home
    @State private var showASRKey = false
    @State private var showLLMKey = false
    @State private var testingConnection = false
    @State private var connectionTestMessage: String?
    @State private var connectionTestSuccess: Bool?

    // Dictionary input
    @State private var newTerm = ""
    @State private var newAliases = ""
    @State private var newNote = ""
    @State private var historySearch = ""
    @State private var historyFilter: WorkMode? = nil
    @State private var subTab: Int = 0 // 0 = History, 1 = Dictionary

    public init(
        coordinator: AppCoordinator,
        store: LocalStore,
        contextExtractor: ContextExtractor,
        recorder: AudioRecorder,
        keyboardMonitor: KeyboardMonitor
    ) {
        self.coordinator = coordinator
        self.store = store
        self.contextExtractor = contextExtractor
        self.recorder = recorder
        self.keyboardMonitor = keyboardMonitor
    }

    public var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.blue.gradient)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("TypelessLite")
                            .font(.system(size: 15, weight: .bold))
                        Text("原生轻量 AI 语音助手")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

                List(HubSection.allCases, selection: $selectedSection) { section in
                    Label(section.rawValue, systemImage: section.iconName)
                        .tag(section)
                }
                .listStyle(.sidebar)

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(keyboardMonitor.isEventTapActive ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(keyboardMonitor.isEventTapActive ? "全局 CGEventTap 已激活" : "当前仅用事件监听兜底")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Text("100% 本地存储 · 无云端追踪")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .navigationSplitViewColumnWidth(min: 195, ideal: 210, max: 230)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch selectedSection {
                    case .home:
                        homeAndPlaygroundView
                    case .engines:
                        enginesSettingsView
                    case .shortcuts:
                        shortcutsSettingsView
                    case .dictionaryAndHistory:
                        dictionaryAndHistoryView
                    }
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear {
            recorder.refreshPermissionStates()
            contextExtractor.refreshTrustStatus()
        }
    }

    // MARK: - 1. Home & Playground

    private var homeAndPlaygroundView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("自然说话，完美书写")
                .font(.system(size: 22, weight: .bold))

            // Permission Check Banner
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("系统权限状态")
                        .font(.system(size: 13, weight: .semibold))

                    HStack(spacing: 16) {
                        permissionBadge(
                            title: "麦克风录音",
                            granted: recorder.microphoneAuthorized,
                            actionTitle: "申请权限"
                        ) {
                            Task {
                                let ok = await recorder.requestMicrophonePermission()
                                if !ok { contextExtractor.openMicrophoneSettings() }
                            }
                        }

                        permissionBadge(
                            title: "辅助功能 (全局热键 & 自动上屏)",
                            granted: contextExtractor.isAccessibilityTrusted,
                            actionTitle: "前往授权"
                        ) {
                            contextExtractor.requestAccessibilityPermission()
                        }

                        if store.settings.asrProvider == .appleSpeech {
                            permissionBadge(
                                title: "Apple 语音识别",
                                granted: recorder.speechRecognitionAuthorized,
                                actionTitle: "申请权限"
                            ) {
                                Task { _ = await recorder.requestSpeechRecognitionPermission() }
                            }
                        }
                    }
                }
                .padding(4)
            }

            // Stats Row
            HStack(spacing: 14) {
                statCard(title: "累计输出字符", value: "\(store.totalCharactersGenerated)", unit: "字", icon: "text.alignleft", color: .blue)
                statCard(title: "估算节省时间", value: "\(store.estimatedMinutesSaved)", unit: "分钟", icon: "clock.arrow.circlepath", color: .green)
                statCard(title: "本地记录条数", value: "\(store.history.count)", unit: "条", icon: "tray.full", color: .purple)
            }

            // Shortcut quick cheatsheet
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("三大核心模式（长按说话松手即出，轻触一次免提再按完成，Esc 取消）")
                        .font(.system(size: 12.5, weight: .semibold))

                    HStack(spacing: 12) {
                        modeChip(mode: .dictation, hotkey: store.settings.dictationHotkey, desc: "去口癖与自我纠错", color: .blue)
                        modeChip(mode: .askAnything, hotkey: store.settings.askAnythingHotkey, desc: "选中改写或浮窗问答", color: .purple)
                        modeChip(mode: .translation, hotkey: store.settings.translationHotkey, desc: "直译为 \(store.settings.translationTargetLanguage)", color: .teal)
                    }
                }
                .padding(4)
            }

            // Interactive Playground
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("实时演练场（无需切换窗口即可测试）", systemImage: "play.rectangle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button {
                            coordinator.triggerPlaygroundAction(.dictation)
                        } label: {
                            Label(
                                coordinator.sessionState.isRecording ? "停止并识别" : "测试口述",
                                systemImage: coordinator.sessionState.isRecording ? "stop.circle.fill" : "mic.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(coordinator.sessionState.isRecording ? .red : .blue)

                        Button {
                            coordinator.triggerPlaygroundAction(.askAnything)
                        } label: {
                            Label("测试 AI 指令", systemImage: "sparkles")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            coordinator.triggerPlaygroundAction(.translation)
                        } label: {
                            Label("测试翻译", systemImage: "globe")
                        }
                        .buttonStyle(.bordered)
                    }

                    TextEditor(text: $coordinator.playgroundText)
                        .font(.system(size: 13.5))
                        .frame(height: 155)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1)
                        )

                    Text("当前引擎：ASR [\(store.settings.asrProvider.displayName)] · LLM [\(store.settings.llmProvider.displayName)]")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }
        }
    }

    private func permissionBadge(title: String, granted: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
                .font(.system(size: 12))
            if !granted {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func statCard(title: String, value: String, unit: String, icon: String, color: Color) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(unit)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func modeChip(mode: WorkMode, hotkey: TriggerKey, desc: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: mode.symbolName)
                    .foregroundStyle(color)
                Text(mode.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text(hotkey.shortBadge)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(color)
            }
            Text(desc)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 2. Engines & API Settings

    private var enginesSettingsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("AI 与语音引擎配置 (BYOK)")
                .font(.system(size: 22, weight: .bold))

            // Quick Presets
            GroupBox("快速预设方案") {
                HStack(spacing: 10) {
                    Button("⚡ Groq 全家桶 (推荐)") {
                        store.settings.asrProvider = .groqWhisper
                        store.settings.llmProvider = .groq
                        if store.settings.asrAPIKey.isEmpty && !store.settings.llmAPIKey.isEmpty {
                            store.settings.asrAPIKey = store.settings.llmAPIKey
                        } else if store.settings.llmAPIKey.isEmpty && !store.settings.asrAPIKey.isEmpty {
                            store.settings.llmAPIKey = store.settings.asrAPIKey
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("🍏 Apple 语音 + DeepSeek") {
                        store.settings.asrProvider = .appleSpeech
                        store.settings.llmProvider = .deepSeek
                    }
                    .buttonStyle(.bordered)

                    Button("✨ Apple 语音 + Gemini") {
                        store.settings.asrProvider = .appleSpeech
                        store.settings.llmProvider = .gemini
                    }
                    .buttonStyle(.bordered)

                    Button("🔒 纯离线本地规则") {
                        store.settings.asrProvider = .appleSpeech
                        store.settings.llmProvider = .localRuleOnly
                    }
                    .buttonStyle(.bordered)
                }
                .padding(6)
            }

            // ASR Section
            GroupBox("1. 语音识别 (ASR)") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("识别引擎", selection: $store.settings.asrProvider) {
                        ForEach(ASRProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }

                    Picker("识别语言", selection: $store.settings.speechLocaleIdentifier) {
                        Text("简体中文 (zh-CN)").tag("zh-CN")
                        Text("English (en-US)").tag("en-US")
                        Text("日本語 (ja-JP)").tag("ja-JP")
                        Text("自动检测 / 多语混说 (仅 Whisper 最佳)").tag("auto")
                    }

                    if store.settings.asrProvider.requiresAPIKey {
                        HStack {
                            if showASRKey {
                                TextField("ASR API Key (如 Groq gsk_... / OpenAI sk-...)", text: $store.settings.asrAPIKey)
                            } else {
                                SecureField("ASR API Key (如 Groq gsk_... / OpenAI sk-...)", text: $store.settings.asrAPIKey)
                            }
                            Button(showASRKey ? "隐藏" : "显示") { showASRKey.toggle() }
                        }

                        TextField("接口地址 (留空使用默认: \(store.settings.asrProvider.defaultEndpoint))", text: $store.settings.asrEndpoint)
                        TextField("模型名 (留空使用默认: \(store.settings.asrProvider.defaultModel))", text: $store.settings.asrModel)
                    } else {
                        Text("macOS 原生语音识别免费且支持离线兜底；若需极速中英混说识别，推荐配置 Groq Whisper（有免费额度，速度极快）。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }

            // LLM Section
            GroupBox("2. AI 文本润色、改写与翻译 (LLM)") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("大模型提供商", selection: $store.settings.llmProvider) {
                        ForEach(LLMProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }

                    if store.settings.llmProvider.requiresAPIKey {
                        HStack {
                            if showLLMKey {
                                TextField("LLM API Key", text: $store.settings.llmAPIKey)
                            } else {
                                SecureField("LLM API Key", text: $store.settings.llmAPIKey)
                            }
                            Button(showLLMKey ? "隐藏" : "显示") { showLLMKey.toggle() }
                        }

                        TextField("Base URL (默认: \(store.settings.llmProvider.defaultBaseURL))", text: $store.settings.llmBaseURL)
                        TextField("模型名 (默认: \(store.settings.llmProvider.defaultModel))", text: $store.settings.llmModel)
                    }

                    HStack(spacing: 12) {
                        Button {
                            testingConnection = true
                            connectionTestMessage = nil
                            Task {
                                let res = await AIVoiceFlowEngine.shared.testLLMConnection(settings: store.settings)
                                testingConnection = false
                                switch res {
                                case .success(let msg):
                                    connectionTestSuccess = true
                                    connectionTestMessage = msg
                                case .failure(let err):
                                    connectionTestSuccess = false
                                    connectionTestMessage = err.localizedDescription
                                }
                            }
                        } label: {
                            if testingConnection {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("测试模型连通性")
                            }
                        }
                        .disabled(testingConnection)

                        if let msg = connectionTestMessage {
                            Text(msg)
                                .font(.system(size: 11.5))
                                .foregroundStyle(connectionTestSuccess == true ? .green : .red)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(8)
            }

            // Prompt & Polish Options
            GroupBox("3. 润色与上下文智能策略") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("自动去除“嗯/啊/那个”等口癖并修正简单自我纠错", isOn: $store.settings.enableFillerRemoval)
                    Toggle("上下文感知语气适配（识别 Xcode/VSCode 保留代码术语，邮件/飞书用正式书面语）", isOn: $store.settings.enableContextToneAdaptation)
                    Toggle("应用个人词典纠偏与术语拼写", isOn: $store.settings.enableDictionaryCorrection)

                    Text("附加自定义 Prompt 规则（可选）")
                        .font(.system(size: 12, weight: .medium))
                    TextField("例如：中英文混排时自动加空格；不要使用感叹号", text: $store.settings.customPromptRules)
                }
                .padding(8)
            }
        }
    }

    // MARK: - 3. Shortcuts & Behavior

    private var shortcutsSettingsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("快捷键与交互偏好")
                .font(.system(size: 22, weight: .bold))

            GroupBox("全局热键绑定") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("口述润色热键 (Dictate)", selection: $store.settings.dictationHotkey) {
                        ForEach(TriggerKey.allCases) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    Picker("选中改写 / Ask Anything 热键", selection: $store.settings.askAnythingHotkey) {
                        ForEach(TriggerKey.allCases) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    Picker("实时翻译热键 (Translate)", selection: $store.settings.translationHotkey) {
                        ForEach(TriggerKey.allCases) { key in
                            Text(key.displayName).tag(key)
                        }
                    }

                    Toggle("当鼠标选中文本时，按主口述键自动切换为 Ask Anything 模式", isOn: $store.settings.autoAskWhenTextSelected)

                    Text("提示：如果 macOS 的 Fn/🌐 键触发了表情符号面板，可在「系统设置 -> 键盘 -> 按下🌐键时」将其改为「不执行任何操作」，或将口述键切换为「右 Option (⌥)」。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox("翻译与窗口显示") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("翻译目标语言")
                        Spacer()
                        Picker("", selection: $store.settings.translationTargetLanguage) {
                            Text("English").tag("English")
                            Text("简体中文").tag("简体中文")
                            Text("日本語").tag("日本語")
                            Text("한국어").tag("한국어")
                            Text("Français").tag("Français")
                            Text("Deutsch").tag("Deutsch")
                        }
                        .frame(width: 180)
                    }

                    Toggle("空闲时也在屏幕底部显示迷你唤醒胶囊", isOn: $store.settings.showFloatingBarWhenIdle)
                        .onChange(of: store.settings.showFloatingBarWhenIdle) { _, _ in
                            coordinator.syncFloatingBarState()
                        }

                    Toggle("在 macOS Dock 栏显示应用图标（关闭后仅保留菜单栏图标）", isOn: $store.settings.showInDock)
                        .onChange(of: store.settings.showInDock) { _, newValue in
                            NSApp.setActivationPolicy(newValue ? .regular : .accessory)
                        }
                }
                .padding(8)
            }
        }
    }

    // MARK: - 4. Dictionary & History

    private var dictionaryAndHistoryView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("个人词典与本地历史")
                    .font(.system(size: 22, weight: .bold))
                Spacer()
                Picker("", selection: $subTab) {
                    Text("历史记录 (\(store.history.count))").tag(0)
                    Text("个人词典 (\(store.dictionary.count))").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }

            if subTab == 0 {
                historyListView
            } else {
                dictionaryListView
            }
        }
    }

    private var historyListView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("搜索历史口述内容或应用名称...", text: $historySearch)
                    .textFieldStyle(.roundedBorder)

                Picker("模式", selection: $historyFilter) {
                    Text("全部").tag(WorkMode?.none)
                    ForEach(WorkMode.allCases) { m in
                        Text(m.shortLabel).tag(WorkMode?.some(m))
                    }
                }
                .frame(width: 120)

                Button("清空全部", role: .destructive) {
                    store.clearHistory()
                }
                .disabled(store.history.isEmpty)
            }

            let filtered = store.history.filter { item in
                let modeMatch = (historyFilter == nil) || (item.mode == historyFilter)
                let q = historySearch.trimmingCharacters(in: .whitespacesAndNewlines)
                let textMatch = q.isEmpty ||
                    item.refinedText.localizedCaseInsensitiveContains(q) ||
                    item.rawText.localizedCaseInsensitiveContains(q) ||
                    item.appName.localizedCaseInsensitiveContains(q)
                return modeMatch && textMatch
            }

            if filtered.isEmpty {
                ContentUnavailableView("暂无匹配的本地记录", systemImage: "waveform", description: Text("所有口述记录仅保存在本地 Application Support/TypelessLite 目录中。"))
                    .frame(minHeight: 260)
            } else {
                ForEach(filtered) { item in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(item.mode.shortLabel, systemImage: item.mode.symbolName)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.blue)
                                if !item.appName.isEmpty {
                                    Text(item.appName)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Text(String(format: "%.1fs", item.durationSeconds))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Text(item.createdAt, style: .relative)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)

                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(item.refinedText, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help("复制结果")

                                Button(role: .destructive) {
                                    store.deleteHistory(id: item.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("删除此条")
                            }

                            Text(item.refinedText)
                                .font(.system(size: 13))
                                .textSelection(.enabled)

                            if item.rawText != item.refinedText && !item.rawText.isEmpty {
                                Text("原始识别：\(item.rawText)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(4)
                    }
                }
            }
        }
    }

    private var dictionaryListView: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("添加专有名词或纠偏词汇") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        TextField("标准拼写 (如 Kubernetes)", text: $newTerm)
                        TextField("常见误识别别名，逗号分隔 (如 k8s, 酷伯内特斯)", text: $newAliases)
                    }
                    HStack(spacing: 10) {
                        TextField("备注（可选）", text: $newNote)
                        Button("添加词条") {
                            let aliases = newAliases
                                .split(separator: ",")
                                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                            store.addDictionaryEntry(term: newTerm, aliases: aliases, note: newNote)
                            newTerm = ""
                            newAliases = ""
                            newNote = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(6)
            }

            ForEach(store.dictionary) { entry in
                GroupBox {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(entry.term)
                                    .font(.system(size: 13.5, weight: .semibold))
                                if !entry.note.isEmpty {
                                    Text(entry.note)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if !entry.aliases.isEmpty {
                                Text("替换别名：\(entry.aliases.joined(separator: "、"))")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) {
                            store.deleteDictionaryEntry(id: entry.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(2)
                }
            }
        }
    }
}
