import Foundation
import AppKit

/// Three core voice workflow modes reverse-engineered from Typeless (/ai/voice_flow)
public enum WorkMode: String, Codable, CaseIterable, Identifiable {
    case dictation = "voice_transcript"
    case askAnything = "voice_command"
    case translation = "voice_translation"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dictation: return "口述润色"
        case .askAnything: return "选中改写 / 提问"
        case .translation: return "实时翻译"
        }
    }

    public var shortLabel: String {
        switch self {
        case .dictation: return "口述"
        case .askAnything: return "AI 指令"
        case .translation: return "翻译"
        }
    }

    public var symbolName: String {
        switch self {
        case .dictation: return "mic.fill"
        case .askAnything: return "sparkles"
        case .translation: return "globe"
        }
    }
}

/// Real-time dictation state machine
public enum SessionState: Equatable {
    case idle
    case recording(mode: WorkMode, isHandsFree: Bool, startedAt: Date)
    case processing(mode: WorkMode, stage: String)
    case completedPreview(text: String)
    case error(message: String)

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    public var isProcessing: Bool {
        if case .processing = self { return true }
        return false
    }

    public var activeMode: WorkMode? {
        switch self {
        case .recording(let mode, _, _), .processing(let mode, _):
            return mode
        default:
            return nil
        }
    }
}

/// Global hotkeys supported by KeyboardMonitor
public enum TriggerKey: String, Codable, CaseIterable, Identifiable {
    case fnKey = "fn"
    case rightOption = "right_option"
    case rightCommand = "right_command"
    case optionSpace = "option_space"
    case f5 = "f5"
    case disabled = "disabled"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fnKey: return "Fn / 🌐 键"
        case .rightOption: return "右 Option (⌥)"
        case .rightCommand: return "右 Command (⌘)"
        case .optionSpace: return "Option + Space (⌥␣)"
        case .f5: return "F5 键"
        case .disabled: return "禁用"
        }
    }

    public var shortBadge: String {
        switch self {
        case .fnKey: return "Fn"
        case .rightOption: return "右 ⌥"
        case .rightCommand: return "右 ⌘"
        case .optionSpace: return "⌥ Space"
        case .f5: return "F5"
        case .disabled: return "无"
        }
    }

    public var isModifierOnly: Bool {
        switch self {
        case .fnKey, .rightOption, .rightCommand: return true
        case .optionSpace, .f5, .disabled: return false
        }
    }
}

/// Speech-to-Text providers (Apple local Speech framework fallback + Whisper APIs)
public enum ASRProvider: String, Codable, CaseIterable, Identifiable {
    case appleSpeech = "apple_speech"
    case groqWhisper = "groq_whisper"
    case openAIWhisper = "openai_whisper"
    case customWhisper = "custom_whisper"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleSpeech: return "macOS 原生语音识别 (离线/免费)"
        case .groqWhisper: return "Groq Whisper (极速)"
        case .openAIWhisper: return "OpenAI Whisper"
        case .customWhisper: return "自定义 Whisper 兼容接口"
        }
    }

    public var defaultEndpoint: String {
        switch self {
        case .appleSpeech: return ""
        case .groqWhisper: return "https://api.groq.com/openai/v1/audio/transcriptions"
        case .openAIWhisper: return "https://api.openai.com/v1/audio/transcriptions"
        case .customWhisper: return "https://api.openai.com/v1/audio/transcriptions"
        }
    }

    public var defaultModel: String {
        switch self {
        case .appleSpeech: return "SFSpeechRecognizer"
        case .groqWhisper: return "whisper-large-v3-turbo"
        case .openAIWhisper: return "whisper-1"
        case .customWhisper: return "whisper-1"
        }
    }

    public var requiresAPIKey: Bool {
        self != .appleSpeech
    }
}

/// LLM providers for text polishing, self-correction, Ask Anything, and translation
public enum LLMProvider: String, Codable, CaseIterable, Identifiable {
    case localRuleOnly = "local_rule"
    case groq = "groq"
    case openAI = "openai"
    case deepSeek = "deepseek"
    case gemini = "gemini"
    case customOpenAI = "custom_openai"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .localRuleOnly: return "仅本地规则去口癖 (零网络/免费)"
        case .groq: return "Groq (Llama 3.3 70B)"
        case .openAI: return "OpenAI (GPT-4o mini)"
        case .deepSeek: return "DeepSeek (deepseek-chat)"
        case .gemini: return "Google Gemini (2.5 Flash)"
        case .customOpenAI: return "自定义 OpenAI 兼容接口"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .localRuleOnly: return ""
        case .groq: return "https://api.groq.com/openai/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .customOpenAI: return "http://127.0.0.1:11434/v1"
        }
    }

    public var defaultModel: String {
        switch self {
        case .localRuleOnly: return "local-regex-cleaner"
        case .groq: return "llama-3.3-70b-versatile"
        case .openAI: return "gpt-4o-mini"
        case .deepSeek: return "deepseek-chat"
        case .gemini: return "gemini-2.5-flash"
        case .customOpenAI: return "qwen2.5:7b"
        }
    }

    public var requiresAPIKey: Bool {
        self != .localRuleOnly
    }
}

