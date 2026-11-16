import AVFoundation
import AppKit
import SwiftUI

struct MenuContent: View {
    @EnvironmentObject private var detector: HandProximityDetector
    @EnvironmentObject private var overlay: OverlayManager

    @AppStorage("monitoringEnabled") private var monitoringEnabled = true
    @AppStorage("sensitivity") private var sensitivity = 1
    @AppStorage("soundEnabled") private var soundEnabled = true
    @AppStorage("cooldownSeconds") private var cooldownSeconds = 5
    @AppStorage("selectedCameraID") private var selectedCameraID = ""
    @AppStorage("reminderCount") private var reminderCount = 0
    // 诊断快照开关（临时功能，后期可整体删除）
    @AppStorage("diagnosticCaptureEnabled") private var diagnosticEnabled = true

    @State private var cameras: [AVCaptureDevice] = []
    @State private var snapshotCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header

            HStack(spacing: 8) {
                Text("检测强度")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: detector.detectionStrength > 0.85 ? [.orange, .pink] : [.purple, .cyan],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * detector.detectionStrength)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 4)

                Text("\(Int(detector.detectionStrength * 100))%")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }

            HStack(spacing: 5) {
                signalTag("食指伸出", active: detector.indexExtended, color: .purple)
                signalTag("正在靠近", active: detector.approaching, color: .orange)
                signalTag("接近区", active: detector.detectionStrength > 0.6, color: .pink)
            }

            Divider()

            Toggle(isOn: $monitoringEnabled) {
                Label("开启手势监测", systemImage: "waveform.path.ecg")
            }
            .onChange(of: monitoringEnabled) { _, enabled in
                if enabled {
                    detector.start(deviceID: selectedCameraID)
                } else {
                    detector.stop()
                }
            }

            Picker("灵敏度", selection: $sensitivity) {
                Text("保守").tag(0)
                Text("标准").tag(1)
                Text("灵敏").tag(2)
            }
            .pickerStyle(.menu)

            Picker("提醒间隔", selection: $cooldownSeconds) {
                Text("3 秒").tag(3)
                Text("5 秒").tag(5)
                Text("8 秒").tag(8)
                Text("12 秒").tag(12)
            }
            .pickerStyle(.menu)

            Toggle(isOn: $soundEnabled) {
                Label("提示音", systemImage: "speaker.wave.2")
            }

            Picker("摄像头", selection: $selectedCameraID) {
                Text("自动选择").tag("")
                ForEach(cameras, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device.uniqueID)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: selectedCameraID) { _, newID in
                guard monitoringEnabled else { return }
                detector.stop()
                detector.start(deviceID: newID)
            }

            Divider()

            HStack {
                Button {
                    overlay.present(intensity: 0.8)
                } label: {
                    Label("预览提醒", systemImage: "eye")
                }
                .buttonStyle(.borderless)

                Spacer()

                Text("已提醒 \(reminderCount) 次")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // MARK: 诊断快照（临时功能，后期可删除整个分区）
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("诊断快照", systemImage: "doc.camera")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("", isOn: $diagnosticEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }

                Text("报警时自动保存画面与数据，供分析误报；漏报可用下方按钮手动记录。仅保留最近 10 条。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Button {
                        detector.captureManualSnapshot()
                        snapshotCount = DiagnosticCapture.shared.count
                    } label: {
                        Label("记录当前", systemImage: "camera")
                    }
                    .buttonStyle(.borderless)

                    Button {
                        DiagnosticCapture.shared.reveal()
                    } label: {
                        Label("打开文件夹", systemImage: "folder")
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Text("\(snapshotCount) 张")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }

            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Label("退出 ScreenGuard", systemImage: "power")
            }
            .buttonStyle(.borderless)

            Text("画面仅在本机分析 · 存储于本机 · 不上传")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 1)
        }
        .padding(14)
        .frame(width: 288)
        .onAppear {
            cameras = discoverCameras()
            snapshotCount = DiagnosticCapture.shared.count
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 34, height: 34)
                Image(systemName: "hand.raised")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("屏幕守卫")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(detector.statusText) · \(detector.stateText)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Circle()
                .fill(detector.isClose ? Color.orange : (detector.isMonitoring ? Color.mint : Color.secondary))
                .frame(width: 8, height: 8)
                .shadow(color: detector.isClose ? .orange.opacity(0.7) : .clear, radius: 5)
        }
    }

    private func signalTag(_ title: String, active: Bool, color: Color) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(active ? color.opacity(0.22) : Color.secondary.opacity(0.10))
            )
            .foregroundStyle(active ? color : .secondary)
    }

    private func discoverCameras() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices
    }
}
