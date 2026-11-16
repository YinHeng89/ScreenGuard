import AppKit
import SwiftUI

@main
struct ScreenGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var detector = HandProximityDetector.shared
    @StateObject private var overlay = OverlayManager.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(detector)
                .environmentObject(overlay)
        } label: {
            Image(systemName: detector.isMonitoring ? "hand.raised" : "hand.raised.slash")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(detector.isClose ? Color.orange : Color.primary)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        super.init()
        UserDefaults.standard.register(defaults: [
            "monitoringEnabled": true,
            "sensitivity": 1,
            "soundEnabled": true,
            "cooldownSeconds": 5,
            "reminderCount": 0,
            "selectedCameraID": ""
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let detector = HandProximityDetector.shared
        detector.onTrigger = { span in
            OverlayManager.shared.present(intensity: span)
            let count = UserDefaults.standard.integer(forKey: "reminderCount") + 1
            UserDefaults.standard.set(count, forKey: "reminderCount")
        }
        detector.onClear = {
            OverlayManager.shared.dismiss()
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.screenguard.preview"),
            object: nil,
            queue: .main
        ) { _ in
            OverlayManager.shared.present(intensity: 0.8)
        }

        // 诊断：命令行触发手动快照（临时功能，后期可删）
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.screenguard.snapshot"),
            object: nil,
            queue: .main
        ) { _ in
            detector.captureManualSnapshot()
        }

        if UserDefaults.standard.bool(forKey: "monitoringEnabled") {
            detector.start(deviceID: UserDefaults.standard.string(forKey: "selectedCameraID") ?? "")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HandProximityDetector.shared.stop()
    }
}

// MARK: - 菜单栏面板背景修复
//
// MenuBarExtra(.window) 面板默认是半透明的：背后的窗口内容会透出来。
// 面板是点击菜单栏图标时才创建的，启动时遍历窗口抓不到，
// 因此用一个零尺寸 NSView 桥接，随面板内容加入窗口时（viewDidMoveToWindow）就地处理。
//
// 诊断确认：面板里并没有 NSVisualEffectView，半透明来自几个覆盖整个面板的
// SwiftUI 内部绘制层（alpha 0.48 / 0.05）。所以只把这些「全尺寸背景层」
// 改成不透明，不碰进度条、文字、开关等小尺寸元素。
struct MenuPanelBackgroundFixer: NSViewRepresentable {
    func makeNSView(context: Context) -> FixerView { FixerView() }
    func updateNSView(_ nsView: FixerView, context: Context) {}

    final class FixerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window = window else { return }
            // 延后一拍，等系统把内容层装配好再铺背景
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === window else { return }
                Self.harden(window)
            }
        }

        private static func harden(_ window: NSWindow) {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.alphaValue = 1

            guard let content = window.contentView else { return }
            func walk(_ view: NSView) {
                // 面板尺寸约 320×581；只处理覆盖整个面板的背景层，
                // 避免误伤进度条(190×4)、图标、开关等正常半透明元素。
                if view.frame.width >= 300 && view.frame.height >= 500 {
                    view.alphaValue = 1
                    view.wantsLayer = true
                    view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                    view.layer?.isOpaque = true
                }
                for sub in view.subviews { walk(sub) }
            }
            walk(content)
            window.display()
        }
    }
}
