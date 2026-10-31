#!/bin/sh
# AI code review：git push 前觸發（pre-push），在背景用 claude / codex（個人訂閱）審查這個分支的改動，結果送 n8n。
# n8n 會把結果留在這個分支開著的 PR；沒有 PR 就開新 issue，每次 push 各開一張。
# 由 install.ps1（Windows）或 install.sh（mac）複製到 ~/.ai-review/，透過 git 全域 hook 設定（hook.ai-review.*）呼叫，所有 repo 共用。
#
# 什麼時候審：
#   ai-review.trigger=push（預設）  每次 push 自動審；只改文件、圖片這類非程式檔時自動跳過
#   ai-review.trigger=manual        push 不審，要審時執行 git ai-review（審目前分支）
#   單次跳過：最新的 commit 訊息寫 skip（單獨一個字，不分大小寫；skipped 不算）
#   單一 repo 關閉：git config hook.ai-review.enabled false
#
# 其他設定（git config，可在單一 repo 覆寫）：
#   ai-review.engine         claude（預設）| codex
#   ai-review.webhook        n8n webhook 網址；沒設就只存本機
#   ai-review.remotePattern  只審 origin 網址符合這個 shell 樣式的 repo，例如 *git.example.com*；沒設就全部都審
#   ai-review.maxLines       改動超過這麼多行就跳過，預設 3000
#   ai-review.skillFile      指定 SKILL.md 路徑（預設找 ~/.claude/skills、~/.codex/skills 底下的 ai-code-review，都沒有就用安裝時複製的那份）
#   ai-review.giteaUser      issue 要指派給的 Gitea 帳號；沒設就用 push 者的 git email 找
#   ai-review.path           mac 安裝時記下的 PATH，從圖形介面工具 push 時才找得到 claude、codex

