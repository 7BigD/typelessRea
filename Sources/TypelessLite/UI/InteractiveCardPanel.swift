import SwiftUI
import AppKit

/// Floating Ask Anything answer card displayed above FloatingBar (replaces Typeless interactive-card.html).
@MainActor
public final class InteractiveCardPanelController {
    private var panel: InteractiveCardNSPanel?
    private let hostingView: NSHostingView<AnyView>

    public init<Content: View>(rootView: Content) {
        self.hostingView = NSHostingView(rootView: AnyView(rootView))
        setupPanel()
    }

    private func setupPanel() {
        let rect = NSRect(x: 0, y: 0, width: 460, height: 300)
        let panel = InteractiveCardNSPanel(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentView = hostingView
        self.panel = panel
    }

    public func show(above barFrame: NSRect) {
        guard let panel else { return }
        let width: CGFloat = 460
        let height: CGFloat = 300
        let screen = NSScreen.screens.first(where: { $0.frame.contains(barFrame.origin) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        let x = visible.midX - width / 2.0
        let y = max(visible.minY + 96.0, barFrame.maxY + 14.0)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel?.orderOut(nil)
    }
}

private final class InteractiveCardNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

public struct InteractiveCardView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var copiedFeedback = false

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        if let payload = coordinator.cardPayload {
            VStack(alignment: .leading, spacing: 10) {
                // Header
                HStack {
                    Label("Ask Anything", systemImage: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.purple)

                    if !payload.appName.isEmpty {
                        Text(payload.appName)
                            .font(.system(size: 11))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        coordinator.dismissCard()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                // Voice command prompt summary
                VStack(alignment: .leading, spacing: 4) {
                    Text("指令：\(payload.voicePrompt)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if !payload.selectedText.isEmpty {
                        Text("选中：\(payload.selectedText)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Divider()

                // Answer body
                ScrollView {
                    Text(payload.answer)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                }

                // Actions
                HStack(spacing: 10) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(payload.answer, forType: .string)
                        copiedFeedback = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copiedFeedback = false
                        }
                    } label: {
                        Label(copiedFeedback ? "已复制" : "复制回答", systemImage: copiedFeedback ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button {
                        coordinator.insertCardAnswerToTargetApp()
                    } label: {
                        Label("插入 / 替换到原光标处", systemImage: "arrow.down.doc")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
            }
            .padding(14)
            .frame(width: 460, height: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.purple.opacity(0.32), lineWidth: 1)
            )
        } else {
            EmptyView()
        }
    }
}
