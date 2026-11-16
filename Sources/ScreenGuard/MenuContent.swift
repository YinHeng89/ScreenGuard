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
    // 三路信号开关：关掉的通道不计分，权重按比例分给其余开启项
    @AppStorage("signalGrowthEnabled") private var growthEnabled = true
    @AppStorage("signalGestureEnabled") private var gestureEnabled = true
    @AppStorage("signalZoneEnabled") private var zoneEnabled = true
    // 诊断快照开关（临时功能，后期可整体删除）
    @AppStorage("diagnosticCaptureEnabled") private var diagnosticEnabled = true

    @State private var cameras: [AVCaptureDevice] = []
    @State private var snapshotCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header

            HStack(spacing: 8) {
                Text("检测强度")
                    .font(.system(size: 11))
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
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("参与评分的信号")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)

                VStack(spacing: 7) {
                    signalRow("食指伸出", isOn: $gestureEnabled)
                        .onChange(of: gestureEnabled) { _, _ in
                            if !growthEnabled && !gestureEnabled && !zoneEnabled { gestureEnabled = true }
                        }
                    signalRow("正在靠近", isOn: $growthEnabled)
                        .onChange(of: growthEnabled) { _, _ in
                            if !growthEnabled && !gestureEnabled && !zoneEnabled { growthEnabled = true }
                        }
                    signalRow("接近区", isOn: $zoneEnabled)
                        .onChange(of: zoneEnabled) { _, _ in
                            if !growthEnabled && !gestureEnabled && !zoneEnabled { zoneEnabled = true }
                        }
                }

                Text("关闭某路信号后，其权重分给其余项；关掉「正在靠近」将不再要求手持续变大。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            settingToggle("开启手势监测", icon: "waveform.path.ecg", isOn: $monitoringEnabled)
                .onChange(of: monitoringEnabled) { _, enabled in
                    if enabled {
                        detector.start(deviceID: selectedCameraID)
                    } else {
                        detector.stop()
                    }
                }

            settingPicker("灵敏度", selection: $sensitivity) {
                Text("保守").tag(0)
                Text("标准").tag(1)
                Text("灵敏").tag(2)
            }

            settingPicker("提醒间隔", selection: $cooldownSeconds) {
                Text("3 秒").tag(3)
                Text("5 秒").tag(5)
                Text("8 秒").tag(8)
                Text("12 秒").tag(12)
            }

            settingToggle("提示音", icon: "speaker.wave.2", isOn: $soundEnabled)

            settingPicker("摄像头", selection: $selectedCameraID) {
                Text("自动选择").tag("")
                ForEach(cameras, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device.uniqueID)
                }
            }
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
                .buttonStyle(.plain)

                Spacer()

                Text("已提醒 \(reminderCount) 次")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            // MARK: 诊断快照（临时功能，后期可删除整个分区）
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                settingToggle("诊断快照", icon: "doc.camera", isOn: $diagnosticEnabled)

                Text("报警时自动保存画面与数据，供分析误报；漏报可用下方按钮手动记录。仅保留最近 10 条。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Button {
                        detector.captureManualSnapshot()
                        snapshotCount = DiagnosticCapture.shared.count
                    } label: {
                        Label("记录当前", systemImage: "camera")
                    }
                    .buttonStyle(.plain)

                    Button {
                        DiagnosticCapture.shared.reveal()
                    } label: {
                        Label("打开文件夹", systemImage: "folder")
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text("\(snapshotCount) 张")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }

            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Label("退出 ScreenGuard", systemImage: "power")
            }
            .buttonStyle(.plain)

            Text("画面仅在本机分析 · 存储于本机 · 不上传")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 1)
        }
        .font(.system(size: 11))
        .tint(.accentColor)
        // 留白加大，整体更舒展
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(width: 320)
        // 内容层实色背景 + 桥接视图：后者随面板加入窗口时，把系统半透明材质改为不透明
        .background(Color(nsColor: .windowBackgroundColor))
        .background(MenuPanelBackgroundFixer())
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
                    .font(.system(size: 13, weight: .semibold))
                Text("\(detector.statusText) · \(detector.stateText)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Circle()
                .fill(detector.isClose ? Color.orange : (detector.isMonitoring ? Color.mint : Color.secondary))
                .frame(width: 8, height: 8)
                .shadow(color: detector.isClose ? .orange.opacity(0.7) : .clear, radius: 5)
        }
    }

    /// 统一的行内开关：左侧图标+文字，右侧迷你 switch 右对齐。
    private func settingToggle(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5))
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }

    /// 统一的下拉项：左侧标签，右侧菜单式选择器，选中值右对齐并弱化。
    private func settingPicker<Content: View, Selection: Hashable>(
        _ title: String,
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11.5))
            Spacer(minLength: 8)
            Picker("", selection: selection) { content() }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(height: 18)
    }

    /// 单个信号：左右结构，文字在前、迷你 switch 在后，右对齐。
    private func signalRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(isOn.wrappedValue ? .primary : .tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
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