/// Context-aware tone inferred from focused application / website
public enum ToneStyle: String, Codable, CaseIterable {
    case codeFriendly = "code_friendly"
    case professional = "professional"
    case casual = "casual"
    case neutral = "neutral"

    public var displayName: String {
        switch self {
        case .codeFriendly: return "编程/终端"
        case .professional: return "商务/邮件"
        case .casual: return "聊天/笔记"
        case .neutral: return "通用清晰"
        }
    }

    public var promptInstruction: String {
        switch self {
        case .codeFriendly:
            return "The user is working in a code editor, terminal, or developer tool. Preserve English technical terms, camelCase/snake_case identifiers, CLI commands, and code symbols accurately without translating them into Chinese."
        case .professional:
            return "The user is writing in a professional communication or document app (email, workspace chat, docs). Use clear, polite, well-structured language and proper punctuation."
        case .casual:
            return "The user is in an instant messaging or personal notes app. Keep the tone natural, concise, and conversational while still removing verbal fillers and stutters."
        case .neutral:
            return "Produce clean, well-punctuated, natural written text matching the speaker's original intent and tone."
        }
    }
}

/// Focused app & accessibility context captured right when dictation starts
public struct AppContextInfo: Codable, Equatable {
    public var appName: String
    public var bundleId: String
    public var windowTitle: String
    public var webURL: String?
    public var webDomain: String?
    public var selectedText: String
    public var beforeText: String
    public var afterText: String
    public var detectedTone: ToneStyle

    public init(
        appName: String = "",
        bundleId: String = "",
        windowTitle: String = "",
        webURL: String? = nil,
        webDomain: String? = nil,
        selectedText: String = "",
        beforeText: String = "",
        afterText: String = "",
        detectedTone: ToneStyle = .neutral
    ) {
        self.appName = appName
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.webURL = webURL
        self.webDomain = webDomain
        self.selectedText = selectedText
        self.beforeText = beforeText
        self.afterText = afterText
        self.detectedTone = detectedTone
    }

    /// Infer communication tone from bundleId, appName, and active web domain
    public static func inferTone(bundleId: String, appName: String, webDomain: String?) -> ToneStyle {
        let bundle = bundleId.lowercased()
        let name = appName.lowercased()
        let domain = (webDomain ?? "").lowercased()

        let codeBundles = [
            "com.apple.dt.xcode", "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92",
            "com.cursor", "com.jetbrains", "com.googlecode.iterm2", "com.apple.terminal",
            "dev.warp.warp-stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
            "com.sublimetext", "dev.zed.zed", "com.trae"
        ]
        if codeBundles.contains(where: { bundle.contains($0) }) ||
            ["xcode", "cursor", "visual studio code", "code", "terminal", "iterm2", "warp", "ghostty", "zed"].contains(where: { name.contains($0) }) ||
            domain.contains("github.com") || domain.contains("gitlab") {
            return .codeFriendly
        }

        let workBundles = [
            "com.apple.mail", "com.microsoft.outlook", "com.tinyspeck.slackmacgap",
            "com.electron.lark", "com.bytedance.feishu", "com.alibaba.dingtalkmac",
            "notion.id", "com.linear", "com.figma.desktop", "md.obsidian"
        ]
        if workBundles.contains(where: { bundle.contains($0) }) ||
            ["mail", "outlook", "slack", "feishu", "lark", "dingtalk", "钉钉", "飞书", "notion", "pages", "word"].contains(where: { name.contains($0) }) ||
            ["mail.google.com", "docs.google.com", "notion.so", "figma.com", "docs.qq.com"].contains(where: { domain.contains($0) }) {
            return .professional
        }

        let chatBundles = [
            "com.tencent.xinwechat", "com.tencent.qq", "ru.keepcoder.telegram",
            "com.apple.mobilesms", "com.apple.notes", "com.hnc.discord"
        ]
        if chatBundles.contains(where: { bundle.contains($0) }) ||
            ["wechat", "微信", "qq", "telegram", "messages", "信息", "notes", "备忘录", "discord"].contains(where: { name.contains($0) }) {
            return .casual
        }

        return .neutral
    }
}

/// Output produced by AIVoiceFlowEngine
public struct VoiceFlowResult: Equatable {
    public enum DeliveryType: String, Codable, Equatable {
        case replaceOrInsert
        case card
        case noOp
    }

