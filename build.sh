#!/bin/bash
# 构建「守夜」.app（原生 Swift / AppKit，使用系统自带 Command Line Tools，无需 Xcode 许可）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CLT=/Library/Developer/CommandLineTools
SWIFTC="$CLT/usr/bin/swiftc"
SDK="$CLT/SDKs/MacOSX27.0.sdk"
OUT="$ROOT/build/守夜.app"

[ -x "$SWIFTC" ] || { echo "找不到 Swift 编译器：$SWIFTC"; exit 1; }
[ -d "$SDK" ]    || { echo "找不到 SDK：$SDK"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 生成图标"
"$SWIFTC" -O -sdk "$SDK" -framework AppKit -o "$WORK/make-icon" "$ROOT/make-icon.swift"
mkdir -p "$WORK/AppIcon.iconset"
"$WORK/make-icon" "$WORK/AppIcon.iconset" >/dev/null
/usr/bin/iconutil -c icns "$WORK/AppIcon.iconset" -o "$WORK/AppIcon.icns"

echo "==> 编译主程序"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
"$SWIFTC" -O \
  -target arm64-apple-macos13.0 \
  -sdk "$SDK" \
  -framework Cocoa \
  -o "$OUT/Contents/MacOS/LidGuard" \
  "$ROOT/main.swift"

cp "$ROOT/Info.plist" "$OUT/Contents/Info.plist"
cp "$WORK/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"

echo "==> 临时签名（本机自用）"
/usr/bin/codesign --force --sign - --timestamp=none "$OUT" 2>&1 | sed 's/^/    /'

echo "==> 完成：$OUT"
du -sh "$OUT" | sed 's/^/    体积：/'
