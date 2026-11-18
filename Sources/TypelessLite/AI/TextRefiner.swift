import Foundation

/// Pure local text cleaning engine (filler removal, simple self-correction, personal dictionary substitution)
/// and structured LLM prompt builder for Dictation, Ask Anything, and Translation modes.
public enum TextRefiner {
    /// Applies user's personal dictionary aliases -> canonical term replacements.
    public static func applyDictionary(_ text: String, entries: [DictionaryEntry]) -> String {
        guard !text.isEmpty, !entries.isEmpty else { return text }
        var output = text

        for entry in entries {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            for alias in entry.aliases {
                let cleanAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanAlias.isEmpty else { continue }

                let isASCIIWord = cleanAlias.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == " ") }
                let escaped = NSRegularExpression.escapedPattern(for: cleanAlias)
                let pattern = isASCIIWord ? "\\b\(escaped)\\b" : escaped

                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    let range = NSRange(output.startIndex..., in: output)
                    output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: NSRegularExpression.escapedTemplate(for: term))
                }
            }
        }
        return output
    }

    /// Deterministic local cleaner used when LLM is disabled or unavailable as offline fallback.
    public static func localClean(
        _ rawText: String,
        tone: ToneStyle = .neutral,
        removeFillers: Bool = true,
        dictionary: [DictionaryEntry] = [],
        applyDictionaryReplacements: Bool = true
    ) -> String {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        if removeFillers {
            // 1. Remove leading hesitation syllables with punctuation (e.g., "嗯，那个，我们今天..." -> "我们今天...")
            text = replacingRegex(
                text,
                pattern: "^(?:[嗯啊呃哦唉嘿]+[，,、。\\s]*)+",
                with: ""
            )

            // 2. Remove mid-sentence Chinese hesitation fillers surrounded by boundaries
            text = replacingRegex(
                text,
                pattern: "(?:^|[，,。\\s])(?:呃+|嗯+|啊+|那个(?=[，,、\\s])|就是说(?=[，,、\\s])|怎么说呢(?=[，,、\\s])|然后呢(?=[，,、\\s]))[，,、\\s]*",
                with: " "
            )

            // 3. Remove English verbal fillers (um, uh, er, ah, you know, I mean)
            text = replacingRegex(
                text,
                pattern: "(?i)[,\\s]+\\b(?:you know|i mean)\\b[,\\s]+",
                with: " "
            )
            text = replacingRegex(
                text,
                pattern: "(?i)(?:^|(?<=[\\s,]))\\b(?:um+|uh+|er+|ah+|you know|i mean)\\b[,.]*\\s*",
                with: ""
            )

            // 4. Handle explicit spoken self-correction markers in Chinese & English
            // Example: "明天下午三点，不对，四点开会" -> "明天下午四点开会" or "周三，不对，周四" -> "周四"
            text = applySimpleSelfCorrection(text)
        }

        // Normalize duplicate spaces & orphan punctuation
        text = replacingRegex(text, pattern: "\\s{2,}", with: " ")
        text = replacingRegex(text, pattern: "^[，,、；;\\s]+", with: "")
        text = replacingRegex(text, pattern: "([，,、。！？!?])\\1+", with: "$1")
        text = replacingRegex(text, pattern: "\\s+([，,。！？!?；;：:])", with: "$1")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Capitalize leading ASCII letter if text starts with lowercase ASCII
        if let first = text.first, first.isASCII && first.isLowercase, tone != .codeFriendly {
            text = first.uppercased() + text.dropFirst()
        }

        if applyDictionaryReplacements {
            text = applyDictionary(text, entries: dictionary)
        }

        return text
    }

    private static func applySimpleSelfCorrection(_ input: String) -> String {
        var text = input
        // Handle Chinese phrase-level corrections: "X，不对，Y" / "X，算了，Y" / "X，不是，Y"
        let cnMarkers = ["不对", "不是", "算了", "我是说", "重说一下"]
        for marker in cnMarkers {
            let pattern = "[^，,。！？\n]{1,14}[，,\\s]+\(marker)[，,\\s]+"
            text = replacingRegex(text, pattern: pattern, with: "")
        }

        // Handle English corrections: "X, no wait, Y" / "X, wait no, Y" / "X, actually, Y"
        let enPattern = "(?i)\\b[\\w'-]{1,20}[,\\s]+(?:no wait|wait no|sorry|actually)[,\\s]+"
        text = replacingRegex(text, pattern: enPattern, with: "")
        return text
    }

    private static func replacingRegex(_ input: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return input
        }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)
    }

    // MARK: - Prompt Builder (Replacing Typeless /ai/voice_flow Server Prompts)

    public static func buildPrompts(
        mode: WorkMode,
        rawTranscript: String,
        context: AppContextInfo,
        settings: AppSettings,
        dictionary: [DictionaryEntry]
    ) -> (system: String, user: String) {
        let vocabTerms = dictionary.map { entry -> String in
            if entry.aliases.isEmpty {
                return entry.term
            }
            return "\(entry.term) (spoken variants: \(entry.aliases.joined(separator: ", ")))"
        }
        let vocabBlock = vocabTerms.isEmpty
            ? ""
            : "\nPersonal Vocabulary (always use exact spelling when referenced): \(vocabTerms.joined(separator: "; "))."

        let contextBlock: String
        if settings.enableContextToneAdaptation {
            var parts: [String] = []
            if !context.appName.isEmpty { parts.append("Active App: \(context.appName)") }
            if let domain = context.webDomain, !domain.isEmpty { parts.append("Website: \(domain)") }
            if !context.windowTitle.isEmpty { parts.append("Window: \(context.windowTitle)") }
            parts.append("Style Guidance: \(context.detectedTone.promptInstruction)")
            if !context.beforeText.isEmpty {
                parts.append("Text before cursor: \"\(context.beforeText.suffix(180))\"")
            }
            contextBlock = "\nContext:\n" + parts.joined(separator: "\n")
        } else {
            contextBlock = ""
        }

        let extraRules = settings.customPromptRules.trimmingCharacters(in: .whitespacesAndNewlines)
        let extraBlock = extraRules.isEmpty ? "" : "\nUser Custom Rules:\n\(extraRules)"

        switch mode {
        case .dictation:
            let system = """
            You are TypelessLite, an ultra-fast voice dictation refiner.
            Transform raw speech-to-text transcripts into clean, ready-to-paste written text.
            Rules:
            1. Remove filler words and hesitations ("嗯", "啊", "呃", "那个", "就是说", "um", "uh", "you know", "like").
            2. Resolve mid-sentence self-corrections or restarts cleanly, keeping only the speaker's final intended statement.
            3. Fix obvious homophone/ASR errors, add proper punctuation, and format numbered/bulleted lists when the speaker enumerates items.
            4. Preserve the speaker's original language(s) (including mixed Chinese + English technical terms). Do NOT translate unless asked.
            5. Output ONLY the final refined text with no commentary, quotes, or markdown wrappers.\(vocabBlock)\(contextBlock)\(extraBlock)
            """
            let user = "Raw transcript:\n\(rawTranscript)"
            return (system, user)

        case .translation:
            let targetLang = settings.translationTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "English"
                : settings.translationTargetLanguage
            let system = """
            You are TypelessLite, a real-time speech translator and editor.
            Rules:
            1. Clean filler words, stutters, and self-corrections from the raw transcript.
            2. Translate the final intended message naturally and idiomatically into \(targetLang).
            3. Output ONLY the translated text with no commentary or quotes.\(vocabBlock)\(contextBlock)\(extraBlock)
            """
            let user = "Raw transcript:\n\(rawTranscript)"
            return (system, user)

        case .askAnything:
            let system = """
            You are TypelessLite AI Assistant, handling voice commands on macOS.
            Determine whether the user wants to:
            - "replace": rewrite, polish, shorten, expand, fix, translate, or draft text directly into their editor.
            - "card": ask a question, request an explanation, summarize, or get an answer in a floating popup card without overwriting their text.
            Respond strictly with a single JSON object (no markdown code fences):
            {"delivery": "replace" | "card", "result": "<final text or answer>"}\(vocabBlock)\(contextBlock)\(extraBlock)
            """
            let selectedSection = context.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "(No text selected)"
                : context.selectedText
            let user = """
            Selected Text:
            \(selectedSection)

            Voice Command:
            \(rawTranscript)
            """
            return (system, user)
        }
    }

    /// Parses Ask Anything JSON output cleanly even if a model wraps it in markdown fences.
    public static func parseAskAnythingResponse(_ content: String, voicePrompt: String, hasSelectedText: Bool) -> (delivery: VoiceFlowResult.DeliveryType, text: String) {
        var cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = replacingRegex(cleaned, pattern: "^```(?:json)?\\s*", with: "")
            cleaned = replacingRegex(cleaned, pattern: "\\s*```$", with: "")
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let data = cleaned.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = json["result"] as? String {
            let deliveryRaw = (json["delivery"] as? String ?? "").lowercased()
            let delivery: VoiceFlowResult.DeliveryType = (deliveryRaw == "card") ? .card : .replaceOrInsert
            return (delivery, result.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Heuristic fallback when custom local models reply with plain text instead of JSON
        let fallbackDelivery = classifyAskAnythingFallback(voicePrompt: voicePrompt, hasSelectedText: hasSelectedText)
        return (fallbackDelivery, cleaned)
    }

    public static func classifyAskAnythingFallback(voicePrompt: String, hasSelectedText: Bool) -> VoiceFlowResult.DeliveryType {
        let lower = voicePrompt.lowercased()
        let questionKeywords = ["什么", "为什么", "怎么", "解释", "总结", "概括", "含义", "意思", "explain", "summarize", "what is", "why", "how", "?"]
        if questionKeywords.contains(where: { lower.contains($0) }) || !hasSelectedText {
            let writeCommands = ["帮我写", "起草", "回复", "生成", "翻译", "改写", "润色", "write", "draft", "reply", "rewrite", "translate"]
            if writeCommands.contains(where: { lower.contains($0) }) {
                return .replaceOrInsert
            }
            return .card
        }
        return .replaceOrInsert
    }
}
