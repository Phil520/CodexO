#!/bin/bash
# 打包 CodexO.app 成可分发的 zip。
#
# ⭐⭐ 为什么单独写脚本、且必须用 `zip -X` 而不是 `ditto -c -k`
#
# 背景：2026-10-19 连续两次发布（1.0.2 / 1.0.3）产出的 zip 都是**坏的**，
# 解压后 codesign 报 "a sealed resource is missing or invalid"，
# 而打包前的 App 签名明明是有效的。
#
# 根因：`ditto -c -k` 会把 macOS 的 AppleDouble 元数据一并打进 zip，
# 表现为每个文件旁边多出一个 `._同名文件`，还会多出一个 `__MACOSX/` 目录：
#
#     CodexO.app/Contents/Info.plist
#     CodexO.app/Contents/._Info.plist        ← 这就是罪魁
#     __MACOSX/CodexO.app/Contents/...
#
# 这些 `._` 文件是**打包时才生成的**（源 App 里一个都没有），
# 它们落进 bundle 之后，`_CodeSignature/CodeResources` 里记录的哈希
# 就对不上实际文件了 —— 签名封印被破坏，Gatekeeper 直接拒绝。
#
# `zip -X` 的作用：不往归档里写扩展属性（extended attributes）。
# AppleDouble 文件正是靠 xattr 承载的，所以 `-X` 一加它们就不会产生。
#
# ⭐ 验收铁律：打包完必须**解压到干净目录重新验签**。
# 1.0.2 的验收就是这样漏掉的 —— 我在解压后没有重新 codesign，
# 直接沿用了"打包前签名有效"的印象，于是坏包发了出去。
# 「打包前有效」和「用户拿到手有效」是两件事，必须分开验。

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$PROJECT_DIR/output/CodexO.app"

if [ ! -d "$APP" ]; then
  echo "找不到 $APP，请先跑 bash build.sh"
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
OUT_DIR="${1:-/tmp/codexo_pkg_$VERSION}"
ZIP="$OUT_DIR/CodexO-$VERSION.zip"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# 先清源 App 里的残留（.DS_Store / ._*）。正常情况下一个都没有，
# 但如果有人在 Finder 里打开过这个目录，就可能混进来。
find "$APP" -name '.DS_Store' -delete 2>/dev/null || true
find "$APP" -name '._*' -delete 2>/dev/null || true

# 打包前验一次签
echo "==> 打包前验签"
codesign --verify --deep --strict "$APP"

# ⭐ 关键：-X 不写扩展属性，-r 递归，-9 最高压缩
#    绝不能换回 ditto -c -k（理由见文件头）
( cd "$PROJECT_DIR/output" && zip -q -r -X -9 "$ZIP" "CodexO.app" )

echo "==> 打包完成：$ZIP"
ls -la "$ZIP"

# 查一下有没有混进 AppleDouble 文件（应当输出 0）
BAD="$(unzip -l "$ZIP" | grep -c '\._\|__MACOSX' || true)"
echo "    AppleDouble 文件数：$BAD"
if [ "$BAD" != "0" ]; then
  echo "    ❌ 包里混进了 AppleDouble 文件，签名会失效。检查打包命令是否用了 -X"
  exit 1
fi

# ⭐ 验收：解压到干净目录，验签、验版本、再实跑一次。
#    只在打包前验签是不够的 —— 必须验「用户真正拿到的那份」。
VERIFY_DIR="$(mktemp -d /tmp/codexo_verify.XXXXXX)"
echo "==> 解压到干净目录验收：$VERIFY_DIR"
unzip -q "$ZIP" -d "$VERIFY_DIR"
VAPP="$VERIFY_DIR/CodexO.app"

echo "    解压后 ._ 文件数：$(find "$VAPP" -name '._*' | wc -l | tr -d ' ')（应为 0）"

echo "==> 解压后验签"
codesign --verify --deep --strict "$VAPP"
echo "    签名有效 ✅"

