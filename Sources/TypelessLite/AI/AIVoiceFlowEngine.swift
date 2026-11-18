import Foundation

/// Clean-room replacement for Typeless's proprietary /ai/voice_flow backend.
/// Orchestrates ASR (Apple Speech or Groq/OpenAI Whisper) + LLM (Groq/OpenAI/DeepSeek/Gemini/Custom or Local Rule Cleaner).
public final class AIVoiceFlowEngine {
    public static let shared = AIVoiceFlowEngine()

    private let session: URLSession
    private var currentTask: Task<VoiceFlowResult, Error>?

    public init(session: URLSession = .shared) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 45
        self.session = URLSession(configuration: config)
    }

    public func cancelCurrent() {
        currentTask?.cancel()
        currentTask = nil
    }

    public func processVoiceFlow(
        audioURL: URL,
        duration: Double,
        mode: WorkMode,
        context: AppContextInfo,
        settings: AppSettings,
        dictionary: [DictionaryEntry]
    ) async throws -> VoiceFlowResult {
        var warningNotes: [String] = []

        // 1. Speech-to-Text (ASR)
        let rawTranscript: String
        let asrEngineUsed: String

        let trimmedASRKey = settings.asrAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.asrProvider == .appleSpeech || (settings.asrProvider.requiresAPIKey && trimmedASRKey.isEmpty) {
            if settings.asrProvider.requiresAPIKey && trimmedASRKey.isEmpty {
                warningNotes.append("未填写 \(settings.asrProvider.displayName) Key，已自动降级为 macOS 原生语音识别")
            }
            asrEngineUsed = ASRProvider.appleSpeech.defaultModel
            rawTranscript = try await AudioRecorder.shared.transcribeWithAppleSpeech(
                fileURL: audioURL,
                localeIdentifier: settings.speechLocaleIdentifier,
                contextualStrings: dictionary.map(\.term)
            )
        } else {
            asrEngineUsed = "\(settings.asrProvider.rawValue):\(settings.effectiveASRModel)"
            rawTranscript = try await transcribeWithWhisperAPI(
                audioURL: audioURL,
                endpoint: settings.effectiveASREndpoint,
                apiKey: trimmedASRKey,
                model: settings.effectiveASRModel,
                localeIdentifier: settings.speechLocaleIdentifier,
                dictionaryTerms: dictionary.map(\.term)
            )
        }

        let cleanedRaw = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedRaw.isEmpty {
            return VoiceFlowResult(
                rawTranscript: "",
                refinedText: "",
                delivery: .noOp,
                durationSeconds: duration,
                asrEngineUsed: asrEngineUsed,
                llmEngineUsed: "none",
                usedFallbackLocalOnly: true,
                warningMessage: "未检测到清晰语音内容"
            )
        }

        // 2. AI Refinement / Command / Translation
        let trimmedLLMKey = settings.llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let canUseCloudLLM: Bool = {
            switch settings.llmProvider {
            case .localRuleOnly:
                return false
            case .customOpenAI:
                return !settings.effectiveLLMBaseURL.isEmpty
            default:
                return !trimmedLLMKey.isEmpty
            }
        }()

        if !canUseCloudLLM {
            if settings.llmProvider != .localRuleOnly {
                warningNotes.append("未配置 \(settings.llmProvider.displayName) API Key，已使用本地规则去口癖处理")
            }
            return localFallbackResult(
                rawTranscript: cleanedRaw,
                duration: duration,
                mode: mode,
                context: context,
                settings: settings,
                dictionary: dictionary,
                asrEngineUsed: asrEngineUsed,
                warning: warningNotes.isEmpty ? nil : warningNotes.joined(separator: "；")
            )
        }

        let prompts = TextRefiner.buildPrompts(
            mode: mode,
            rawTranscript: cleanedRaw,
            context: context,
            settings: settings,
            dictionary: dictionary
        )

        do {
            let llmOutput = try await callChatCompletions(
                baseURL: settings.effectiveLLMBaseURL,
                apiKey: trimmedLLMKey,
                model: settings.effectiveLLMModel,
                systemPrompt: prompts.system,
                userPrompt: prompts.user
            )

            let finalDictCleaned = settings.enableDictionaryCorrection
                ? TextRefiner.applyDictionary(llmOutput, entries: dictionary)
                : llmOutput

            switch mode {
            case .dictation, .translation:
                return VoiceFlowResult(
                    rawTranscript: cleanedRaw,
                    refinedText: finalDictCleaned.trimmingCharacters(in: .whitespacesAndNewlines),
                    delivery: .replaceOrInsert,
                    durationSeconds: duration,
                    asrEngineUsed: asrEngineUsed,
                    llmEngineUsed: "\(settings.llmProvider.rawValue):\(settings.effectiveLLMModel)",
                    usedFallbackLocalOnly: false,
                    warningMessage: warningNotes.isEmpty ? nil : warningNotes.joined(separator: "；")
                )

            case .askAnything:
                let parsed = TextRefiner.parseAskAnythingResponse(
                    finalDictCleaned,
                    voicePrompt: cleanedRaw,
                    hasSelectedText: !context.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                return VoiceFlowResult(
                    rawTranscript: cleanedRaw,
                    refinedText: parsed.text,
                    delivery: parsed.delivery,
                    durationSeconds: duration,
                    asrEngineUsed: asrEngineUsed,
                    llmEngineUsed: "\(settings.llmProvider.rawValue):\(settings.effectiveLLMModel)",
                    usedFallbackLocalOnly: false,
                    warningMessage: warningNotes.isEmpty ? nil : warningNotes.joined(separator: "；")
                )
            }
        } catch {
            warningNotes.append("AI 请求失败(\(error.localizedDescription))，已降级为本地规则输出")
            return localFallbackResult(
                rawTranscript: cleanedRaw,
                duration: duration,
                mode: mode,
                context: context,
                settings: settings,
                dictionary: dictionary,
                asrEngineUsed: asrEngineUsed,
                warning: warningNotes.joined(separator: "；")
            )
        }
    }

    private func localFallbackResult(
        rawTranscript: String,
        duration: Double,
        mode: WorkMode,
        context: AppContextInfo,
        settings: AppSettings,
        dictionary: [DictionaryEntry],
        asrEngineUsed: String,
        warning: String?
    ) -> VoiceFlowResult {
        let cleaned = TextRefiner.localClean(
            rawTranscript,
            tone: settings.enableContextToneAdaptation ? context.detectedTone : .neutral,
            removeFillers: settings.enableFillerRemoval,
            dictionary: dictionary,
            applyDictionaryReplacements: settings.enableDictionaryCorrection
        )

        switch mode {
        case .dictation:
            return VoiceFlowResult(
                rawTranscript: rawTranscript,
                refinedText: cleaned,
                delivery: .replaceOrInsert,
                durationSeconds: duration,
                asrEngineUsed: asrEngineUsed,
                llmEngineUsed: LLMProvider.localRuleOnly.defaultModel,
                usedFallbackLocalOnly: true,
                warningMessage: warning
            )
        case .translation:
            return VoiceFlowResult(
                rawTranscript: rawTranscript,
                refinedText: cleaned,
                delivery: .replaceOrInsert,
                durationSeconds: duration,
                asrEngineUsed: asrEngineUsed,
                llmEngineUsed: LLMProvider.localRuleOnly.defaultModel,
                usedFallbackLocalOnly: true,
                warningMessage: warning ?? "翻译模式需要配置 LLM API Key（当前仅输出本地清理文本）"
            )
        case .askAnything:
            let cardText = """
            【指令】\(cleaned)
            \(context.selectedText.isEmpty ? "" : "\n【选中原文】\n\(context.selectedText)\n")
            提示：当前为纯本地规则模式，未连接大语言模型。请在「AI 引擎」设置中配置 Groq / DeepSeek / OpenAI / Gemini 或本地 Ollama，即可开启智能改写与问答卡片。
            """
            return VoiceFlowResult(
                rawTranscript: rawTranscript,
                refinedText: cardText.trimmingCharacters(in: .whitespacesAndNewlines),
                delivery: .card,
                durationSeconds: duration,
                asrEngineUsed: asrEngineUsed,
                llmEngineUsed: LLMProvider.localRuleOnly.defaultModel,
                usedFallbackLocalOnly: true,
                warningMessage: warning
            )
        }
    }

    // MARK: - Connection Self-Test

    public func testLLMConnection(settings: AppSettings) async -> Result<String, Error> {
        if settings.llmProvider == .localRuleOnly {
            return .success("当前为纯本地规则模式，无需网络连接即可离线工作。")
        }
        let key = settings.llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.llmProvider != .customOpenAI && key.isEmpty {
            return .failure(NSError(domain: "TypelessLite", code: 400, userInfo: [NSLocalizedDescriptionKey: "请先填写 API Key"]))
        }
        do {
            let reply = try await callChatCompletions(
                baseURL: settings.effectiveLLMBaseURL,
                apiKey: key,
                model: settings.effectiveLLMModel,
                systemPrompt: "Reply with a short greeting confirming connection works.",
                userPrompt: "Ping"
            )
            return .success("连接成功 (\(settings.effectiveLLMModel)): \(reply.prefix(80))")
        } catch {
            return .failure(error)
        }
    }

    // MARK: - HTTP Requests

    private func transcribeWithWhisperAPI(
        audioURL: URL,
        endpoint: String,
        apiKey: String,
        model: String,
        localeIdentifier: String,
        dictionaryTerms: [String]
    ) async throws -> String {
        guard let url = URL(string: endpoint) else {
            throw NSError(domain: "TypelessLite.ASR", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的 ASR 接口地址"])
        }

        let audioData = try Data(contentsOf: audioURL)
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField(name: "model", value: model)
        appendField(name: "response_format", value: "json")

        if localeIdentifier != "auto", let langCode = localeIdentifier.split(separator: "-").first, !langCode.isEmpty {
            appendField(name: "language", value: String(langCode))
        }
        if !dictionaryTerms.isEmpty {
            appendField(name: "prompt", value: dictionaryTerms.prefix(30).joined(separator: ", "))
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "TypelessLite.ASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效网络响应"])
        }
        guard (200...299).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "TypelessLite.ASR", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "ASR HTTP \(http.statusCode): \(errBody.prefix(200))"])
        }

        struct WhisperResponse: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(WhisperResponse.self, from: data)
        return decoded.text
    }

    private func callChatCompletions(
        baseURL: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let urlString = trimmedBase.hasSuffix("/chat/completions") ? trimmedBase : "\(trimmedBase)/chat/completions"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "TypelessLite.LLM", code: 400, userInfo: [NSLocalizedDescriptionKey: "无效的 LLM Base URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "TypelessLite.LLM", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效网络响应"])
        }
        guard (200...299).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "TypelessLite.LLM", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "LLM HTTP \(http.statusCode): \(errBody.prefix(200))"])
        }

        struct ChatCompletionResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw NSError(domain: "TypelessLite.LLM", code: -2, userInfo: [NSLocalizedDescriptionKey: "模型返回为空"])
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
