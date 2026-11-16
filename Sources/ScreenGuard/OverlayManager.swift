import AppKit
import Combine
import SwiftUI

/// 管理置顶、不抢焦点的悬浮提醒窗口。
final class OverlayManager: ObservableObject {
    static let shared = OverlayManager()

    @Published private(set) var isVisible = false
    @Published private(set) var intensity: CGFloat = 1
    /// 每次触发递增，强制 SwiftUI 重建卡片以重置进度条动画
    @Published private(set) var triggerID = UUID()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    // MARK: - 对外接口

    func present(intensity: CGFloat = 1) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.intensity = min(max(intensity, 0), 1)
            self.triggerID = UUID()
            self.hideWork?.cancel()
            self.ensurePanel()
            self.place(self.panel!, size: NSSize(width: 430, height: 152))
            self.panel?.orderFrontRegardless()

            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                self.isVisible = true
            }

            if UserDefaults.standard.bool(forKey: "soundEnabled") {
                NSSound(named: "Tink")?.play()
            }

            let work = DispatchWorkItem { [weak self] in self?.dismiss() }
            self.hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
        }
    }

    func dismiss() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hideWork?.cancel()
            withAnimation(.easeInOut(duration: 0.28)) {
                self.isVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in
                guard let self, !self.isVisible else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    // MARK: - 窗口

    private func ensurePanel() {
        guard panel == nil else { return }

        // 窗口精确贴合卡片，无任何多余区域；不使用阴影，避免灰色残影
        let size = NSSize(width: 430, height: 152)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none

        let hosting = NSHostingView(rootView: AlertCardView().environmentObject(self))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.masksToBounds = false

        panel.contentView = hosting

        place(panel, size: size)
        self.panel = panel
    }

    private func place(_ panel: NSPanel, size: NSSize) {
        // 定位到鼠标所在的当前工作屏幕，多显示器下更贴合用户视线
        let mouse = NSEvent.mouseLocation
        let active = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let frame = active?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 30
        )
        panel.setFrame(
            NSRect(origin: origin, size: size),
            display: true
        )
    }
}

// MARK: - 弹窗视觉

struct AlertCardView: View {
    @EnvironmentObject private var overlay: OverlayManager
    @State private var pulse = false
    @State private var progress: CGFloat = 1

    var body: some View {
        ZStack {
            if overlay.isVisible {
                card
                    .id(overlay.triggerID)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.9).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
                    .onAppear {
                        progress = 1
                        pulse = false
                        withAnimation(.linear(duration: 4.5)) { progress = 0 }
                        withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                            pulse = true
                        }
                    }
            }
        }
        .frame(width: 430, height: 152)
    }

    private var card: some View {
        HStack(spacing: 18) {
            icon

            VStack(alignment: .leading, spacing: 6) {
                Text("请不要用手指触摸屏幕")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                Text("给指尖留一点距离，让屏幕陪你更久")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.68))

                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.mint)
                        .frame(width: 5, height: 5)
                    Text("ScreenGuard 正在守护")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.32), .white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .overlay(alignment: .bottom) { progressBar }
    }

    private var cardBackground: some View {
        ZStack {
            // 纯色渐变，模拟玻璃质感；不使用 material，避免透明窗口上渲染成灰色方块
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.15, blue: 0.24, opacity: 0.96),
                    Color(red: 0.09, green: 0.09, blue: 0.14, opacity: 0.96)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                colors: [.purple.opacity(0.30), .indigo.opacity(0.08), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var icon: some View {
        ZStack {
            Circle()
                .stroke(Color.purple.opacity(0.6), lineWidth: 1.5)
                .scaleEffect(pulse ? 1.55 : 1)
                .opacity(pulse ? 0 : 0.75)

            Circle()
                .stroke(Color.cyan.opacity(0.4), lineWidth: 1)
                .scaleEffect(pulse ? 1.3 : 1)
                .opacity(pulse ? 0 : 0.55)

            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.purple, .indigo],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: "hand.raised.fingers.spread")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(.white)
                )
                .shadow(color: .purple.opacity(0.5), radius: 14, y: 5)
        }
        .frame(width: 76, height: 76)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Color.white.opacity(0.07)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.purple, .cyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * progress)
            }
            .clipShape(Capsule())
        }
        .frame(height: 2.5)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}
