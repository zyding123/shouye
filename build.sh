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
  if [ -n "$DEV_DIR" ] && [ -x "$DEV_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" ]; then
    SWIFTC="$DEV_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    CLT="$DEV_DIR/Platforms/MacOSX.platform/Developer"
  elif [ -n "$DEV_DIR" ] && [ -x "$DEV_DIR/usr/bin/swiftc" ]; then
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
# 默认同时编译 Apple Silicon 与 Intel，再用 lipo 合成通用二进制。
# 只想编一个架构时可以：ARCHS=arm64 ./build.sh
ARCHS="${ARCHS:-arm64 x86_64}"
echo "==> 编译主程序（架构：$ARCHS)"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

SLICES=()
for A in $ARCHS; do
  echo "    编译 $A 切片"
  if ! "$SWIFTC" -O \
        -target "$A-apple-macos13.0" \
        -sdk "$SDK" \
        -framework Cocoa \
        -o "$WORK/LidGuard-$A" \
        "$ROOT/main.swift" 2> "$WORK/$A.log"; then
    echo "    ✗ $A 编译失败：" >&2
    /usr/bin/tail -20 "$WORK/$A.log" | sed 's/^/      /' >&2
    exit 1
  fi
  SLICES+=("$WORK/LidGuard-$A")
done

if [ "${#SLICES[@]}" -gt 1 ]; then
  /usr/bin/lipo -create "${SLICES[@]}" -output "$OUT/Contents/MacOS/LidGuard"
else
  /bin/cp "${SLICES[0]}" "$OUT/Contents/MacOS/LidGuard"
fi
echo "    产出的架构：$(/usr/bin/lipo -archs "$OUT/Contents/MacOS/LidGuard")"

cp "$ROOT/Info.plist" "$OUT/Contents/Info.plist"
cp "$WORK/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
# 使用不同的可执行文件名，按主进程名结束 App 时仍能保留恢复保护。
cp "$OUT/Contents/MacOS/LidGuard" "$OUT/Contents/MacOS/LidGuardWatchdog"

# ---- 签名 ----------------------------------------------------------------
# ad-hoc 签名（不依赖开发者证书）。首次打开可能仍需右键 → 打开。
echo "==> ad-hoc 签名"
/usr/bin/codesign --force --sign - --timestamp=none "$OUT/Contents/MacOS/LidGuardWatchdog" 2>&1 | sed 's/^/    /'
/usr/bin/codesign --force --sign - --timestamp=none "$OUT" 2>&1 | sed 's/^/    /'

echo
echo "==> 完成：$OUT"
du -sh "$OUT" | sed 's/^/    体积：/'
echo "    运行：open \"$OUT\""
