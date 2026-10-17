#!/bin/bash
# Package a verified arm64 App without launching it or touching power settings.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/守夜.app}"
OUT="${2:-$ROOT/build/release}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [ "$IDENTIFIER" != "com.aries.lidguard" ]; then
  echo "Unexpected app identifier: $IDENTIFIER" >&2
  exit 1
fi
case "$VERSION" in
  ''|*[!0-9.]*) echo "Invalid version: $VERSION" >&2; exit 1 ;;
esac
for BINARY in LidGuard LidGuardWatchdog; do
  /usr/bin/file "$APP/Contents/MacOS/$BINARY" | /usr/bin/grep -q 'arm64'
done
/usr/bin/codesign --verify --deep --strict "$APP"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PAYLOAD="$WORK/disk"
mkdir -p "$PAYLOAD" "$WORK/unzip" "$WORK/mount"
/usr/bin/ditto "$APP" "$PAYLOAD/守夜.app"
ln -s /Applications "$PAYLOAD/Applications"
cat > "$OUT/INSTALL.txt" <<EOF
守夜 LidGuard $VERSION

系统要求：Apple Silicon Mac（M 系列），macOS 13 或更高版本。
不支持 Intel Mac；下载预编译包后不需要 Xcode、Command Line Tools 或 Homebrew。

DMG 安装：
1. 打开 Shouye-$VERSION-macOS-arm64.dmg。
2. 把「守夜.app」拖到「Applications」文件夹。
3. 从「应用程序」打开「守夜」，按提示完成一次性管理员授权。

ZIP 安装：
解压 Shouye-$VERSION-macOS-arm64.zip，把「守夜.app」移到「应用程序」后打开。

首次打开：
本版本采用 ad-hoc 签名，尚未使用 Developer ID 证书及 Apple 公证。
如果被系统拦截，请先尝试打开 App，再到「系统设置 → 隐私与安全性」中查看
该 App 的提示，并在确认下载来源后选择「仍要打开」。无需关闭 SIP 或全局 Gatekeeper。
Apple 说明：https://support.apple.com/102445

使用：
从菜单栏确认状态为「守夜中」。开启后合盖不休眠，默认会确认锁屏并延迟息屏。
低电量保护默认在未接电源且达到 20% 时尝试恢复休眠。合盖运行时请保持散热。

更新旧版：
正常退出旧版会恢复合盖休眠。请在开盖状态下退出旧版、替换并打开新版。
正在合盖远程使用时，请勿直接退出或覆盖运行中的旧版，以免远程连接中断。

项目：https://github.com/zyding123/shouye
源代码版本：${SOURCE_COMMIT:-not recorded}
EOF
cp "$OUT/INSTALL.txt" "$PAYLOAD/安装说明.txt"

BASE="Shouye-$VERSION-macOS-arm64"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$PAYLOAD/守夜.app" "$OUT/$BASE.zip"
/usr/bin/hdiutil create -quiet -volname "守夜 $VERSION" -srcfolder "$PAYLOAD" -format UDZO -fs HFS+ "$OUT/$BASE.dmg"

# Verify extracted ZIP, then mount the DMG read-only without opening Finder.
/usr/bin/ditto -x -k "$OUT/$BASE.zip" "$WORK/unzip"
/usr/bin/codesign --verify --deep --strict "$WORK/unzip/守夜.app"
for BINARY in LidGuard LidGuardWatchdog; do
  cmp "$APP/Contents/MacOS/$BINARY" "$WORK/unzip/守夜.app/Contents/MacOS/$BINARY"
done
/usr/bin/hdiutil verify "$OUT/$BASE.dmg" >/dev/null
/usr/bin/hdiutil attach -quiet -readonly -nobrowse -mountpoint "$WORK/mount" "$OUT/$BASE.dmg"
trap '/usr/bin/hdiutil detach -quiet "$WORK/mount" 2>/dev/null || true; rm -rf "$WORK"' EXIT
/usr/bin/codesign --verify --deep --strict "$WORK/mount/守夜.app"
for BINARY in LidGuard LidGuardWatchdog; do
  cmp "$APP/Contents/MacOS/$BINARY" "$WORK/mount/守夜.app/Contents/MacOS/$BINARY"
done
test "$(readlink "$WORK/mount/Applications")" = /Applications
/usr/bin/hdiutil detach -quiet "$WORK/mount"
trap 'rm -rf "$WORK"' EXIT
(
  cd "$OUT"
  /usr/bin/shasum -a 256 "$BASE.dmg" "$BASE.zip" INSTALL.txt > SHA256SUMS.txt
)
echo "Verified release packages: $OUT"
ls -lh "$OUT/$BASE.dmg" "$OUT/$BASE.zip" "$OUT/SHA256SUMS.txt" "$OUT/INSTALL.txt"
