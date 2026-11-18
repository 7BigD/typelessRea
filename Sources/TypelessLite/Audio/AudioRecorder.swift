import Foundation
import AVFoundation
@preconcurrency import Speech
import Combine

/// Captures 16kHz Mono PCM WAV audio, streams real-time RMS audio levels for FloatingBar,
/// and provides offline/local fallback transcription via Apple's SFSpeechRecognizer.
@MainActor
public final class AudioRecorder: NSObject, ObservableObject {
    public static let shared = AudioRecorder()

    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var audioLevels: [CGFloat] = Array(repeating: 0.12, count: 14)
    @Published public private(set) var elapsedSeconds: TimeInterval = 0
    @Published public private(set) var microphoneAuthorized: Bool = false
    @Published public private(set) var speechRecognitionAuthorized: Bool = false

    private var recorder: AVAudioRecorder?
    private var currentFileURL: URL?
    private var startTime: Date?
    private var meterTimer: Timer?

    private override init() {
        super.init()
        refreshPermissionStates()
    }

    public func refreshPermissionStates() {
        microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechRecognitionAuthorized = SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    public func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            microphoneAuthorized = true
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneAuthorized = granted
            return granted
        default:
            microphoneAuthorized = false
            return false
        }
    }

    public func requestSpeechRecognitionPermission() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            speechRecognitionAuthorized = true
            return true
        case .notDetermined:
            let result: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { newStatus in
                    continuation.resume(returning: newStatus)
                }
            }
            let ok = (result == .authorized)
            speechRecognitionAuthorized = ok
            return ok
        default:
            speechRecognitionAuthorized = false
            return false
        }
    }

    // MARK: - Recording Lifecycle

    public func startRecording() throws -> URL {
        if isRecording {
            cancelRecording()
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typelesslite-\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let newRecorder = try AVAudioRecorder(url: tempURL, settings: settings)
        newRecorder.isMeteringEnabled = true
        guard newRecorder.prepareToRecord(), newRecorder.record() else {
            throw NSError(
                domain: "TypelessLite.Audio",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无法启动麦克风录音，请检查麦克风权限或输入设备"]
            )
        }

        self.recorder = newRecorder
        self.currentFileURL = tempURL
        self.startTime = Date()
        self.elapsedSeconds = 0
        self.audioLevels = Array(repeating: 0.14, count: 14)
        self.isRecording = true

        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleMeters()
            }
        }

        return tempURL
    }

    public func stopRecording() -> (url: URL, duration: Double)? {
        meterTimer?.invalidate()
        meterTimer = nil

        guard let rec = recorder, let url = currentFileURL else {
            isRecording = false
            return nil
        }

        rec.stop()
        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        self.recorder = nil
        self.currentFileURL = nil
        self.startTime = nil
        self.isRecording = false
        self.audioLevels = Array(repeating: 0.12, count: 14)
        return (url, duration)
    }

    public func cancelRecording() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        if let url = currentFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        currentFileURL = nil
        startTime = nil
        isRecording = false
        elapsedSeconds = 0
        audioLevels = Array(repeating: 0.12, count: 14)
    }

    private func sampleMeters() {
        guard let rec = recorder, rec.isRecording else { return }
        rec.updateMeters()
        let db = rec.averagePower(forChannel: 0) // typically -60...0 dB
        let clamped = max(-55.0, min(0.0, Double(db)))
        let normalized = CGFloat((clamped + 55.0) / 55.0)
        // Curve slightly for smoother visual responsiveness
        let shaped = max(0.10, min(1.0, pow(normalized, 1.35)))

        var next = audioLevels
        if !next.isEmpty {
            next.removeFirst()
            next.append(shaped)
        }
        audioLevels = next

        if let start = startTime {
            elapsedSeconds = Date().timeIntervalSince(start)
        }
    }

    // MARK: - Apple Native Speech Recognition Fallback

    public func transcribeWithAppleSpeech(
        fileURL: URL,
        localeIdentifier: String,
        contextualStrings: [String]
    ) async throws -> String {
        let granted = await requestSpeechRecognitionPermission()
        guard granted else {
            throw NSError(
                domain: "TypelessLite.Speech",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "未授予系统「语音识别」权限，请在系统设置 -> 隐私与安全性中开启，或在设置中填写 Groq/OpenAI Whisper API Key。"]
            )
        }

        let locale: Locale = (localeIdentifier == "auto" || localeIdentifier.isEmpty)
            ? Locale.current
            : Locale(identifier: localeIdentifier)

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw NSError(
                domain: "TypelessLite.Speech",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "当前语言的 Apple 语音识别器不可用，请检查系统听写设置或切换为 Whisper API。"]
            )
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if !contextualStrings.isEmpty {
            request.contextualStrings = Array(contextualStrings.prefix(100))
        }

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            let lock = NSLock()
            var task: SFSpeechRecognitionTask?

            let finishOnce: (Result<String, Error>) -> Void = { result in
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                switch result {
                case .success(let text):
                    continuation.resume(returning: text)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    finishOnce(.failure(error))
                    return
                }
                if let result, result.isFinal {
                    finishOnce(.success(result.bestTranscription.formattedString))
                }
            }

            // Safety timeout after 20 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 20.0) {
                lock.lock()
                let alreadyDone = didResume
                lock.unlock()
                if !alreadyDone {
                    task?.cancel()
                    finishOnce(.failure(NSError(
                        domain: "TypelessLite.Speech",
                        code: 408,
                        userInfo: [NSLocalizedDescriptionKey: "本地语音识别超时，请重试或使用更短的录音。"]
                    )))
                }
            }
        }
    }
}
