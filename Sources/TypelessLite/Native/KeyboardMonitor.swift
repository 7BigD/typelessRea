import Foundation
import AppKit
import CoreGraphics

/// Reverse-engineered replica of Typeless's libKeyboardHelper.dylib.
/// Supports Fn/Globe, Right Option, Right Command, Option+Space, F5, Hold-to-Talk, Tap/Hands-Free, and Esc cancel.
@MainActor
public final class KeyboardMonitor: ObservableObject {
    public enum Action {
        case startRecording(mode: WorkMode, isHandsFree: Bool)
        case upgradeToHandsFree(mode: WorkMode)
        case finishRecording
        case cancelRecording
    }

    public static let shared = KeyboardMonitor()

    @Published public private(set) var isEventTapActive: Bool = false
    @Published public private(set) var activeMode: WorkMode? = nil
    @Published public private(set) var isHandsFree: Bool = false

    public var onAction: ((Action) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var upgradeCheckTimer: Timer?

    private var currentTriggerKey: TriggerKey? = nil
    private var triggerPressTime: Date? = nil
    private var otherKeyPressedDuringModifierHold: Bool = false
    private var isProcessingActive: Bool = false

    private var settingsProvider: () -> AppSettings = { LocalStore.shared.settings }
    private var isSessionBusyProvider: () -> Bool = { false }

    private let holdThresholdSeconds: TimeInterval = 0.35

    private init() {}

    public func configure(
        settingsProvider: @escaping () -> AppSettings,
        isSessionBusyProvider: @escaping () -> Bool,
        onAction: @escaping (Action) -> Void
    ) {
        self.settingsProvider = settingsProvider
        self.isSessionBusyProvider = isSessionBusyProvider
        self.onAction = onAction
    }

    public func start() {
        stop()

        if startCGEventTap() {
            isEventTapActive = true
            return
        }

        // Fallback to NSEvent monitors when Accessibility permission is not yet granted
        isEventTapActive = false
        startNSEventFallback()

        upgradeCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if AXIsProcessTrusted(), !self.isEventTapActive {
                    if self.startCGEventTap() {
                        self.removeNSEventFallback()
                        self.upgradeCheckTimer?.invalidate()
                        self.upgradeCheckTimer = nil
                        self.isEventTapActive = true
                    }
                }
            }
        }
    }

    public func stop() {
        upgradeCheckTimer?.invalidate()
        upgradeCheckTimer = nil

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        isEventTapActive = false
        removeNSEventFallback()
    }

    public func resetState() {
        activeMode = nil
        isHandsFree = false
        currentTriggerKey = nil
        triggerPressTime = nil
        otherKeyPressedDuringModifierHold = false
    }

    // MARK: - CGEventTap Setup

    private func startCGEventTap() -> Bool {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let activeTap = monitor.eventTap {
                        CGEvent.tapEnable(tap: activeTap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                let shouldConsume = MainActor.assumeIsolated {
                    monitor.handleCGEvent(type: type, event: event)
                }
                return shouldConsume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTap = tap
        self.runLoopSource = source
        return true
    }

    private func startNSEventFallback() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let type = event.type
            let keyCode = Int(event.keyCode)
            let isRepeat = (type == .keyDown || type == .keyUp) ? event.isARepeat : false
            let flags = event.modifierFlags
            Task { @MainActor in
                self?.handleRawEvent(
                    type: type,
                    keyCode: keyCode,
                    isARepeat: isRepeat,
                    hasFn: flags.contains(.function),
                    hasOption: flags.contains(.option),
                    hasCommand: flags.contains(.command)
                )
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let type = event.type
            let keyCode = Int(event.keyCode)
            let isRepeat = (type == .keyDown || type == .keyUp) ? event.isARepeat : false
            let flags = event.modifierFlags
            let consume = MainActor.assumeIsolated {
                self?.handleRawEvent(
                    type: type,
                    keyCode: keyCode,
                    isARepeat: isRepeat,
                    hasFn: flags.contains(.function),
                    hasOption: flags.contains(.option),
                    hasCommand: flags.contains(.command)
                ) ?? false
            }
            return consume ? nil : event
        }
    }

    private func removeNSEventFallback() {
        if let g = globalMonitor {
            NSEvent.removeMonitor(g)
            globalMonitor = nil
        }
        if let l = localMonitor {
            NSEvent.removeMonitor(l)
            localMonitor = nil
        }
    }

    // MARK: - Event Handling

    @discardableResult
    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Bool {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        switch type {
        case .keyDown:
            if isAutoRepeat { return isRegisteredComboKey(keyCode: keyCode, flags: flags) }
            return processKeyDown(keyCode: keyCode, hasOption: flags.contains(.maskAlternate), hasCommand: flags.contains(.maskCommand))
        case .keyUp:
            return processKeyUp(keyCode: keyCode)
        case .flagsChanged:
            return processFlagsChanged(
                keyCode: keyCode,
                hasFn: flags.contains(.maskSecondaryFn),
                hasOption: flags.contains(.maskAlternate),
                hasCommand: flags.contains(.maskCommand)
            )
        default:
            return false
        }
    }

    @discardableResult
    private func handleRawEvent(
        type: NSEvent.EventType,
        keyCode: Int,
        isARepeat: Bool,
        hasFn: Bool,
        hasOption: Bool,
        hasCommand: Bool
    ) -> Bool {
        switch type {
        case .keyDown:
            if isARepeat { return false }
            return processKeyDown(keyCode: keyCode, hasOption: hasOption, hasCommand: hasCommand)
        case .keyUp:
            return processKeyUp(keyCode: keyCode)
        case .flagsChanged:
            return processFlagsChanged(
                keyCode: keyCode,
                hasFn: hasFn,
                hasOption: hasOption,
                hasCommand: hasCommand
            )
        default:
            return false
        }
    }

    private func isRegisteredComboKey(keyCode: Int, flags: CGEventFlags) -> Bool {
        let settings = settingsProvider()
        let configured = [settings.dictationHotkey, settings.askAnythingHotkey, settings.translationHotkey]
        if keyCode == 49 && flags.contains(.maskAlternate) && configured.contains(.optionSpace) {
            return true
        }
        if keyCode == 96 && configured.contains(.f5) {
            return true
        }
        return false
    }

    private func modeForTriggerKey(_ key: TriggerKey) -> WorkMode? {
        let settings = settingsProvider()
        if settings.dictationHotkey == key { return .dictation }
        if settings.askAnythingHotkey == key { return .askAnything }
        if settings.translationHotkey == key { return .translation }
        return nil
    }

    // MARK: - Key State Machine

    private func processKeyDown(keyCode: Int, hasOption: Bool, hasCommand: Bool) -> Bool {
        // Esc (53) cancels active recording or in-flight processing
        if keyCode == 53, (activeMode != nil || isSessionBusyProvider()) {
            resetState()
            onAction?(.cancelRecording)
            return true
        }

        if currentTriggerKey?.isModifierOnly == true {
            otherKeyPressedDuringModifierHold = true
        }

        if keyCode == 49 && hasOption && !hasCommand {
            if let mode = modeForTriggerKey(.optionSpace) {
                triggerPressed(key: .optionSpace, mode: mode)
                return true
            }
        }

        if keyCode == 96 {
            if let mode = modeForTriggerKey(.f5) {
                triggerPressed(key: .f5, mode: mode)
                return true
            }
        }

        return false
    }

    private func processKeyUp(keyCode: Int) -> Bool {
        guard let activeTrigger = currentTriggerKey else { return false }
        if activeTrigger == .optionSpace && keyCode == 49 {
            triggerReleased(key: .optionSpace)
            return true
        }
        if activeTrigger == .f5 && keyCode == 96 {
            triggerReleased(key: .f5)
            return true
        }
        return false
    }

    private func processFlagsChanged(keyCode: Int, hasFn: Bool, hasOption: Bool, hasCommand: Bool) -> Bool {
        // Fn / Globe key: hardware keyCode 63 (built-in) or 179 (Apple external)
        if keyCode == 63 || keyCode == 179 {
            if let mode = modeForTriggerKey(.fnKey) {
                if hasFn {
                    if currentTriggerKey == nil {
                        triggerPressed(key: .fnKey, mode: mode)
                    }
                } else if currentTriggerKey == .fnKey {
                    triggerReleased(key: .fnKey)
                }
            }
            return false
        }

        // Right Option keyCode == 61
        if keyCode == 61 {
            if let mode = modeForTriggerKey(.rightOption) {
                if hasOption {
                    if currentTriggerKey == nil {
                        triggerPressed(key: .rightOption, mode: mode)
                    }
                } else if currentTriggerKey == .rightOption {
                    triggerReleased(key: .rightOption)
                }
            }
            return false
        }

        // Right Command keyCode == 54
        if keyCode == 54 {
            if let mode = modeForTriggerKey(.rightCommand) {
                if hasCommand {
                    if currentTriggerKey == nil {
                        triggerPressed(key: .rightCommand, mode: mode)
                    }
                } else if currentTriggerKey == .rightCommand {
                    triggerReleased(key: .rightCommand)
                }
            }
            return false
        }

        return false
    }

    private func triggerPressed(key: TriggerKey, mode: WorkMode) {
        if isSessionBusyProvider() && activeMode == nil {
            return
        }

        // If already recording in hands-free mode, second press finishes recording
        if let current = activeMode, isHandsFree {
            if current == mode {
                currentTriggerKey = key
                triggerPressTime = Date()
                // Wait for release or finish immediately on press
                resetState()
                onAction?(.finishRecording)
            }
            return
        }

        currentTriggerKey = key
        triggerPressTime = Date()
        otherKeyPressedDuringModifierHold = false
        activeMode = mode
        isHandsFree = false
        onAction?(.startRecording(mode: mode, isHandsFree: false))
    }

    private func triggerReleased(key: TriggerKey) {
        guard currentTriggerKey == key else { return }

        // If another key was pressed during a modifier-only hold (e.g. Fn+F11), cancel silently
        if key.isModifierOnly && otherKeyPressedDuringModifierHold {
            resetState()
            onAction?(.cancelRecording)
            return
        }

        guard let started = triggerPressTime, let mode = activeMode else {
            currentTriggerKey = nil
            return
        }

        let elapsed = Date().timeIntervalSince(started)
        currentTriggerKey = nil
        triggerPressTime = nil

        if elapsed >= holdThresholdSeconds {
            // Hold-to-talk finished
            resetState()
            onAction?(.finishRecording)
        } else {
            // Quick tap -> enter hands-free continuous recording until next press or Esc
            isHandsFree = true
            onAction?(.upgradeToHandsFree(mode: mode))
        }
    }
}
