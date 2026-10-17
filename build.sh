#!/bin/bash
# 构建「守夜」.app —— 原生 Swift / AppKit，使用系统自带的 Command Line Tools
# 不需要 Xcode 完整版，也不需要接受 Xcode 许可（本脚本直接调用 CLT 里的编译器）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build/守夜.app"

# ---- 定位工具链 ----------------------------------------------------------
# 优先用独立安装的 Command Line Tools；没有的话退回 xcode-select 指定的路径。
CLT="${CLT_DIR:-/Library/Developer/CommandLineTools}"
SWIFTC="$CLT/usr/bin/swiftc"

if [ ! -x "$SWIFTC" ]; then
  DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
  if [ -n "$DEV_DIR" ] && [ -x "$DEV_DIR/usr/bin/swiftc" ]; then
    SWIFTC="$DEV_DIR/usr/bin/swiftc"
    CLT="$DEV_DIR"
  fi
fi

if [ ! -x "$SWIFTC" ]; then
  cat <<'EOF'
✗ 找不到 Swift 编译器。

请先安装 Command Line Tools（约 1.3 GB，不需要装 Xcode 完整版）：

    xcode-select --install

装完后重新运行 ./build.sh
EOF
  exit 1
fi

# ---- 定位 SDK ------------------------------------------------------------
# MacOSX.sdk 是指向当前 SDK 的符号链接，跨系统版本最稳；也允许用 SDK_PATH 覆盖。
SDK="${SDK_PATH:-$CLT/SDKs/MacOSX.sdk}"
if [ ! -d "$SDK" ]; then
  SDK="$(ls -d "$CLT"/SDKs/MacOSX*.sdk 2>/dev/null | sort | tail -1 || true)"
fi
if [ ! -d "$SDK" ]; then
  echo "✗ 找不到 macOS SDK（已尝试 $CLT/SDKs）"; exit 1
fi

echo "==> 工具链：$SWIFTC"
echo "==> SDK   ：$SDK"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- 生成图标 ------------------------------------------------------------
echo "==> 生成图标"
"$SWIFTC" -O -sdk "$SDK" -framework AppKit -o "$WORK/make-icon" "$ROOT/make-icon.swift"
mkdir -p "$WORK/AppIcon.iconset"
"$WORK/make-icon" "$WORK/AppIcon.iconset" >/dev/null
/usr/bin/iconutil -c icns "$WORK/AppIcon.iconset" -o "$WORK/AppIcon.icns"

# ---- 编译主程序 ----------------------------------------------------------
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

# ---- 签名 ----------------------------------------------------------------
# ad-hoc 签名（不依赖开发者证书）。首次打开可能仍需右键 → 打开。
echo "==> ad-hoc 签名"
/usr/bin/codesign --force --sign - --timestamp=none "$OUT" 2>&1 | sed 's/^/    /'

echo
echo "==> 完成：$OUT"
du -sh "$OUT" | sed 's/^/    体积：/'
echo "    运行：open \"$OUT\""
