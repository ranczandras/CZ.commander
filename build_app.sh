#!/bin/zsh
set -e

PROJECT_DIR="${0:A:h}"
APP_NAME="CZ.commander"
BUILD_DIR="${CZ_BUILD_DIR:-$HOME/.cache/czcommander-build}"
# Assemble + sign on a local disk: network/Drive volumes add xattrs ("detritus") that break codesign.
STAGE_DIR="$BUILD_DIR/stage"
APP_BUNDLE="$STAGE_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> [1/4] Building Release arm64 binary for Apple Silicon (M-Series)..."
cd "$PROJECT_DIR"
# Build from a local mirror: the project lives on a network/Drive volume whose sync touches
# file mtimes mid-build ("input file was modified during the build").
SRC_MIRROR="$BUILD_DIR/src"
mkdir -p "$SRC_MIRROR"
rsync -a --delete --exclude ".git" --exclude "*.app" --exclude ".DS_Store" --exclude "docs" "$PROJECT_DIR/" "$SRC_MIRROR/"
cd "$SRC_MIRROR"
swift build -c release --arch arm64 --scratch-path "$BUILD_DIR" --disable-sandbox
cd "$PROJECT_DIR"

BINARY_PATH="$BUILD_DIR/arm64-apple-macosx/release/CZCommander"
if [ ! -f "$BINARY_PATH" ]; then
    BINARY_PATH="$BUILD_DIR/release/CZCommander"
fi

echo "==> [2/4] Creating $APP_NAME.app bundle structure..."
rm -rf "$APP_BUNDLE"
mkdir -p "$STAGE_DIR" "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BINARY_PATH" "$MACOS_DIR/CZCommander"
chmod +x "$MACOS_DIR/CZCommander"

echo "==> [3/4] Generating high-resolution macOS AppIcon.icns..."
ICONSET_DIR="/tmp/CZCommander.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

swift - "$ICONSET_DIR" << 'SWIFT_ICON'
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "/tmp/CZCommander.iconset"

func renderIcon(size: Int, filename: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext

    let s = CGFloat(size)

    // CZ.commander icon: midnight-blue squircle, blue + red folders, two-way arrows.
    // Drawn in a 120-unit design space (y down), placed on the macOS icon grid (~80% with margin).
    let k = s * 0.805 / 120.0
    let margin = s * (1.0 - 0.805) / 2.0
    cg.translateBy(x: 0, y: s)
    cg.scaleBy(x: 1, y: -1)
    cg.translateBy(x: margin, y: margin)
    cg.scaleBy(x: k, y: k)

    let space = CGColorSpaceCreateDeviceRGB()
    func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    func vGradient(_ path: CGPath, _ top: UInt32, _ bottom: UInt32) {
        cg.saveGState()
        cg.addPath(path); cg.clip()
        let box = path.boundingBox
        let g = CGGradient(colorsSpace: space, colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
        cg.drawLinearGradient(g, start: CGPoint(x: 0, y: box.minY), end: CGPoint(x: 0, y: box.maxY), options: [])
        cg.restoreGState()
    }
    func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
    }

    // Background squircle with soft drop shadow
    let bg = rr(0, 0, 120, 120, 27)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -2.5 * k), blur: 6 * k, color: rgb(0x000000, 0.35))
    cg.addPath(bg); cg.setFillColor(rgb(0x0A0F1E)); cg.fillPath()
    cg.restoreGState()
    vGradient(bg, 0x1E2A4A, 0x0A0F1E)
    cg.saveGState()
    cg.addPath(bg); cg.clip()
    // Glass reflection band (mirror effect) over the top half
    let band = rr(4, 4, 112, 52, 24)
    cg.addPath(band); cg.clip()
    let gloss = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.17), rgb(0xFFFFFF, 0.05)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gloss, start: CGPoint(x: 0, y: 4), end: CGPoint(x: 0, y: 56), options: [])
    cg.restoreGState()
    cg.addPath(rr(0.5, 0.5, 119, 119, 26.5)); cg.setStrokeColor(rgb(0xFFFFFF, 0.10)); cg.setLineWidth(1); cg.strokePath()

    // Folder: tab + back, then gradient front face with square top corners
    func folder(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, back: UInt32, faceTop: UInt32, faceBottom: UInt32, shadow: Bool) {
        cg.saveGState()
        if shadow { cg.setShadow(offset: CGSize(width: 0, height: -2 * k), blur: 5 * k, color: rgb(0x000000, 0.45)) }
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        cg.setFillColor(rgb(back))
        cg.addPath(rr(x, y, w * 0.50, 14, 7)); cg.fillPath()
        cg.fill(CGRect(x: x, y: y + 7, width: w * 0.50, height: 7))
        cg.addPath(rr(x, y + 7, w, h - 7, 7)); cg.fillPath()
        cg.fill(CGRect(x: x, y: y + 7, width: 7, height: 7))
        let face = CGMutablePath()
        face.addPath(rr(x, y + 15, w, h - 15, 7))
        face.addRect(CGRect(x: x, y: y + 15, width: w, height: 8))
        let faceClip = CGMutablePath()
        faceClip.addRect(CGRect(x: x, y: y + 15, width: w, height: 8))
        faceClip.addPath(rr(x, y + 15, w, h - 15, 7))
        vGradient(faceClip, faceTop, faceBottom)
        cg.setFillColor(rgb(0xFFFFFF, 0.55)); cg.fill(CGRect(x: x, y: y + 15, width: w, height: 1.5))
        cg.endTransparencyLayer()
        cg.restoreGState()
    }
    folder(x: 18, y: 31, w: 61, h: 49, back: 0x2F86F0, faceTop: 0x7CC2FF, faceBottom: 0x2F86F0, shadow: false)
    folder(x: 41, y: 45, w: 61, h: 51, back: 0xC81E2E, faceTop: 0xFF6B6B, faceBottom: 0xDE2A3A, shadow: true)

    // Two-way arrows
    cg.setLineCap(.round); cg.setLineJoin(.round); cg.setLineWidth(3.5)
    cg.setStrokeColor(rgb(0xFFFFFF))
    cg.move(to: CGPoint(x: 56, y: 72)); cg.addLine(to: CGPoint(x: 82, y: 72))
    cg.move(to: CGPoint(x: 76, y: 67)); cg.addLine(to: CGPoint(x: 82, y: 72)); cg.addLine(to: CGPoint(x: 76, y: 77))
    cg.strokePath()
    cg.setStrokeColor(rgb(0xFFFFFF, 0.78))
    cg.move(to: CGPoint(x: 87, y: 85)); cg.addLine(to: CGPoint(x: 61, y: 85))
    cg.move(to: CGPoint(x: 67, y: 80)); cg.addLine(to: CGPoint(x: 61, y: 85)); cg.addLine(to: CGPoint(x: 67, y: 90))
    cg.strokePath()
    NSGraphicsContext.restoreGraphicsState()
    if let pngData = rep.representation(using: .png, properties: [:]) {
        try? pngData.write(to: URL(fileURLWithPath: "\(outDir)/\(filename)"))
    }
}

