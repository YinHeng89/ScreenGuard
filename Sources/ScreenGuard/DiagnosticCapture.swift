import AppKit
import CoreGraphics
import Foundation

/// 诊断快照模块：把报警瞬间的摄像头画面与全部检测数据落盘，供事后分析误报 / 漏报。
///
/// 设计目标：**完全独立、可随时删除**。
/// 删除时只需移除本文件，以及 HandProximityDetector / MenuContent 中零星几处调用；
/// 不启用时（开关关闭）不产生任何磁盘写入。
final class DiagnosticCapture: @unchecked Sendable {
    static let shared = DiagnosticCapture()

    private let queue = DispatchQueue(label: "com.screenguard.diagnostic", qos: .utility)
    private let fileManager = FileManager.default
    private(set) var rootURL: URL?

    /// 最多保留的快照组数，超出后自动清理最旧的（每组 = 同名 PNG + JSON）
    private let maxSnapshots = 10

    /// 诊断捕获开关，默认开启。存 UserDefaults，菜单栏可切换。
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "diagnosticCaptureEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "diagnosticCaptureEnabled") }
    }

    private init() {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let dir = support?.appendingPathComponent("ScreenGuard/Diagnostics", isDirectory: true)
        self.rootURL = dir
        if let dir { try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    // MARK: - 图像转换

    /// 把摄像头帧转成 PNG。必须在 pixelBuffer 有效的线程（analysisQueue）调用。
    static func pngData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - 落盘

    /// 保存一次快照。图像与 JSON 使用同一时间戳前缀，便于配对查看。
    /// - Parameters:
    ///   - png: 摄像头帧 PNG 数据（可为 nil，仅存数据）
    ///   - reason: "auto-alert"（自动报警）/ "manual"（手动记录）
    ///   - metadata: 检测数据字典
    func save(png: Data?, reason: String, metadata: [String: Any]) {
        guard isEnabled, let root = rootURL else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss.SSS"
        let stamp = formatter.string(from: Date())
        let base = "\(stamp)_\(reason)"

        queue.async {
            if let png {
                try? png.write(to: root.appendingPathComponent("\(base).png"))
            }
            var payload = metadata
            payload["capturedAt"] = ISO8601DateFormatter().string(from: Date())
            payload["reason"] = reason
            if let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            ) {
                try? data.write(to: root.appendingPathComponent("\(base).json"))
            }

            // 滚动清理：时间戳前缀即字典序，保留最新 maxSnapshots 组，删除更旧的
            self.pruneOldSnapshots(in: root)
        }
    }

    /// 保留最新的 N 组快照，删除其余的 PNG 与 JSON。
    /// 文件名以 "yyyy-MM-dd_HH-mm-ss.SSS_reason" 开头，字典序等于时间序。
    private func pruneOldSnapshots(in root: URL) {
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        // 以去掉扩展名后的 base 为一组（PNG 与 JSON 同名）
        var bases = Set<String>()
        for name in names where name.hasSuffix(".png") || name.hasSuffix(".json") {
            bases.insert((name as NSString).deletingPathExtension)
        }
        let sorted = bases.sorted()   // 旧 → 新
        guard sorted.count > maxSnapshots else { return }
        for base in sorted.prefix(sorted.count - maxSnapshots) {
            try? fileManager.removeItem(at: root.appendingPathComponent(base + ".png"))
            try? fileManager.removeItem(at: root.appendingPathComponent(base + ".json"))
        }
    }

    // MARK: - 管理

    /// 在 Finder 中打开诊断文件夹
    func reveal() {
        guard let root = rootURL else { return }
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    /// 已保存的快照数量（按 PNG 计）
    var count: Int {
        guard let root = rootURL else { return 0 }
        return (try? fileManager.contentsOfDirectory(atPath: root.path))?
            .filter { $0.hasSuffix(".png") }.count ?? 0
    }

    /// 清空全部诊断文件
    func clearAll() {
        guard let root = rootURL else { return }
        queue.async {
            for name in (try? self.fileManager.contentsOfDirectory(atPath: root.path)) ?? [] {
                try? self.fileManager.removeItem(at: root.appendingPathComponent(name))
            }
        }
    }
}
