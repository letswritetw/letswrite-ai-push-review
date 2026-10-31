# ai-push-review

`git push` 時，在背景用你自己訂閱的 Claude Code 或 Codex CLI 審查這個分支的改動，把結果留在自架 Gitea 的 PR 或 issue，並發 Telegram 通知。

- 不用另外申請 API key，用個人訂閱的 `claude` 或 `codex` 指令跑審查
- 每台電腦裝一次，之後所有 repo 都適用，不用動各 repo 的 `.git/hooks`
- 審查重點寫在一個 skill 檔（`SKILL.md`），可以自己改
- 能對照專案的業務規則文件，抓「改了 A 功能，B 功能壞掉」
- 報告是 PR-Agent 風格的表格，每條建議點開才看到細節和修改方式

## 審完之後會發生什麼

- **沒問題，或只有小問題**：Telegram 收到一則「✅ 審查通過」，報告只存在你的電腦，Gitea 不會多任何東西。
- **有中高風險的問題**：結果留在這個分支開著的 PR 上；沒有 PR 就開一張新 issue 指派給你，每次 push 各開一張。同時 Telegram 收到通知。
- **沒設定 n8n**：報告只存在你的電腦（`~/.ai-review/reviews/`），可以先這樣試用。

運作流程：

```
git push
 └ pre-push（git 全域 hook 設定，不動各 repo 的 .git/hooks）
    └ ~/.ai-review/review.sh 背景執行
       ├ 只審 origin 網址符合 remotePattern 的 repo
       ├ 範圍：一般分支審「這個分支自己新增的 commit」，跟 PR 會列出的一樣，已經在其他遠端分支上的不算
       │   預設分支（origin/HEAD 指的那個，例如 main），或遠端只有這一個分支時，只審這次 push 新增的 commit
       │   merge commit 都不算
       ├ claude -p 或 codex exec（都是唯讀），照 skills/ai-code-review/SKILL.md 輸出報告
       │   └ repo 有 docs/ai-rules/ 時，對照業務規則檢查有沒有改 A 壞 B
       └ 報告存在 ~/.ai-review/reviews/，並送到 n8n webhook
n8n（n8n/ai-review.json）
 ├ 報告開頭的 SEVERITY 是 none / low：只發「✅ 審查通過」通知
 └ medium / high / 無法判讀：
    ├ 分支有開著的 PR → 留 PR review（high 用「要求修改」，medium 用一般留言）
    ├ 沒有 PR → 開新 issue，指派給 push 的人（用 git 的 email 找 Gitea 帳號；找不到就不指派）
    ├ 依嚴重度和分類貼 label
    └ 發 Telegram 通知，附上 PR 或 issue 連結
```

## 檔案

| 檔案                             | 用途                                                                     |
| -------------------------------- | ------------------------------------------------------------------------ |
| `review.sh`                      | 主程式，POSIX sh，Windows 透過 Git for Windows 內附的 sh 執行            |
| `install.cmd`、`install.ps1`     | Windows 安裝檔                                                           |
| `install.sh`                     | mac 安裝檔                                                               |
| `skills/ai-code-review/SKILL.md` | 審查規則與報告格式，也能當 Claude Code 的 `/ai-code-review` skill 手動用 |
| `n8n/ai-review.json`             | n8n workflow，匯入後使用                                                 |

## 需求

- **Git 2.54 以上**：要用 2.54 才有的「設定式 hook」（寫在 git 全域設定裡的 hook）。
  - Windows：安裝檔會試著用 winget 升級。
  - mac：內建的 Apple Git 太舊，要用 Homebrew 裝的 git，安裝檔會試著執行 `brew install git`。
- **Claude Code 或 Codex CLI**：已經用訂閱帳號登入（`claude` 登入，或 `codex login`）。
- **選用**：自架 Gitea、n8n、Telegram bot。沒有的話，報告只存在本機。

## 安裝（每台電腦一次）

