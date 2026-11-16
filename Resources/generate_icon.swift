import AppKit

// 生成 1024×1024 的 macOS 应用图标源图。
// 用法: swift Resources/generate_icon.swift <输出路径>

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/screenguard_icon_1024.png"

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { fatalError("无法创建位图") }

NSGraphicsContext.saveGraphicsState()
guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("无法创建图形上下文")
}
NSGraphicsContext.current = graphicsContext
let cg = graphicsContext.cgContext

// macOS 大图标圆角比例
let radius = CGFloat(size) * 0.2237
let iconPath = CGPath(
    roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
    cornerWidth: radius,
    cornerHeight: radius,
    transform: nil
)
cg.addPath(iconPath)
cg.clip()

// 紫 → 靛蓝渐变底
let baseColors = [
    NSColor(red: 0.49, green: 0.37, blue: 0.98, alpha: 1).cgColor,
    NSColor(red: 0.31, green: 0.27, blue: 0.90, alpha: 1).cgColor
]
let baseGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: baseColors as CFArray,
    locations: [0, 1]
)!
cg.drawLinearGradient(
    baseGradient,
    start: CGPoint(x: 0, y: 0),
    end: CGPoint(x: 0, y: size),
    options: []
)

// 左上柔光
let highlight = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        NSColor.white.withAlphaComponent(0.20).cgColor,
        NSColor.white.withAlphaComponent(0).cgColor
    ] as CFArray,
    locations: [0, 1]
)!
cg.drawRadialGradient(
    highlight,
    startCenter: CGPoint(x: size * 0.26, y: size * 0.82),
    startRadius: 0,
    endCenter: CGPoint(x: size * 0.26, y: size * 0.82),
    endRadius: size * 0.95,
    options: []
)

let center = CGPoint(x: size / 2, y: size / 2)

// 手掌背后的柔光晕（偏移到掌心上方，避免在镂空处形成亮斑）
let glow = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        NSColor.white.withAlphaComponent(0.12).cgColor,
        NSColor.white.withAlphaComponent(0).cgColor
    ] as CFArray,
    locations: [0, 1]
)!
let glowCenter = CGPoint(x: size * 0.5, y: size * 0.62)
cg.drawRadialGradient(
    glow,
    startCenter: glowCenter,
    startRadius: size * 0.18,
    endCenter: glowCenter,
    endRadius: size * 0.52,
    options: []
)

// SF Symbols 手掌，染成纯白
let symbolNames = ["hand.raised.fingers.spread", "hand.raised", "hand"]
var symbol: NSImage?
for name in symbolNames {
    if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
        symbol = image
        break
    }
}
guard let symbol else { fatalError("系统缺少手掌符号") }

let config = NSImage.SymbolConfiguration(pointSize: 520, weight: .medium, scale: .large)
guard let configured = symbol.withSymbolConfiguration(config) else {
    fatalError("符号配置失败")
}

let whiteSymbol = NSImage(size: configured.size, flipped: false) { rect in
    configured.draw(in: rect)
    NSColor.white.setFill()
    rect.fill(using: .sourceIn)
    return true
}

let symbolRect = CGRect(
    x: (size - whiteSymbol.size.width) / 2,
    y: (size - whiteSymbol.size.height) / 2 - size * 0.012,
    width: whiteSymbol.size.width,
    height: whiteSymbol.size.height
)
whiteSymbol.draw(in: symbolRect)

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("PNG 编码失败")
}
try png.write(to: URL(fileURLWithPath: output), options: .atomic)
print(output)