let specs: [(Int, String)] = [
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
for (sz, name) in specs {
    renderIcon(size: sz, filename: name)
}
SWIFT_ICON

/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns" || true

cat << 'PLIST' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>CZCommander</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.czcommander.macos</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>CZ.commander</string>
    <key>CFBundleDisplayName</key>
    <string>CZ.commander</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>__CZ_VERSION__</string>
    <key>CFBundleVersion</key>
    <string>__CZ_BUILD__</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>CZ.commander needs access to your files and folders for file management.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>CZ.commander needs access to your files and folders for file management.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>CZ.commander needs access to your files and folders for file management.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>CZ.commander needs access to external drives and volumes for file management.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>CZ.commander asks Finder to empty the Trash when it has no Full Disk Access, and uses System Events to list and change your Login Items.</string>
    <key>NSNetworkVolumesUsageDescription</key>
    <string>CZ.commander needs access to network volumes for file management.</string>
</dict>
</plist>
PLIST

# Version comes from the VERSION file; build number = number of commits (or 1 outside git)
APP_VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
APP_BUILD="$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/bin/sed -i '' -e "s/__CZ_VERSION__/$APP_VERSION/" -e "s/__CZ_BUILD__/$APP_BUILD/" "$CONTENTS_DIR/Info.plist"
echo "    version $APP_VERSION ($APP_BUILD)"

echo -n "APPL????" > "$CONTENTS_DIR/PkgInfo"

echo "==> [4/4] Signing $APP_NAME.app..."
# Sign with the stable local identity when available so macOS privacy grants (removable volumes,
# Full Disk Access) survive rebuilds; ad-hoc signatures change every build and macOS asks again.
SIGN_ID="${CZ_SIGN_ID:-CZ.commander Local Signing}"
if /usr/bin/security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
    echo "    signing with: $SIGN_ID"
    /usr/bin/codesign --force --deep --identifier com.czcommander.macos --sign "$SIGN_ID" "$APP_BUNDLE"
else
    echo "    WARNING: '$SIGN_ID' not found, ad-hoc signing (privacy prompts will repeat after rebuilds)"
    /usr/bin/codesign --force --deep --identifier com.czcommander.macos --sign - "$APP_BUNDLE" 2>/dev/null || true
fi
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
if [[ "${CZ_SKIP_INSTALL:-0}" != "1" ]]; then
    rm -rf "/Applications/$APP_NAME.app"
    /usr/bin/ditto --noextattr --noqtn "$APP_BUNDLE" "/Applications/$APP_NAME.app"
fi
rm -rf "$PROJECT_DIR/$APP_NAME.app"
/usr/bin/ditto --noextattr --noqtn "$APP_BUNDLE" "$PROJECT_DIR/$APP_NAME.app"

echo "==> Build Complete: $APP_BUNDLE (installed to /Applications unless CZ_SKIP_INSTALL=1)"
file "$APP_BUNDLE/Contents/MacOS/CZCommander"