1. 下載這個 repo。
2. 執行安裝檔：
   - Windows：雙擊 `install.cmd`。
   - mac：在終端機執行 `sh install.sh`。
3. 指定 webhook 和要審的 repo（建議）：

   ```
   install.cmd -Webhook https://n8n.example.com/webhook/ai-review -RemotePattern "*git.example.com*"
   ```

   ```
   sh install.sh --webhook https://n8n.example.com/webhook/ai-review --remote-pattern "*git.example.com*"
   ```

   `RemotePattern` 是 shell 萬用字元樣式，對 `git remote get-url origin` 比對。沒指定時每個 repo 都審，連 GitHub 上的個人專案也會用掉訂閱額度。

4. 如果 git 用的 email 跟 Gitea 帳號的 email 不同，或 Gitea 隱藏了 email，issue 會對不到人。這時要設定自己的 Gitea 帳號：

   ```
   git config --global ai-review.giteaUser <Gitea 帳號>
   ```

安裝選項：

| 想要                   | Windows                             | mac                                     |
| ---------------------- | ----------------------------------- | --------------------------------------- |
| 指定用 codex           | `install.cmd -Engine codex`         | `sh install.sh --engine codex`          |
| 改成手動模式           | `install.cmd -Trigger manual`       | `sh install.sh --trigger manual`        |
| 指定 n8n webhook       | `install.cmd -Webhook <網址>`       | `sh install.sh --webhook <網址>`        |
| 只審特定 Gitea 的 repo | `install.cmd -RemotePattern <樣式>` | `sh install.sh --remote-pattern <樣式>` |
| 移除                   | `install.cmd -Uninstall`            | `sh install.sh --uninstall`             |

想在 Claude Code 裡手動用 `/ai-code-review`，把 `skills/ai-code-review` 整個資料夾複製到 `~/.claude/skills/`。自動審查會優先用那一份，所以改審查規則時改那裡就好。

## 什麼時候審

| 方式                     | 怎麼用                                                                                                 |
| ------------------------ | ------------------------------------------------------------------------------------------------------ |
| 每次 push 自動審（預設） | 直接 `git push`                                                                                        |
| 這次不要審               | 最新的 commit 訊息寫 `skip`，例如「改錯字 skip」。要單獨一個字、不分大小寫，`skipped` 不算             |
| 改成手動                 | `git config --global ai-review.trigger manual`，之後 push 不審，要審時在專案資料夾執行 `git ai-review` |
| 改回自動                 | `git config --global ai-review.trigger push`                                                           |
| 某個專案都不審           | 在該 repo 執行 `git config hook.ai-review.enabled false`                                               |

下面這些情況會自動跳過：

- 分支只改了文件、圖片這類非程式檔
- push 的是 tag，或是刪除遠端分支
- 改動超過 3000 行（`git config ai-review.maxLines <行數>` 可以調整）

其他：

- `git ai-review` 在自動模式下也能用，可以在 push 前先審一次。
- 執行紀錄在 `~/.ai-review/review.log`（Windows 是 `%USERPROFILE%\.ai-review\review.log`），每份報告存在同一層的 `reviews` 資料夾。
- 每次審查都會用掉個人訂閱的使用額度，一般分支每 push 一次就整個分支重審一次。

## 審查重點

規則寫在 `skills/ai-code-review/SKILL.md`，可以依團隊需要改：

- **看最後結果**：審的是整個分支。前面 commit 寫錯、後面 commit 已經修好的，不會報。
- **只報有證據的問題**：每一條都附檔案位置和程式碼，沒辦法證實的標「待確認」。
- **業務規則（改 A 壞 B）**：見下一節。
- **前後端檢查清單**：依 OWASP Top 10:2025、CWE Top 25 (2025)、OWASP ASVS 5.0 整理，報告每一條會標出依據的編號。清單偏向 C#／.NET、SQL、JavaScript／Vue，其他技術可以自己補。
- **不跟靜態掃描重複**：排版、命名這類 SonarQube、ESLint 抓得到的不報，重點放在業務邏輯、權限判斷、跨功能影響。
- **專案特有的重點**：寫在該 repo 根目錄的 `.ai-review.md`，審查時會一起讀。

