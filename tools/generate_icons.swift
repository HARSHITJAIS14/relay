#!/usr/bin/env swift
// Render the existing vector brand mark into native platform icon resources.
import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let svg = try XMLDocument(contentsOf: root.appendingPathComponent("assets/relay-mark.svg"))
let element = svg.rootElement()!
let rectangle = element.elements(forName: "rect")[0]
let mark = element.elements(forName: "path")[0]
let pathData = mark.attribute(forName: "d")!.stringValue!
let colorHex = rectangle.attribute(forName: "fill")!.stringValue!
let radius = Double(rectangle.attribute(forName: "rx")!.stringValue!)!
let strokeWidth = Double(mark.attribute(forName: "stroke-width")!.stringValue!)!
let rgb = UInt32(colorHex.dropFirst(), radix: 16)!
let green = NSColor(srgbRed: Double((rgb >> 16) & 255) / 255,
                    green: Double((rgb >> 8) & 255) / 255,
                    blue: Double(rgb & 255) / 255, alpha: 1)

// The master mark uses only absolute M, L and V commands.
let expression = try NSRegularExpression(pattern: "[MLV]|[0-9]+(?:\\.[0-9]+)?")
let tokens = expression.matches(in: pathData, range: NSRange(pathData.startIndex..., in: pathData))
    .map { String(pathData[Range($0.range, in: pathData)!]) }
let path = NSBezierPath()
var index = 0
var point = NSPoint.zero
while index < tokens.count {
    let command = tokens[index]
    index += 1
    switch command {
    case "M", "L":
        point = NSPoint(x: Double(tokens[index])!, y: Double(tokens[index + 1])!)
        index += 2
        if command == "M" { path.move(to: point) } else { path.line(to: point) }
    case "V":
        point.y = Double(tokens[index])!
        index += 1
        path.line(to: point)
    default: fatalError("Unsupported command in the master icon: \(command)")
    }
}
path.lineWidth = strokeWidth
path.lineCapStyle = .round
path.lineJoinStyle = .round

func render(_ size: Int, to url: URL, menuBar: Bool = false, macInset: Bool = false) throws {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    let inset = macInset ? Double(size) * 100 / 1024 : 0
    context.translateBy(x: inset, y: Double(size) - inset)
    let scale = (Double(size) - inset * 2) / 36
    context.scaleBy(x: scale, y: -scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    if !menuBar {
        green.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 36, height: 36),
                     xRadius: radius, yRadius: radius).fill()
    }
    (menuBar ? NSColor.black : NSColor.white).setStroke()
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

let resources = root.appendingPathComponent("apps/macos/Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for size in [16, 32, 128, 256, 512] {
    try render(size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"), macInset: true)
    try render(size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"), macInset: true)
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("Could not create the Mac icon") }
try render(128, to: resources.appendingPathComponent("RelayMark.png"))
try render(18, to: resources.appendingPathComponent("MenuBarIcon.png"), menuBar: true)
try render(36, to: resources.appendingPathComponent("MenuBarIcon@2x.png"), menuBar: true)
try render(1024, to: root.appendingPathComponent("assets/relay-icon-preview.png"), macInset: true)
let android = root.appendingPathComponent("apps/android/app/src/main/res")
for (density, size) in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)] {
    try render(size, to: android.appendingPathComponent("mipmap-\(density)/ic_launcher.png"))
}
try render(256, to: android.appendingPathComponent("drawable/ic_logo.png"))
// Adaptive launcher masks are applied by Android; the foreground stays in its safe area.
let foreground = """
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="48" android:viewportHeight="48">
    <group android:translateX="6" android:translateY="6">
        <path android:fillColor="@android:color/transparent"
            android:strokeColor="#FFFFFF" android:strokeWidth="\(strokeWidth)"
            android:strokeLineCap="round" android:strokeLineJoin="round"
            android:pathData="\(pathData)" />
    </group>
</vector>
"""
let header = """
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="36dp" android:height="36dp"
    android:viewportWidth="36" android:viewportHeight="36">
    <path android:fillColor="\(colorHex)"
        android:pathData="M\(radius),0H\(36-radius)Q36,0 36,\(radius)V\(36-radius)Q36,36 \(36-radius),36H\(radius)Q0,36 0,\(36-radius)V\(radius)Q0,0 \(radius),0Z" />
    <path android:fillColor="@android:color/transparent"
        android:strokeColor="#FFFFFF" android:strokeWidth="\(strokeWidth)"
        android:strokeLineCap="round" android:strokeLineJoin="round"
        android:pathData="\(pathData)" />
</vector>
"""
let adaptive = """
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/relay_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_foreground" />
</adaptive-icon>
"""
for (name, contents) in [("drawable/ic_launcher_foreground.xml", foreground),
                         ("drawable/ic_relay_mark.xml", header),
                         ("mipmap-anydpi-v26/ic_launcher.xml", adaptive.replacingOccurrences(of: "    <monochrome android:drawable=\"@drawable/ic_launcher_foreground\" />\n", with: "")),
                         ("mipmap-anydpi-v33/ic_launcher.xml", adaptive),
                         ("values/relay_colors.xml", "<resources><color name=\"relay_launcher_background\">\(colorHex)</color></resources>\n")] {
    let url = android.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (contents + "\n").write(to: url, atomically: true, encoding: .utf8)
}
print("Generated matching Mac, Android and menu-bar icons from assets/relay-mark.svg")
