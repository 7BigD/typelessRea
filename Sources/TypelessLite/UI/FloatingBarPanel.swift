import SwiftUI
import AppKit

/// Non-activating floating capsule panel at bottom-center of screen (replaces Typeless floating-bar.html).
@MainActor
public final class FloatingBarPanelController {
    private var panel: FloatingBarNSPanel?
    private let hostingView: NSHostingView<AnyView>

    public init<Content: View>(rootView: Content) {
        self.hostingView = NSHostingView(rootView: AnyView(rootView))
        setupPanel()
    }

    private func setupPanel() {
        let initialRect = NSRect(x: 0, y: 0, width: 380, height: 64)
        let panel = FloatingBarNSPanel(
            contentRect: initialRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.contentView = hostingView
        self.panel = panel
    }

    public func updateVisibility(visible: Bool, expanded: Bool) {
        guard let panel else { return }
        if !visible {
            panel.orderOut(nil)
            return
        }

        let targetSize = expanded ? NSSize(width: 400, height: 66) : NSSize(width: 210, height: 38)
        let screen = activeScreen()
        let frame = screen.visibleFrame
        let x = frame.midX - targetSize.width / 2.0
        let y = frame.minY + 26.0
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: targetSize), display: true, animate: false)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    public var currentFrame: NSRect {
        panel?.frame ?? .zero
    }

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

private final class FloatingBarNSPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// SwiftUI content rendered inside the floating capsule
public struct FloatingBarView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject var store: LocalStore

    public init(coordinator: AppCoordinator, recorder: AudioRecorder, store: LocalStore) {
        self.coordinator = coordinator
        self.recorder = recorder
        self.store = store
    }

    public var body: some View {
        Group {
            switch coordinator.sessionState {
            case .idle:
                if store.settings.showFloatingBarWhenIdle {
                    idlePill
                } else {
                    EmptyView()
                }
            case .recording(let mode, let isHandsFree, _):
                recordingPill(mode: mode, isHandsFree: isHandsFree)
            case .processing(let mode, let stage):
                processingPill(mode: mode, stage: stage)
            case .completedPreview(let text):
                completedPill(text: text)
            case .error(let message):
                errorPill(message: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var idlePill: some View {
        Button {
            coordinator.toggleManualDictation()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("按 \(store.settings.dictationHotkey.shortBadge) 说话")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }

    private func recordingPill(mode: WorkMode, isHandsFree: Bool) -> some View {
        HStack(spacing: 10) {
            // Mode pill
            HStack(spacing: 5) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 11.5, weight: .bold))
                Text(mode.shortLabel)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(modeColor(mode), in: Capsule())

            // App / Hands-free metadata + live waveform
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(coordinator.activeContext.appName.isEmpty ? "TypelessLite" : coordinator.activeContext.appName)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if isHandsFree {
                        Text("免提")
                            .font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }

                HStack(spacing: 2.5) {
                    ForEach(Array(recorder.audioLevels.enumerated()), id: \.offset) { _, level in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(modeColor(mode).gradient)
                            .frame(width: 3, height: max(4, level * 18))
                            .animation(.linear(duration: 0.06), value: level)
                    }
                }
                .frame(height: 18, alignment: .center)
            }

            Spacer(minLength: 4)

            // Cancel button
            Button {
                coordinator.cancelSession()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("取消 (Esc)")

            // Finish button
            Button {
                coordinator.finishSession()
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(modeColor(mode))
            }
            .buttonStyle(.plain)
            .help("完成并生成")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 356, height: 50)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(modeColor(mode).opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }

    private func processingPill(mode: WorkMode, stage: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("\(mode.shortLabel) · \(stage)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                coordinator.cancelSession()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 280, height: 42)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
    }

    private func completedPill(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 14))
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 340, minHeight: 38)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.green.opacity(0.35), lineWidth: 0.9)
        )
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }

    private func errorPill(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14))
            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: 360, minHeight: 40)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.45), lineWidth: 0.9)
        )
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
    }

    private func modeColor(_ mode: WorkMode) -> Color {
        switch mode {
        case .dictation: return .blue
        case .askAnything: return .purple
        case .translation: return .teal
        }
    }
}
