#!/bin/sh
# AI code review 安裝（mac／Linux）：每台電腦跑一次，之後 push 時都會在背景審查分支的改動。
# 用法：sh install.sh
#       sh install.sh --engine codex       指定用 codex（預設自動偵測，claude 優先）
#       sh install.sh --trigger manual     push 不自動審，要審時執行 git ai-review
#       sh install.sh --webhook <網址>     指定 n8n webhook（沒指定就只把報告存在本機）
#       sh install.sh --remote-pattern <樣式>  只審 origin 網址符合的 repo，例如 "*git.example.com*"（預設全部）
#       sh install.sh --uninstall          移除
# 需求：Git 2.54 以上（設定式 hook）、claude 或 codex 已用訂閱登入。

engine=
trigger=push
webhook=
remote=
uninstall=
dir=$HOME/.ai-review
here=$(cd "$(dirname "$0")" && pwd)

fail() { echo "安裝失敗：$1" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case $1 in
    --engine) engine=$2; shift ;;
    --trigger) trigger=$2; shift ;;
    --webhook) webhook=$2; shift ;;
    --remote-pattern) remote=$2; shift ;;
    --uninstall) uninstall=1 ;;
    *) fail "不認得的參數：$1" ;;
  esac
  shift
done
case $engine in ''|claude|codex) ;; *) fail '--engine 只能是 claude 或 codex' ;; esac
case $trigger in push|manual) ;; *) fail '--trigger 只能是 push 或 manual' ;; esac

if [ -n "$uninstall" ]; then
  git config --global --remove-section hook.ai-review 2>/dev/null
  git config --global --remove-section ai-review 2>/dev/null
  git config --global --unset alias.ai-review
  echo "已移除 git 設定。審查紀錄還留在 $dir，不需要可以手動刪除。"
  exit 0
fi

# 1. Git 版本：macOS 內建的 Apple Git 太舊，要用 Homebrew 的
command -v git >/dev/null || fail '找不到 git，請先安裝 Homebrew，再執行 brew install git'
gitver() { git --version | awk '{ split($3, v, "."); print v[1] * 10000 + v[2] * 100 + v[3] }'; }
if [ "$(gitver)" -lt 25400 ]; then
  echo "$(git --version) 太舊，嘗試用 Homebrew 升級…"
  command -v brew >/dev/null && brew install git
  hash -r
  [ "$(gitver)" -ge 25400 ] || fail "Git 需要 2.54 以上，目前用的是 $(command -v git)。用 Homebrew 裝好 git 後，確認 which git 指到 Homebrew 的路徑（例如 /opt/homebrew/bin/git），再重跑"
fi

# 2. 審查引擎（訂閱登入）
claude_ok() { command -v claude >/dev/null && claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; }
codex_ok() { command -v codex >/dev/null && codex login status 2>&1 | grep -q 'Logged in'; }
case $engine in
  '') if claude_ok; then engine=claude; elif codex_ok; then engine=codex
      else fail 'claude 和 codex 都沒有登入，請先執行 claude（登入訂閱帳號）或 codex login'; fi ;;
  claude) claude_ok || fail 'claude 沒有登入，請先執行 claude 登入訂閱帳號' ;;
  codex) codex_ok || fail 'codex 沒有登入，請先執行 codex login' ;;
esac

# 3. 複製腳本與 skill 備份（review.sh 優先用 ~/.claude/skills 或 ~/.codex/skills 裡的 ai-code-review，找不到才用這份）
mkdir -p "$dir"
cp "$here/review.sh" "$dir/review.sh" || fail "複製 review.sh 失敗"
cp "$here/skills/ai-code-review/SKILL.md" "$dir/SKILL.md" || fail "複製 SKILL.md 失敗"

# 4. git 全域設定：push 前的 hook，加上手動審查用的 git ai-review
script="sh \"$dir/review.sh\""
git config --global hook.ai-review.command "$script"
git config --global --replace-all hook.ai-review.event pre-push
git config --global alias.ai-review "!$script --now"
git config --global ai-review.trigger "$trigger"
git config --global ai-review.engine "$engine"
if [ -n "$webhook" ]; then git config --global ai-review.webhook "$webhook"; else git config --global --unset ai-review.webhook; fi
git config --global ai-review.remotePattern "${remote:-*}"
# 從 Fork、SourceTree 這類圖形介面工具 push 時，PATH 只有系統預設的幾個資料夾，找不到 claude、codex，所以記下現在的 PATH
git config --global ai-review.path "$PATH"

echo
echo "安裝完成：引擎 $engine，觸發方式 $trigger，審查的 repo：${remote:-全部}，webhook：${webhook:-未設定（報告只存在本機）}"
if [ "$trigger" = push ]; then
  echo '之後 push 時，會在背景審查這個分支的改動；只改文件、圖片時自動跳過。'
  echo '單次跳過：最新的 commit 訊息寫 skip'
else
  echo 'push 不會自動審查；要審時在專案資料夾執行：git ai-review'
fi
echo '改觸發方式：git config --global ai-review.trigger push 或 manual'
echo "紀錄在 $dir/review.log"
echo
echo "注意：用 Fork、SourceTree 這類圖形介面工具 push 時，要在工具設定裡改用 $(command -v git)，工具內建的 git 太舊時不會觸發審查。"
