import Foundation
import Combine

/// Local persistence manager (UserDefaults for settings + JSON files in Application Support for history & dictionary).
/// Strictly local-only: no telemetry, no cloud sync, no account tokens.
@MainActor
public final class LocalStore: ObservableObject {
    public static let shared = LocalStore()

    @Published public var settings: AppSettings {
        didSet { saveSettings() }
    }
    @Published public var history: [HistoryRecord] = []
    @Published public var dictionary: [DictionaryEntry] = []

    private let baseDirectory: URL
    private let userDefaults: UserDefaults
    private let settingsKey = "TypelessLite.AppSettings.v1"

    public init(baseDirectory: URL? = nil, userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let dir = baseDirectory {
            self.baseDirectory = dir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.baseDirectory = appSupport.appendingPathComponent("TypelessLite", isDirectory: true)
        }

        if let data = userDefaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = AppSettings()
        }

        ensureDirectoryExists()
        loadDictionary()
        loadHistory()
    }

    private var historyFileURL: URL {
        baseDirectory.appendingPathComponent("history.json")
    }

    private var dictionaryFileURL: URL {
        baseDirectory.appendingPathComponent("dictionary.json")
    }

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            userDefaults.set(data, forKey: settingsKey)
        }
    }

    // MARK: - History Management

    public func loadHistory() {
        guard FileManager.default.fileExists(atPath: historyFileURL.path),
              let data = try? Data(contentsOf: historyFileURL),
              let decoded = try? JSONDecoder().decode([HistoryRecord].self, from: data) else {
            history = []
            return
        }
        history = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    public func addHistory(_ record: HistoryRecord) {
        history.insert(record, at: 0)
        if history.count > 500 {
            history = Array(history.prefix(500))
        }
        saveHistory()
    }

    public func deleteHistory(id: UUID) {
        history.removeAll { $0.id == id }
        saveHistory()
    }

    public func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    private func saveHistory() {
        ensureDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(history) {
            try? data.write(to: historyFileURL, options: .atomic)
        }
    }

    // MARK: - Personal Dictionary Management

    public func loadDictionary() {
        if FileManager.default.fileExists(atPath: dictionaryFileURL.path),
           let data = try? Data(contentsOf: dictionaryFileURL),
           let decoded = try? JSONDecoder().decode([DictionaryEntry].self, from: data) {
            dictionary = decoded
            return
        }

        // Seed helpful initial technical terms if no file exists yet
        dictionary = [
            DictionaryEntry(term: "TypelessLite", aliases: ["type less lite", "typeless light"], note: "本项目名称"),
            DictionaryEntry(term: "GitHub", aliases: ["git hub", "get hub"], note: "代码托管平台"),
            DictionaryEntry(term: "SwiftUI", aliases: ["swift ui", "swift you i"], note: "Apple UI 框架"),
            DictionaryEntry(term: "DeepSeek", aliases: ["deep seek"], note: "大模型名称"),
            DictionaryEntry(term: "macOS", aliases: ["mac os", "麦克奥斯"], note: "操作系统")
        ]
        saveDictionary()
    }

    public func addDictionaryEntry(term: String, aliases: [String], note: String = "", source: DictionaryEntry.EntrySource = .manual) {
        let cleanTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTerm.isEmpty else { return }

        let cleanAliases = aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let index = dictionary.firstIndex(where: { $0.term.caseInsensitiveCompare(cleanTerm) == .orderedSame }) {
            var existing = dictionary[index]
            let merged = Array(Set(existing.aliases + cleanAliases)).sorted()
            existing.aliases = merged
            if !note.isEmpty { existing.note = note }
            dictionary[index] = existing
        } else {
            dictionary.insert(DictionaryEntry(term: cleanTerm, aliases: cleanAliases, note: note, source: source), at: 0)
        }
        saveDictionary()
    }

    public func deleteDictionaryEntry(id: UUID) {
        dictionary.removeAll { $0.id == id }
        saveDictionary()
    }

    public func saveDictionary() {
        ensureDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(dictionary) {
            try? data.write(to: dictionaryFileURL, options: .atomic)
        }
    }

    // MARK: - Stats

    public var totalCharactersGenerated: Int {
        history.reduce(0) { $0 + $1.refinedText.count }
    }

    public var totalSpeakingSeconds: Double {
        history.reduce(0) { $0 + $1.durationSeconds }
    }

    /// Approximate minutes saved compared to manual typing (assuming 45 chars/min typing vs ~160 chars/min dictation)
    public var estimatedMinutesSaved: Int {
        let manualMinutes = Double(totalCharactersGenerated) / 45.0
        let spokenMinutes = totalSpeakingSeconds / 60.0
        return max(0, Int((manualMinutes - spokenMinutes).rounded()))
    }
}
