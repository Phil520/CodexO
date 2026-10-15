#!/bin/bash
# 编译并打包 CodexO（Codex 用量菜单栏 App）
# 用法：bash build.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="CodexO"
# 可执行文件名保持不变：CFBundleExecutable 指的是它，
# 改它要同步改 Info.plist，而它并不影响用户看到的名字。
BIN_NAME="CodexUsageMenuBar"
TARGET_APP="$PROJECT_DIR/output/$APP_NAME.app"

echo "==> 清理旧产物"
rm -rf "$TARGET_APP"
mkdir -p "$TARGET_APP/Contents/MacOS" "$TARGET_APP/Contents/Resources"

echo "==> 编译 Swift 源码"
swiftc -swift-version 5 -O -framework Cocoa \
  -o "$TARGET_APP/Contents/MacOS/$BIN_NAME" \
  "$PROJECT_DIR/src/main.swift" \
  "$PROJECT_DIR/src/UsageReader.swift" \
  "$PROJECT_DIR/src/MenuBarUI.swift" \
  "$PROJECT_DIR/src/Diagnostics.swift" \
  "$PROJECT_DIR/src/Soak.swift"

echo "==> 写入 Info.plist"
cp "$PROJECT_DIR/src/Info.plist" "$TARGET_APP/Contents/Info.plist"

echo "==> 生成 App 图标"
# 图标用现成的生成器现画，不提交二进制 .icns：
# 二进制没法 diff、改不动、review 时也看不出改了什么。
ICON_TMP="$(mktemp -d)"
if swiftc -swift-version 5 -O -framework Cocoa \
     -o "$ICON_TMP/make_icon" \
     "$PROJECT_DIR/tools/make_icon.swift" \
     "$PROJECT_DIR/src/MenuBarUI.swift" \
     "$PROJECT_DIR/src/UsageReader.swift" \
     "$PROJECT_DIR/src/Diagnostics.swift" \
     "$PROJECT_DIR/src/Soak.swift" \
  && "$ICON_TMP/make_icon" "$ICON_TMP/CodexO.iconset" >/dev/null \
  && iconutil -c icns "$ICON_TMP/CodexO.iconset" \
       -o "$TARGET_APP/Contents/Resources/$APP_NAME.icns"; then
  echo "    已生成 $APP_NAME.icns"
else
  # 图标失败不该让整个打包失败 —— App 照样能跑，只是 Finder 里是默认图标。
  # 但必须把原因打出来：上一次这里写了 2>/dev/null，失败时只剩一行
  # "图标生成失败"，完全看不出是编译没通过还是 iconutil 报错，白查一轮。
  echo "    ⚠️ 图标生成失败，App 仍可运行（Finder 里显示默认图标）"
  echo "       上面的 swiftc / iconutil 报错即为原因"
fi
rm -rf "$ICON_TMP"

echo "==> ad-hoc 签名"
codesign --force --sign - "$TARGET_APP" >/dev/null 2>&1 || echo "    签名跳过（不影响本地运行）"

echo "==> 校验签名与 Info"
codesign -dv "$TARGET_APP" 2>&1 | head -3
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$TARGET_APP/Contents/Info.plist" | sed 's/^/    版本 /'

echo "==> 完成：$TARGET_APP"
du -sh "$TARGET_APP"