    public var rawTranscript: String
    public var refinedText: String
    public var delivery: DeliveryType
    public var durationSeconds: Double
    public var asrEngineUsed: String
    public var llmEngineUsed: String
    public var usedFallbackLocalOnly: Bool
    public var warningMessage: String?

    public init(
        rawTranscript: String,
        refinedText: String,
        delivery: DeliveryType,
        durationSeconds: Double,
        asrEngineUsed: String,
        llmEngineUsed: String,
        usedFallbackLocalOnly: Bool = false,
        warningMessage: String? = nil
    ) {
        self.rawTranscript = rawTranscript
        self.refinedText = refinedText
        self.delivery = delivery
        self.durationSeconds = durationSeconds
        self.asrEngineUsed = asrEngineUsed
        self.llmEngineUsed = llmEngineUsed
        self.usedFallbackLocalOnly = usedFallbackLocalOnly
        self.warningMessage = warningMessage
    }
}

/// Personal vocabulary entry to boost accuracy & apply deterministic corrections
public struct DictionaryEntry: Codable, Identifiable, Equatable {
    public enum EntrySource: String, Codable {
        case manual
        case autoLearned
    }

    public var id: UUID
    public var term: String
    public var aliases: [String]
    public var note: String
    public var source: EntrySource
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        term: String,
        aliases: [String] = [],
        note: String = "",
        source: EntrySource = .manual,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.term = term
        self.aliases = aliases
        self.note = note
        self.source = source
        self.createdAt = createdAt
    }
}

/// Local dictation/command history record (strictly local, zero cloud sync)
public struct HistoryRecord: Codable, Identifiable, Equatable {
    public var id: UUID
    public var mode: WorkMode
    public var rawText: String
    public var refinedText: String
    public var selectedContextText: String
    public var appName: String
    public var bundleId: String
    public var durationSeconds: Double
    public var delivery: String
    public var asrEngine: String
    public var llmEngine: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        mode: WorkMode,
        rawText: String,
        refinedText: String,
        selectedContextText: String = "",
        appName: String = "",
        bundleId: String = "",
        durationSeconds: Double = 0,
        delivery: String = "insert",
        asrEngine: String = "",
        llmEngine: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.mode = mode
        self.rawText = rawText
        self.refinedText = refinedText
        self.selectedContextText = selectedContextText
        self.appName = appName
        self.bundleId = bundleId
        self.durationSeconds = durationSeconds
        self.delivery = delivery
        self.asrEngine = asrEngine
        self.llmEngine = llmEngine
        self.createdAt = createdAt
    }
}

/// Payload shown in InteractiveCardPanel for Ask Anything answers
public struct InteractiveCardPayload: Equatable, Identifiable {
    public var id: UUID
    public var selectedText: String
    public var voicePrompt: String
    public var answer: String
    public var appName: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        selectedText: String,
        voicePrompt: String,
        answer: String,
        appName: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.selectedText = selectedText
        self.voicePrompt = voicePrompt
        self.answer = answer
        self.appName = appName
        self.createdAt = createdAt
    }
}

/// User settings stored locally in UserDefaults
public struct AppSettings: Codable, Equatable {
    public var dictationHotkey: TriggerKey = .fnKey
    public var askAnythingHotkey: TriggerKey = .optionSpace
    public var translationHotkey: TriggerKey = .f5
    public var autoAskWhenTextSelected: Bool = false

    public var asrProvider: ASRProvider = .appleSpeech
    public var asrAPIKey: String = ""
    public var asrEndpoint: String = ""
    public var asrModel: String = ""
    public var speechLocaleIdentifier: String = "zh-CN"

    public var llmProvider: LLMProvider = .localRuleOnly
    public var llmAPIKey: String = ""
    public var llmBaseURL: String = ""
    public var llmModel: String = ""

    public var translationTargetLanguage: String = "English"
    public var enableContextToneAdaptation: Bool = true
    public var enableFillerRemoval: Bool = true
    public var enableDictionaryCorrection: Bool = true
    public var muteSystemAudioWhileRecording: Bool = false
    public var showFloatingBarWhenIdle: Bool = false
    public var showInDock: Bool = true
    public var customPromptRules: String = ""

    public init() {}

    public var effectiveASREndpoint: String {
        let trimmed = asrEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? asrProvider.defaultEndpoint : trimmed
    }

    public var effectiveASRModel: String {
        let trimmed = asrModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? asrProvider.defaultModel : trimmed
    }

    public var effectiveLLMBaseURL: String {
        let trimmed = llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? llmProvider.defaultBaseURL : trimmed
    }

    public var effectiveLLMModel: String {
        let trimmed = llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? llmProvider.defaultModel : trimmed
    }
}