V="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$VAPP/Contents/Info.plist")"
B="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$VAPP/Contents/Info.plist")"
echo "    解压后版本：$V (build $B)"
if [ "$V" != "$VERSION" ]; then
  echo "    ❌ 解压后版本与打包前不一致：$V ≠ $VERSION"
  exit 1
fi

echo "==> 实跑解压出来的这一份（验完立刻收尾，不留孤儿进程）"
#
# ⚠️ 不能直接跑 $VAPP，也不能按 "CodexUsageMenuBar" 泛名 pgrep/pkill。
#
# 这个 App 要求单实例，锁文件在 $TMPDIR 下用户级共享。
# 直接跑解压出来的那一份时：
#   · 如果用户正开着 CodexO，它抢不到锁，立刻退出 → 被误判成「起来了但立刻退出」
#   · pgrep 泛名会把用户那个进程一起数进去 → 进程数 2 → 被误判成单实例失效
#   · 收尾 pkill -9 泛名会**把用户正在用的 App 一起杀掉**
#
# 而且这些都是「反复启停同一个 bundle id」，正是状态栏图标消失的诱因。
# 所以这里复制一份、换时间戳 id、换独立锁，只操作自己这一份。
RUN_APP="$VERIFY_DIR/CodexO-RunTest.app"
ditto "$VAPP" "$RUN_APP"
/usr/bin/plutil -replace CFBundleIdentifier \
  -string "com.bean.codexo.pkgtest$(date +%s)" \
  "$RUN_APP/Contents/Info.plist"
RUN_LOCK="${TMPDIR:-/tmp}/CodexO.singleton.pkgtest-$$.lock"
rm -f "$RUN_LOCK" 2>/dev/null || true
echo "    实跑对象：临时副本（独立 id + 独立锁），不影响正在运行的 CodexO"

# 用 setsid 式脱离 + 关掉 job control 提示：
# 单纯 `cmd &` 在脚本被 kill 时会打印 "Terminated: 15" 噪音，
# 那只是 shell 在报作业被杀，不是错误 —— 但验收日志里出现这种行会误导人。
set +m
CODEXO_LOCK_PATH="$RUN_LOCK" "$RUN_APP/Contents/MacOS/CodexUsageMenuBar" >/dev/null 2>&1 &
TEST_PID=$!
disown 2>/dev/null || true
set -m
sleep 4
if kill -0 "$TEST_PID" 2>/dev/null; then
  echo "    起来了 ✅ pid=$TEST_PID"
  RUNNING="$(pgrep -f "CodexO-RunTest.app" | wc -l | tr -d ' ')"
  echo "    当前 CodexO 进程数：$RUNNING"
  if [ "$RUNNING" != "1" ]; then
    echo "    ❌ 进程数不为 1，单实例保护可能有问题"
    kill -9 "$TEST_PID" 2>/dev/null || true
    sleep 1
    rm -rf "$VERIFY_DIR"
    exit 1
  fi
else
  echo "    ❌ 起来了但立刻退出"
  rm -rf "$VERIFY_DIR"
  exit 1
fi

# 收尾铁律：先杀进程、确认干净，**然后**才删目录。
# 顺序反了就会留下孤儿进程 —— 菜单栏于是出现两个图标（本项目踩过两次）。
#
# 全程只按副本路径匹配，绝不使用 "CodexUsageMenuBar" 这种泛名：
# 用户自己的 CodexO 进程名是一样的，泛杀就会把人家正在用的图标搞没了。
kill "$TEST_PID" 2>/dev/null || true
sleep 2
if kill -0 "$TEST_PID" 2>/dev/null; then
  kill -9 "$TEST_PID" 2>/dev/null || true
  sleep 1
fi
REMAIN="$(pgrep -f "CodexO-RunTest.app" 2>/dev/null | wc -l | tr -d ' ')"
echo "    收尾后残留测试进程：$REMAIN"
rm -f "$RUN_LOCK" 2>/dev/null || true

if [ "$REMAIN" != "0" ]; then
  pkill -9 -f "CodexO-RunTest.app" 2>/dev/null || true
  sleep 1
  echo "    已强制清理"
fi
rm -rf "$VERIFY_DIR"

echo "==> 打包 + 验收全部通过：$ZIP"