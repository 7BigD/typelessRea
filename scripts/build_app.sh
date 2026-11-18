#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="TypelessLite"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "[1/5] Building $APP_NAME in release mode..."
cd "$ROOT_DIR"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
if [ ! -f "$BIN_PATH" ]; then
  echo "Error: Binary not found at $BIN_PATH"
  exit 1
fi

echo "[2/5] Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

echo "[3/5] Generating clean-room AppIcon.icns..."
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
swift - "$ICONSET_DIR" << 'SWIFT'
import AppKit

let outDir = CommandLine.arguments[1]
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

func renderIcon(px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 0, y: 0, width: px, height: px)
    let inset = CGFloat(px) * 0.08
    let bgRect = rect.insetBy(dx: inset, dy: inset)
    let radius = CGFloat(px) * 0.22
    let path = NSBezierPath(roundedRect: bgRect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.98, alpha: 1.0),
        NSColor(calibratedRed: 0.42, green: 0.25, blue: 0.92, alpha: 1.0)
    ])
    gradient?.draw(in: path, angle: -45)

    // Minimalist 5-bar waveform mark
    let barCount = 5
    let heights: [CGFloat] = [0.24, 0.44, 0.62, 0.40, 0.26]
    let barWidth = CGFloat(px) * 0.068
    let spacing = CGFloat(px) * 0.052
    let totalW = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
    let startX = (CGFloat(px) - totalW) / 2.0
    NSColor.white.setFill()
    for i in 0..<barCount {
        let h = CGFloat(px) * heights[i]
        let x = startX + CGFloat(i) * (barWidth + spacing)
        let y = (CGFloat(px) - h) / 2.0
        let bar = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: h), xRadius: barWidth / 2, yRadius: barWidth / 2)
        bar.fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for (px, name) in sizes {
    if let data = renderIcon(px: px) {
        try? data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    }
}
SWIFT

if command -v iconutil >/dev/null 2>&1; then
  iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns" || true
fi
rm -rf "$(dirname "$ICONSET_DIR")"

echo "[4/5] Writing Info.plist..."
cat > "$CONTENTS_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>TypelessLite</string>
    <key>CFBundleExecutable</key>
    <string>TypelessLite</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>local.typelesslite.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>TypelessLite</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>TypelessLite 需要访问您的麦克风以进行语音口述、AI 指令和实时翻译。</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>TypelessLite 可以使用 macOS 原生语音识别引擎在本地或免 Key 模式下转写您的语音。</string>
</dict>
</plist>
EOF

echo "[5/5] Ad-hoc codesigning $APP_BUNDLE..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "Build complete:"
ls -lh "$MACOS_DIR/$APP_NAME"
du -sh "$APP_BUNDLE"
codesign -dv "$APP_BUNDLE" 2>&1 || true
