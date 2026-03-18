#!/bin/bash
set -euo pipefail

APP_NAME="pmux"
BUNDLE_DIR="build/${APP_NAME}.app"
CONTENTS="${BUNDLE_DIR}/Contents"
ARCH="${1:-arm64}"

echo "==> Building for ${ARCH}..."
swift build -c release --arch ${ARCH} 2>&1

BUILD_DIR=$(swift build -c release --arch ${ARCH} --show-bin-path)

echo "==> Assembling ${APP_NAME}.app..."
rm -rf "${BUNDLE_DIR}"
mkdir -p "${CONTENTS}/MacOS"
mkdir -p "${CONTENTS}/Frameworks"
mkdir -p "${CONTENTS}/Resources"

# Executable
cp "${BUILD_DIR}/PMuxViewer" "${CONTENTS}/MacOS/PMuxViewer"

# Parsec SDK dylib
if [ "$ARCH" = "x86_64" ]; then
    cp Sources/CParsecBridge/include/libparsec-x86_64.dylib "${CONTENTS}/Frameworks/libparsec.dylib"
else
    cp Sources/CParsecBridge/include/libparsec.dylib "${CONTENTS}/Frameworks/libparsec.dylib"
fi
install_name_tool -id @rpath/libparsec.dylib "${CONTENTS}/Frameworks/libparsec.dylib"

# Generate app icon
echo "==> Generating app icon..."
python3 - "${CONTENTS}/Resources" << 'PYICON'
import struct, zlib, sys, os

out_dir = sys.argv[1]

def make_png(size, pixels_func):
    w = h = size
    raw = b''
    for y in range(h):
        raw += b'\x00'  # filter none
        for x in range(w):
            raw += pixels_func(x, y, w, h)

    def chunk(ctype, data):
        c = ctype + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)

    ihdr = struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')

def pmux_icon(x, y, w, h):
    cx, cy = w/2, h/2
    r = w * 0.42
    margin = w * 0.06

    # Distance from center for hexagon test
    dx, dy = abs(x - cx), abs(y - cy)
    # Rounded hexagon approximation
    in_hex = (dx / r + dy / r * 1.73 < 1.73) and dx < r * 0.98 and dy < r * 0.88
    corner_r = w * 0.08

    if not in_hex:
        return b'\x00\x00\x00\x00'  # transparent

    # Background: dark navy
    bg = (26, 27, 46, 255)  # #1a1b2e

    # 2x2 grid of "screens" inside hexagon
    gap = w * 0.04
    grid_r = r * 0.52
    gx, gy = x - cx, y - cy

    # Four quadrants with gap
    in_screen = False
    screen_active = False
    if abs(gx) > gap and abs(gy) > gap:
        if abs(gx) < grid_r and abs(gy) < grid_r:
            in_screen = True
            # Top-left screen is "active" (brighter)
            screen_active = gx < 0 and gy < 0

    if in_screen:
        if screen_active:
            return bytes((32, 145, 246, 255))  # #2091f6 accent blue
        else:
            return bytes((59, 163, 255, 180))  # #3ba3ff lighter, semi-transparent

    # Connection dots at grid intersections
    dot_r = w * 0.025
    for dot_x, dot_y in [(0, 0), (0, -grid_r*0.5), (0, grid_r*0.5),
                          (-grid_r*0.5, 0), (grid_r*0.5, 0)]:
        ddx, ddy = gx - dot_x, gy - dot_y
        if ddx*ddx + ddy*ddy < dot_r*dot_r:
            return bytes((32, 145, 246, 255))  # accent dot

    return bytes(bg)

# Generate sizes for iconset
iconset = os.path.join(out_dir, 'AppIcon.iconset')
os.makedirs(iconset, exist_ok=True)

sizes = [
    (16, 'icon_16x16.png'), (32, 'icon_16x16@2x.png'),
    (32, 'icon_32x32.png'), (64, 'icon_32x32@2x.png'),
    (128, 'icon_128x128.png'), (256, 'icon_128x128@2x.png'),
    (256, 'icon_256x256.png'), (512, 'icon_256x256@2x.png'),
    (512, 'icon_512x512.png'), (1024, 'icon_512x512@2x.png'),
]

for sz, name in sizes:
    png = make_png(sz, pmux_icon)
    with open(os.path.join(iconset, name), 'wb') as f:
        f.write(png)
    print(f"  {name} ({sz}x{sz})")

PYICON

# Convert iconset to icns
if [ -d "${CONTENTS}/Resources/AppIcon.iconset" ]; then
    iconutil -c icns "${CONTENTS}/Resources/AppIcon.iconset" -o "${CONTENTS}/Resources/AppIcon.icns" 2>/dev/null || true
    rm -rf "${CONTENTS}/Resources/AppIcon.iconset"
fi

# Info.plist
cat > "${CONTENTS}/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>PMuxViewer</string>
    <key>CFBundleIdentifier</key><string>com.parsecmux.pmux</string>
    <key>CFBundleName</key><string>pmux</string>
    <key>CFBundleDisplayName</key><string>pmux</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSMicrophoneUsageDescription</key><string>pmux needs microphone access for audio streaming.</string>
</dict>
</plist>
PLIST

# PkgInfo
echo -n "APPL????" > "${CONTENTS}/PkgInfo"

# Codesign (ad-hoc)
echo "==> Codesigning..."
codesign --force --sign - "${CONTENTS}/Frameworks/libparsec.dylib" 2>/dev/null || true
codesign --force --deep --sign - "${BUNDLE_DIR}" 2>/dev/null || true

echo "==> Done: ${BUNDLE_DIR} (${ARCH})"
echo "   Run: open \"${BUNDLE_DIR}\""
