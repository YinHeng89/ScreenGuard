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