### 業務規則文件（選用）

在 repo 放 `docs/ai-rules/*.md`，把重要的業務邏輯寫成 AI 讀得懂的規則。審查時會從改到的檔案、函式和它們的呼叫端，找出受影響的規則，逐條確認還成立。一個檔案寫一個功能，例如 `docs/ai-rules/訂單退款.md`：

```markdown
---
files: [src/Handlers/Refund.ashx, src/Services/OrderService.cs]
keywords: [退款, Refund, CancelOrder]
---

## ORDER-02 已出貨的訂單不能直接退款

- when：訂單狀態是「已出貨」時呼叫退款
- then：回傳錯誤，要先走退貨流程
- code：src/Services/OrderService.cs `CanRefund()`
- evidence：`if (order.Status == OrderStatus.Shipped) return false;`
- status: verified
- verified_at: 2026-10-01
```

- `status: verified` 的規則才會當成依據；`inferred`、`unverified` 只當線索。
- `verified_at` 之後，`files` 裡的檔案有其他異動時，規則可能過時，也只當線索。
- 改動是刻意改業務邏輯時，報告會列一條「規則檔需要更新」，不當成錯誤。

## 管理者：n8n 與 Gitea 設定一次

1. Gitea 建 bot 帳號（例如 `ai-reviewer`），給它各 repo 的寫入權限。產生 access token，權限勾 `write:issue`、`write:repository`（留 PR review 要用）、`read:user`（用 email 找人要用）。
2. n8n 匯入 `n8n/ai-review.json`。
3. 在 n8n 建 **Bearer Auth** 憑證，名稱取 `Gitea ai-review bot`，Token 填 bot 的 access token（只填 token 本身，前面不用加 `Bearer`）。匯入的 workflow 裡，5 個 Gitea 節點（`Find PR`、`Find author`、`Post to Gitea`、`Post to Gitea (fallback)`、`Add labels`）都預設用這個憑證。
4. Gitea 網址預設從 remote 網址推算，remote 要是 http 或 https。用 SSH remote 時，要在 `Parse` 節點最上面的 `GITEA` 填 Gitea 網址。
5. 設定 Telegram：
   - 在 Telegram 找 [@BotFather](https://t.me/BotFather)，執行 `/newbot` 建一個 bot，記下它給的 token。
   - 把 bot 加進要收通知的群組，在群組裡傳一則 `/start`。
   - 用瀏覽器開 `https://api.telegram.org/bot<token>/getUpdates`，找到 `"chat":{"id":-100…}`，這個數字（群組是負數）就是 chat id。
   - 編輯 `Telegram` 節點：網址裡的 `BOT_TOKEN` 換成 token，內容裡的 `CHAT_ID` 換成 chat id。

   審查通過和要處理的通知都從這個節點發出，訊息內容在 `Notify` 節點組成；要改發到其他聊天工具，改這兩個節點就好。不想收到審查通過的通知，刪掉 `Passed?` 節點 true 輸出的那條連線。

6. 啟用 workflow（Active），把 Webhook 節點顯示的 Production URL 給開發者安裝時用。

### Label

| 情況                           | 貼的 label                         |
| ------------------------------ | ---------------------------------- |
| 每一則 AI 審查（PR 或 issue）  | `ai-review`、`bug`、`Kind/Bug`     |
| 有 medium 以上的資安問題       | `Kind/Security`                    |
| 有 medium 以上的業務規則被破壞 | `Compat/Breaking`                  |
| 嚴重度 high／medium            | `Priority/High`／`Priority/Medium` |

除了 `ai-review`，其他都是 Gitea 內建 label 範本（Default、Advanced）裡的名稱。repo 和組織都沒有的 label，Gitea 會略過，不會出錯。要調整就改 `Parse` 節點最上面的 `LABELS`。

### 常見錯誤

| 出錯的節點                | 錯誤訊息                          | 處理                                                                                           |
| ------------------------- | --------------------------------- | ---------------------------------------------------------------------------------------------- |
| `Telegram`                | `401 Unauthorized`                | 網址裡的 bot token 貼錯                                                                        |
| `Telegram`                | `400 Bad Request: chat not found` | chat id 錯了，或 bot 不在這個群組                                                              |
| `Telegram`                | `429`                             | Telegram 限制 bot 在同一個群組每分鐘最多發 20 則，很多人同時 push 時可能遇到。偶爾發生可以不管 |
| `Find …`、`Post to Gitea` | `Credentials not found`、`401`    | 「Gitea ai-review bot」憑證沒建，或節點沒選到它                                                |
| `Post to Gitea`           | `403`、`404`                      | token 權限不夠，或 bot 帳號沒有該 repo 的寫入權限                                              |
| `Parse`                   | `remote 不是 http(s) 網址`        | 用的是 SSH remote，見上面第 4 步                                                               |

## 用圖形介面工具 push

很多圖形介面工具自帶舊版 git。**用它們 push 時不會審查，而且沒有任何錯誤訊息或紀錄**，很容易以為有在審。實際執行 push 的那個 git 要 2.54 以上才會觸發。Windows 安裝完成時會列出要調整的工具。

| 工具            | 內建 Git（2026-10 在 Windows 查到的版本） | 怎麼處理                                                                                                                          |
| --------------- | ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| 命令列、VS Code | 用系統 Git                                | 不用處理                                                                                                                          |
| Visual Studio   | 用 VS 內建的 Git，沒有改用系統 Git 的選項 | 內建版本太舊就用 Visual Studio Installer 更新 VS（VS 2019 16.11.60 內建 2.55.0，已經可以用）                                      |
| Fork            | 2.50.1                                    | Preferences → Git → Git Instance 改指定系統 Git 的 `bin\git.exe`。不要選 `cmd\git.exe`，Fork 會因為同一層找不到 `bash.exe` 而報錯 |
| SourceTree      | 2.51.0                                    | Tools → Options → Git → Git Version 選 System                                                                                     |
| GitHub Desktop  | 2.53.0                                    | 不能換 git，改用上面其他工具 push                                                                                                 |

系統 Git 的位置：Windows 用 `where git` 查；mac 用 `which git` 查，通常是 `/opt/homebrew/bin/git`。

mac 從圖形介面工具 push 時，系統不會帶入終端機的 PATH，會找不到 `claude`、`codex`。`install.sh` 會把安裝當下的 PATH 記在 `ai-review.path`，審查時補回去。之後 claude 或 codex 換了安裝位置，重跑一次 `install.sh`。

## 限制

- 只在 Windows 10 + Git for Windows 實際用過。mac 的 `install.sh` 只在 Git Bash 模擬測試過，還沒在真的 Mac 上跑過。
- 報告裡的檔案連結和 n8n 都是照 Gitea 的網址格式做的，GitHub、GitLab 要自己改 workflow。
- 報告格式和審查規則是繁體中文。
- 用個人訂閱跑自動化審查，請自行確認 Claude、Codex 的使用條款和額度。

## 解除安裝

1. 執行 `install.cmd -Uninstall`（mac 是 `sh install.sh --uninstall`）。這會移除 git 全域設定裡的 `hook.ai-review.*`、`ai-review.*` 和 `git ai-review` 指令，之後 push 就不會再審查。
2. 刪除 `~/.ai-review` 資料夾（Windows 是 `%USERPROFILE%\.ai-review`）。裡面是腳本、執行紀錄和每次的審查報告。
3. 有把 skill 複製到 `~/.claude/skills/ai-code-review` 的話，一起刪掉。

只是暫時不想自動審查，改成手動模式就好：`git config --global ai-review.trigger manual`。

## 授權

MIT，見 [LICENSE](LICENSE)。
