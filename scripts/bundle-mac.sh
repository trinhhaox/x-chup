#!/usr/bin/env bash
# Build and package xChup.app into /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="xChup"
APP_DIR="/Applications/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
LOCAL_BIN="${HOME}/.local/bin"

echo "==> 1. Building release binaries (cargo)..."
cargo build --release -p snip-cli -p snip-daemon

echo "==> 2. Generating AppIcon.icns..."
mkdir -p /tmp/AppIcon.iconset
cat << 'SWIFT_EOF' > /tmp/gen_icns.swift
import AppKit

func renderIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.05
    let iconRect = rect.insetBy(dx: inset, dy: inset)
    let cornerRadius = size * 0.22

    ctx.saveGState()
    let path = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        NSColor(red: 0.10, green: 0.08, blue: 0.26, alpha: 1.0).cgColor,
        NSColor(red: 0.22, green: 0.16, blue: 0.52, alpha: 1.0).cgColor,
        NSColor(red: 0.10, green: 0.42, blue: 0.88, alpha: 1.0).cgColor
    ] as CFArray
    let locations: [CGFloat] = [0.0, 0.45, 1.0]
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations)!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

    let pad = size * 0.22
    let cornerLen = size * 0.16
    let strokeW = size * 0.045
    ctx.setLineWidth(strokeW)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)

    // Viewfinder brackets
    ctx.move(to: CGPoint(x: pad, y: size - pad - cornerLen))
    ctx.addLine(to: CGPoint(x: pad, y: size - pad))
    ctx.addLine(to: CGPoint(x: pad + cornerLen, y: size - pad))
    ctx.strokePath()

    ctx.move(to: CGPoint(x: size - pad - cornerLen, y: size - pad))
    ctx.addLine(to: CGPoint(x: size - pad, y: size - pad))
    ctx.addLine(to: CGPoint(x: size - pad, y: size - pad - cornerLen))
    ctx.strokePath()

    ctx.move(to: CGPoint(x: pad, y: pad + cornerLen))
    ctx.addLine(to: CGPoint(x: pad, y: pad))
    ctx.addLine(to: CGPoint(x: pad + cornerLen, y: pad))
    ctx.strokePath()

    ctx.move(to: CGPoint(x: size - pad - cornerLen, y: pad))
    ctx.addLine(to: CGPoint(x: size - pad, y: pad))
    ctx.addLine(to: CGPoint(x: size - pad, y: pad + cornerLen))
    ctx.strokePath()

    // Lens
    let center = CGPoint(x: size * 0.5, y: size * 0.5)
    let lensR = size * 0.14
    let lensRect = CGRect(x: center.x - lensR, y: center.y - lensR, width: lensR * 2, height: lensR * 2)

    let lensColors = [
        NSColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 0.95).cgColor,
        NSColor(red: 0.05, green: 0.4, blue: 0.95, alpha: 0.95).cgColor
    ] as CFArray
    let lensGrad = CGGradient(colorsSpace: colorSpace, colors: lensColors, locations: [0.0, 1.0])!
    ctx.saveGState()
    ctx.addEllipse(in: lensRect)
    ctx.clip()
    ctx.drawLinearGradient(lensGrad, start: CGPoint(x: center.x, y: center.y + lensR), end: CGPoint(x: center.x, y: center.y - lensR), options: [])
    ctx.restoreGState()

    ctx.setLineWidth(size * 0.02)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
    ctx.strokeEllipse(in: lensRect)

    let dotR = size * 0.035
    let dotRect = CGRect(x: center.x - dotR * 1.5, y: center.y + dotR * 0.8, width: dotR * 2, height: dotR * 2)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
    ctx.fillEllipse(in: dotRect)

    ctx.restoreGState()
    img.unlockFocus()
    return img
}

