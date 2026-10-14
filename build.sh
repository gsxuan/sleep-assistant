#!/bin/sh
# 一键编译并安装「休眠助手 / Sleep Assistant」到 /Applications
# 用法：./build.sh
set -e

APP_NAME="休眠助手"
APP="/Applications/${APP_NAME}.app"
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/.build"
mkdir -p "$BUILD"

echo "==> 1/4 编译 app"
swiftc -O -o "$BUILD/CaffeinateToggle" "$HERE/app/main.swift"

echo "==> 2/4 渲染应用图标 (1024x1024 -> AppIcon.icns)"
swiftc -O -o "$BUILD/iconrender" "$HERE/icon/main.swift"
"$BUILD/iconrender" "$BUILD/appicon_1024.png"

ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for spec in "16 16 icon_16x16" "32 32 icon_16x16@2x" "32 32 icon_32x32" \
            "64 64 icon_32x32@2x" "128 128 icon_128x128" "256 256 icon_128x128@2x" \
            "256 256 icon_256x256" "512 512 icon_256x256@2x" "512 512 icon_512x512" \
            "1024 1024 icon_512x512@2x"; do
    set -- $spec
    sips -z "$1" "$1" "$BUILD/appicon_1024.png" --out "$ICONSET/$3.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUILD/AppIcon.icns"

echo "==> 3/4 组装 ${APP_NAME}.app"
pkill -x CaffeinateToggle 2>/dev/null || true
sleep 1
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/Info.plist"                        "$APP/Contents/Info.plist"
cp "$BUILD/CaffeinateToggle"                 "$APP/Contents/MacOS/CaffeinateToggle"
cp "$BUILD/AppIcon.icns"                     "$APP/Contents/Resources/AppIcon.icns"
cp "$HERE/app/com.think.caffeinate.plist"    "$APP/Contents/Resources/com.think.caffeinate.plist"
cp "$HERE/app/caffeinate-toggle-helper"      "$APP/Contents/Resources/caffeinate-toggle-helper"
chmod +x "$APP/Contents/MacOS/CaffeinateToggle" "$APP/Contents/Resources/caffeinate-toggle-helper"

echo "==> 4/4 签名并启动"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "(ad-hoc 签名失败，可忽略)"
open "$APP"
echo "完成：$APP"