here=${0%/*}   # 安裝檔用絕對路徑呼叫；不用 $(dirname) 少一次 fork（Windows 上一次約 0.1～0.3 秒）

# ---- 手動：git ai-review（alias）審目前分支 ----
if [ "$1" = --now ]; then
  AI_REVIEW_BG=1 nohup sh "$0" "$(git rev-parse --abbrev-ref HEAD)" "$(git rev-parse HEAD)" >>"$here/review.log" 2>&1 </dev/null &
  echo "已在背景審查目前分支，進度看 $here/review.log"
  exit 0
fi

# ---- 前景（pre-push）：讀 git 傳來的 push 清單，每個要 push 的分支各開一個背景審查，push 不用等 ----
if [ "$AI_REVIEW_BG" != 1 ]; then
  if [ -n "$AI_REVIEW_SKIP" ] || [ "$(git config ai-review.trigger)" = manual ]; then cat >/dev/null; exit 0; fi
  while read -r lref lsha rref rsha; do
    case "$rref" in refs/heads/*) ;; *) continue ;; esac   # 只審分支，不審 tag
    case "$lsha" in *[!0]*) ;; *) continue ;; esac         # 全 0 代表刪除遠端分支
    AI_REVIEW_BG=1 nohup sh "$0" "${rref#refs/heads/}" "$lsha" "$rsha" >>"$here/review.log" 2>&1 </dev/null &
  done
  exit 0
fi

# ---- 背景：判斷要不要審，審查並送出 ----
branch=$1
sha=$2
old=${3-$(git rev-parse -q --verify "refs/remotes/origin/$branch")}   # 遠端原本的位置；全 0 是遠端還沒有這個分支，手動審時用本機記錄的遠端位置
p=$(git config ai-review.path) && PATH=$p:$PATH
pattern=$(git config ai-review.remotePattern || echo '*')
case "$(git remote get-url origin 2>/dev/null)" in $pattern) ;; *) exit 0 ;; esac
git log -1 --format=%B "$sha" | grep -qiw skip && exit 0

# 這個分支上、還不在其他遠端分支的 commit，就是這個分支自己的改動，也就是 PR 會包含的內容
others=$(git for-each-ref --format='%(refname)' refs/remotes/origin/ | grep -vxF -e "refs/remotes/origin/$branch" -e refs/remotes/origin/HEAD)
# 預設分支不會開 PR，沒有其他遠端分支可以比時也一樣：改成只審這次 push 新增的 commit；遠端還沒有這個分支（第一次 push）才審全部
if [ -z "$others" ] || [ "$(git symbolic-ref -q --short refs/remotes/origin/HEAD)" = "origin/$branch" ]; then
  case "$old" in *[!0]*) others=$old ;; *) others= ;; esac
fi
list=$(git log --no-merges --format='%h %s' "$sha" --not $others)
[ -n "$list" ] || exit 0
n=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
oldest=$(git rev-list --no-merges "$sha" --not $others | tail -1)
base=$(git rev-parse -q --verify "$oldest^") || base=$(git hash-object -t tree /dev/null)   # 根 commit 就跟空樹比

engine=$(git config ai-review.engine || echo claude)
short=$(git rev-parse --short "$sha")
repo=$(basename "$(git rev-parse --show-toplevel)")
name="$repo $branch $short"
# 只改文件、圖片這類非程式檔時不審
git diff --name-only "$base" "$sha" \
  | grep -qiE '\.(cs|vb|js|mjs|cjs|ts|tsx|jsx|vue|sql|aspx|ascx|ashx|asmx|master|cshtml|razor|html?|css|scss|py|java|kt|go|php|rb|config|json|xml|ya?ml|ps1|sh)$' \
  || { echo "$(date '+%F %T') $name 沒有改到程式檔，略過"; exit 0; }
lines=$(git log --no-merges --numstat --format= "$sha" --not $others | awk '{s+=$1+$2} END {print s+0}')
max=$(git config ai-review.maxLines || echo 3000)
[ "$lines" -gt "$max" ] && { echo "$(date '+%F %T') $name 改動 $lines 行，超過上限 $max，略過"; exit 0; }

skill=$(git config ai-review.skillFile)
if [ ! -f "$skill" ]; then
  for f in "$HOME"/.claude/skills/*ai-code-review/SKILL.md "$HOME"/.codex/skills/*ai-code-review/SKILL.md "$here/SKILL.md"; do
    [ -f "$f" ] && { skill=$f; break; }
  done
fi
[ -f "$skill" ] || { echo "$(date '+%F %T') $name 找不到 ai-code-review SKILL.md，略過"; exit 1; }

mkdir -p "$here/reviews"
out="$here/reviews/$repo-$(printf '%s' "$branch" | tr '/\\:*?"<>| ' '__________')-$short.md"   # ponytail: 不自動清，量大再加保留天數
echo "$(date '+%F %T') $name 開始審查（$engine，$n 個 commit）"
{
  echo "依照下面的 ai-code-review skill，審查分支 $branch 的改動：範圍 $base..$sha，共 $n 個 commit（不含 merge commit）。只輸出審查報告本身。"
  # Gitea 看檔案的網址：<repo 網址>/src/commit/<sha>/<路徑>#L行號
  echo "檔案連結前綴：$(git remote get-url origin | sed 's#//[^@/]*@#//#; s#\.git$##')/src/commit/$sha"
  echo
  printf '%s\n' "$list"
  echo
  cat "$skill"
} >"$out.prompt"

# codex review --commit 不能帶自訂指示，所以用 codex exec 唯讀 sandbox 跑
case "$engine" in
  codex) codex exec -s read-only --ephemeral -o "$out" - <"$out.prompt" >/dev/null 2>"$out.err" ;;
  *) claude -p --permission-mode dontAsk \
       --allowedTools "Read,Grep,Glob,Bash(git show *),Bash(git diff *),Bash(git log *),Bash(codegraph explore *)" \
       <"$out.prompt" >"$out" 2>"$out.err" ;;
esac
status=$?
[ $status -eq 0 ] && [ -s "$out" ] || { echo "$(date '+%F %T') $name 審查失敗（exit $status）"; tail -5 "$out.err"; }
rm -f "$out.prompt" "$out.err"
[ $status -eq 0 ] && [ -s "$out" ] || exit 1

url=$(git config ai-review.webhook)
[ -n "$url" ] || { echo "$(date '+%F %T') $name 完成，未設定 webhook，結果在 $out"; exit 0; }

# Windows 的 curl 會把命令列參數轉成系統碼頁（Big5），中文分支名、作者、標題會變亂碼；
# 所以每個欄位先寫成檔案，再用 -F name=<file 送，內容保持原本的 UTF-8
meta="$out.meta"
mkdir -p "$meta"
put() { printf '%s' "$2" >"$meta/$1"; }
put remote "$(git remote get-url origin | sed 's#//[^@/]*@#//#')"   # 拿掉 remote 網址裡可能帶的帳密
put branch "$branch"
put sha "$sha"
put base "$base"
put commits "$list"
put author "$(git config user.name) <$(git config user.email)>"   # push 的人
put engine "$engine"
put giteaUser "$(git config ai-review.giteaUser)"   # 選填；沒設時 n8n 用 author 的 email 找 Gitea 帳號
set --
for k in remote branch sha base commits author engine giteaUser; do set -- "$@" -F "$k=<$meta/$k"; done
curl -fsS -m 30 "$@" -F "review=<$out" "$url" >/dev/null \
  && echo "$(date '+%F %T') $name 已送出" \
  || echo "$(date '+%F %T') $name 送出失敗，結果在 $out"
rm -rf "$meta"
