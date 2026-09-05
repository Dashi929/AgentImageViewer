#!/usr/bin/env bash
# 非交互推送：绕过 GCM UI（用户全屏应用时凭据弹窗会卡住工作流）
# 用法: bash tool/push.sh [branch]
set -e
cd "$(dirname "$0")/.."
BRANCH="${1:-main}"
TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | git credential fill 2>/dev/null | grep ^password= | cut -d= -f2-)
if [ -z "$TOKEN" ]; then
  echo "no token" >&2
  exit 1
fi
GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=echo git -c credential.helper= push "https://x-access-token:${TOKEN}@github.com/Dashi929/AgentImageViewer.git" "$BRANCH" --tags --follow-tags