func savePNG(image: NSImage, path: String) {
    if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

let iconsetDir = "/tmp/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconsetDir)
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let sizes: [(Int, Int, String)] = [
    (16, 1, "icon_16x16.png"),
    (16, 2, "icon_16x16@2x.png"),
    (32, 1, "icon_32x32.png"),
    (32, 2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png")
]

for (baseSize, scale, name) in sizes {
    let px = CGFloat(baseSize * scale)
    let img = renderIcon(size: px)
    savePNG(image: img, path: "\(iconsetDir)/\(name)")
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir, "-o", "/tmp/AppIcon.icns"]
try? task.run()
task.waitUntilExit()
SWIFT_EOF
swift /tmp/gen_icns.swift

echo "==> 3. Compiling xChup Swift UI binary..."
swiftc -O -framework AppKit -framework Carbon -framework Vision -framework ImageIO app-mac/main.swift -o /tmp/xChup

echo "==> 4. Assembling ${APP_DIR}..."
# Stop running instances first
PLIST_DIR="${HOME}/Library/LaunchAgents"
launchctl bootout "gui/$(id -u)/com.trinhhaox.xchup" 2>/dev/null || true
launchctl unload "${PLIST_DIR}/com.trinhhaox.xchup.plist" 2>/dev/null || true
pkill -9 -x xChup 2>/dev/null || true
pkill -9 -x snipd 2>/dev/null || true
pkill -9 -x snip-ui 2>/dev/null || true
sleep 1

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp /tmp/AppIcon.icns "${RESOURCES_DIR}/AppIcon.icns"
cp /tmp/xChup "${MACOS_DIR}/xChup"
cp target/release/snipd "${MACOS_DIR}/snipd"
cp target/release/snip "${MACOS_DIR}/snip"
ln -sf "xChup" "${MACOS_DIR}/snip-ui"
chmod +x "${MACOS_DIR}/xChup" "${MACOS_DIR}/snipd" "${MACOS_DIR}/snip"

# Create Info.plist
cat << 'PLIST_EOF' > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleName</key>
    <string>xChup</string>
    <key>CFBundleDisplayName</key>
    <string>xChup</string>
    <key>CFBundleIdentifier</key>
    <string>com.trinhhaox.xchup</string>
    <key>CFBundleVersion</key>
    <string>0.1.1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.1</string>
    <key>CFBundleExecutable</key>
    <string>xChup</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>xChup cần quyền ghi lại màn hình để chụp ảnh và quay video màn hình.</string>
</dict>
</plist>
PLIST_EOF

echo "APPL????" > "${CONTENTS_DIR}/PkgInfo"

echo "==> 5. Codesigning ${APP_DIR}..."
codesign --force --deep --sign - "${APP_DIR}"

echo "==> 6. Registering with LaunchServices..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${APP_DIR}"

echo "==> 7. Creating symlinks in ${LOCAL_BIN}..."
mkdir -p "${LOCAL_BIN}"
ln -sf "${MACOS_DIR}/snip" "${LOCAL_BIN}/snip"
ln -sf "${MACOS_DIR}/snipd" "${LOCAL_BIN}/snipd"
ln -sf "${MACOS_DIR}/xChup" "${LOCAL_BIN}/snip-ui"
ln -sf "${MACOS_DIR}/xChup" "${LOCAL_BIN}/xchup"

# Remove any legacy launchctl agents
PLIST_DIR="${HOME}/Library/LaunchAgents"
launchctl bootout "gui/$(id -u)/com.trinhhaox.xchup" 2>/dev/null || true
launchctl unload "${PLIST_DIR}/com.trinhhaox.xchup.plist" 2>/dev/null || true
rm -f "${PLIST_DIR}/com.trinhhaox.xchup.plist" "${PLIST_DIR}/com.trinhhaox.xchup.daemon.plist" "${PLIST_DIR}/com.trinhhaox.xchup.tray.plist"

# Register Login Item for xChup.app
osascript -e '
tell application "System Events"
    if not (exists login item "xChup") then
        make login item at end with properties {path:"/Applications/xChup.app", hidden:false, name:"xChup"}
    end if
end tell
' 2>/dev/null || true

# Launch xChup as a standard user GUI application
open -a "${APP_DIR}" --args tray

echo ""
echo "=========================================================="
echo "  xChup.app has been successfully installed in /Applications!"
echo "  - App: /Applications/xChup.app"
echo "  - Icon: Embedded retina AppIcon.icns"
echo "  - Menu Bar & Daemon: Running via xChup.app"
echo "  - CLI command: snip (in ~/.local/bin/snip)"
echo "=========================================================="
