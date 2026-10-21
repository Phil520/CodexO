#!/bin/bash
# GitHub 用户名改完后，跑这个把本地各处同步到新名字。
#
# 背景（2026-10-19）：用户名从 Phil520 改为 Rff-Phil，显示名一并从 huihui 改为 Rff-Phil。
# 改名是用户在浏览器里自己点的（Settings → Account → Change username）——
# 命令行改不了，因为改用户名的授权要打 github.com/device/code，
# 而这台机器的代理只放行 api.github.com，github.com 本体不通。
#
# 用法：bash tools/sync_github_username.sh Rff-Phil
#
# 为什么值得写个脚本：
# GitHub 官方保证改名后网页链接会自动重定向、本地 push 也会继续可用，
# 但**本地 git remote 里的旧地址不会自己变**，也不会提醒你。
# 下次 clone 别的分支、或者换机器重新拉取时，才会发现地址不对。

set -euo pipefail

NEW="${1:-}"
OLD="Phil520"

if [ -z "$NEW" ]; then
  echo "用法：bash tools/sync_github_username.sh <新用户名>"
  echo "示例：bash tools/sync_github_username.sh Rff-Phil"
  exit 1
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> 1. 先确认 GitHub 上确实改好了"
# 旧名字查得到 = 没改成；新名字查不到 = 还没生效。
# GitHub 官方说重定向生效要几分钟，刚改完可能还查得到，属正常。
if gh api "users/$NEW" >/dev/null 2>&1; then
  echo "    ✅ $NEW 已存在"
  NEW_OK="yes"
else
  echo "    ⚠️ 查不到 ${NEW}（可能刚改完、重定向还没生效，也可能是拼错了）"
  NEW_OK="no"
fi
if gh api "users/$OLD" >/dev/null 2>&1; then
  echo "    ⚠️ 旧名字 $OLD 仍能查到 —— 改名可能还没生效，先去浏览器确认"
  OLD_OK="yes"
else
  echo "    ✅ 旧名字 $OLD 已不可用"
  OLD_OK="no"
fi

echo
echo "==> 2. 更新本地 git remote"
cd "$PROJECT_DIR"
if git remote get-url origin >/dev/null 2>&1; then
  OLD_URL="$(git remote get-url origin)"
  NEW_URL="${OLD_URL/$OLD/$NEW}"
  if [ "$OLD_URL" = "$NEW_URL" ]; then
    echo "    remote 里没有 $OLD，无需改动（当前：$OLD_URL）"
  else
    git remote set-url origin "$NEW_URL"
    echo "    $OLD_URL"
    echo "  → $NEW_URL"
  fi
else
  echo "    没有 origin remote，跳过"
fi

echo
echo "==> 3. 扫一遍项目里还有没有写死旧用户名的地方"
LEFT="$(grep -rn "$OLD" . --include="*.md" --include="*.sh" --include="*.swift" \
        --include="*.plist" 2>/dev/null | grep -v "^\./\.git/" | wc -l | tr -d ' ')"
if [ "$LEFT" = "0" ]; then
  echo "    ✅ 0 处"
else
  echo "    找到 $LEFT 处，逐条列出（历史记录可以不动，脚本与文档里的要改）："
  grep -rn "$OLD" . --include="*.md" --include="*.sh" --include="*.swift" \
       --include="*.plist" 2>/dev/null | grep -v "^\./\.git/" | head -20
fi

echo
echo "==> 4. 验证 remote 可用"
git remote -v
echo "    测试连通性（只读，不改任何东西）…"
if git ls-remote origin >/dev/null 2>&1; then
  echo "    ✅ remote 可访问"
else
  echo "    ⚠️ remote 访问失败。GitHub 官方说明改名后重定向生效需要几分钟，"
  echo "       等一会儿再试；如果一直失败，检查是不是代理把 git 协议也挡了"
  echo "       （这台机器目前 api.github.com 通、github.com 不通）"
fi

echo
echo "==> 5. 汇总"
echo "    新用户名：$NEW"
echo "    显示名  ：Rff-Phil"
echo "    仓库地址：https://github.com/$NEW/CodexO"
echo "    Release ：https://github.com/$NEW/CodexO/releases"
if [ "$NEW_OK" = "yes" ]; then
  echo
  echo "    改名已生效。**旧用户名 Phil520 会被永久保留、他人无法注册**，"
  echo "    所以旧链接不会被别人抢走，指向的都是你的仓库。"
fi