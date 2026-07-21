---
name: report-gcp
description: 一鍵無人值守產出 GCP 架構報告（scan → 五支柱並行 → 彙整 → HTML），中途不停、結束才回報
argument-hint: "[專案 ID] [期別，如 2026-07 或 2026-Q3；留空用當月]"
---

你現在要**以無人值守方式**跑完整條 GCP 架構報告流程。使用者已透過 `/report-gcp` 明確授權，
從現在起**一路跑到產出 HTML 報告為止，中途一律不得停下來問使用者或等待確認**——
唯一的例外是「階段 0 憑證檢查」失敗。全程結束後才回報一則摘要。

參數：`$ARGUMENTS`（第一個是專案 ID，第二個是期別；都可留空）

**一句話：期別只決定報告標題與存檔目錄，其餘一律是掃描當下的快照。**

- 期別＝一個**已結束的完整週期**，慣例在週期結束後才觸發：
  `2026-06` 月報＝6 月整月、`2026-Q2` 季報＝4–6 月、`2025` 年報＝整個 2025；
  **留空＝上一個完整月**（例：7/5 觸發即 6 月）。
- **資源盤點、安全性、可靠性、效能、維運一律為掃描當下的快照**（GCP 只給現況）。掃描日期用今天。
- **成本沒有期別可言**：GCP 沒有等同 Cost Explorer 的成本明細 API（需 BigQuery 帳單匯出），
  成本支柱靠「預算設定 ＋ Recommender 建議 ＋ 資源組態推算」，這些都是當下狀態。
  **實際帳單明細一律列為資料缺口**，不可捏造金額。

## 鐵則（本次執行全程適用）

- **全程對 GCP 專案唯讀**：只允許 `list` / `describe` / `get-iam-policy` 類指令，
  絕不執行任何變更專案狀態的指令。
- **直譯器只處理本機資料**：`python3` / `awk` / `sed` 等僅供處理 `data/` 本機檔案；
  **嚴禁透過任何直譯器、管線或子程序間接呼叫會變更 GCP 專案狀態的指令**。
- **中途不問人**：每階段之間不等待人工確認，直接接續下一階段；除階段 0 憑證失敗外不得中止詢問。
- 報告**預設不遮罩**（正式上線用途）；不自動發佈 Artifact，無人值守路徑到本機檔案為止。

## 階段 0 — 前置憑證檢查（唯一的快速失敗點）

跑 `gcloud auth list` 與 `gcloud config list`。

- **失敗（未安裝／未登入）**：**立刻停止整個流程**，不要派任何 agent、不要嘗試修復憑證。只回一句：
  「gcloud 未登入或未安裝，請先執行 `gcloud auth login` 並 `gcloud config set project <專案 ID>`
  後重新 `/report-gcp`。」然後結束。
- **成功**：記下帳號與專案，直接進入階段 ①，不要停下來問使用者。

## 階段 ① — 掃描（同步，前景等待）

派 `gcp-scanner`（同步執行、等它完成）跑
`bash .claude/skills/report-gcp/scripts/scan.sh <專案 ID> <期別>` 掃描專案
（兩者都留空則 `bash .claude/skills/report-gcp/scripts/scan.sh`，用 gcloud 目前設定的專案與上個完整月）。
使用的身分應為**唯讀身分**（只掛 `roles/viewer` + `roles/iam.securityReviewer` +
`roles/recommender.viewer` + `roles/billing.viewer`）——唯讀鐵則的強制層在 IAM。
腳本會做唯讀自檢並把結果寫進 `data/scan-meta.json` 的 `credential_check`。

完成後確認 `data/inventory.md`、`data/scan-meta.json` 與 **`data/digest/network-facts.md`** 都存在；
若缺任一，停止並回報掃描失敗原因（讀 `data/scan-errors.log` 說明）。
network-facts 是安全性／可靠性分析的必要輸入（防火牆實際暴露面、Cloud SQL 可及性等
跨檔關聯事實），缺了它 LLM 就得自己做交叉比對——那正是會漏掉高風險發現的地方。

## 階段 ② — 五支柱並行分析（背景並行）

**在同一則訊息裡並行派五個分析 agent**（背景執行），等五個都完成通知才進下一階段：

- `security-auditor` → `findings/security.md`
- `reliability-reviewer` → `findings/reliability.md`
- `performance-reviewer` → `findings/performance.md`
- `cost-optimizer` → `findings/cost.md`
- `ops-reviewer` → `findings/operations.md`

五個都回報後，逐一確認對應 `findings/*.md` 存在。
若**某一支硬失敗**（完全無輸出檔）：**記錄該支柱缺漏、繼續用其餘支柱往下走**，
在最末摘要明確標註「缺 X 支柱」，不要因單一支柱失敗中止整批，也不要停下來問使用者。

## 階段 ③ — 彙整報告

五份 findings 齊全（或已確認哪些缺漏）後，派 `report-writer` 產出：
- `report/GCP架構報告.md`
- `report/report-data.json`

## 階段 ④ — 確定性產生 HTML（由你＝主對話執行）

report-writer 沒有 Bash，這步由你跑：

```
node .claude/skills/report-gcp/scripts/build-report.js
```

- 成功 → 產出 `report/gcp-report.html`，進入階段 ⑤。
- 若因 `report-data.json` 不合 schema 而 `exit 1`：讀取錯誤訊息，回頭請 `report-writer`
  只修正該欄位後**重跑一次** `build-report.js`（**最多重試一次**）。仍失敗才停止並回報錯誤細節。

## 階段 ⑤ — 連結檢查（由你＝主對話執行）

報告交付前確認引用的官方文件連結沒有失效（不經過 LLM，不碰 GCP 專案）：

```
bash .claude/skills/report-gcp/scripts/check-links.sh report/GCP架構報告.md findings/security.md findings/reliability.md findings/performance.md findings/cost.md findings/operations.md
```

- 全數有效 → 進入階段 ⑥。
- 有失效連結（exit 1）→ **不要中止流程**。把失效清單記下來，在收尾摘要中列出，
  並提醒需更新 `.claude/skills/report-gcp/references/` 下對應支柱的目錄檔。
- 標為「⚠️ 可疑」者不影響退出碼，但要一併列進摘要請使用者人工確認。

## 階段 ⑥ — 存檔本期報告（由你＝主對話執行）

```
bash .claude/skills/report-gcp/scripts/archive-report.sh
```

存到 `archive/<期別>/`。**這步不可略過**：`report/` 與 `findings/` 都被 gitignore 且每跑一次
整份覆蓋，不存檔的話上一期報告就永久消失，日後無法做跨期回歸檢查（比對這期是否有發現無聲消失或被降級）。

## 收尾（唯一的回報時機）

輸出一則摘要：
- 期別、掃描的專案與區域、掃描日期、**唯讀自檢結果**（`credential_check`；
  若為 `write-capable` 要明確提醒使用者換唯讀身分）
- 五支柱各自分數與各嚴重度（高／中／低）發現數；若有缺漏支柱明確標註
- 連結檢查結果（全數有效／失效清單／可疑清單）
- 產出檔路徑：`report/gcp-report.html`、`report/GCP架構報告.md`、`report/report-data.json`
- **成本明細為資料缺口**的提醒，以及「接上 BigQuery 帳單匯出即可補齊」的建議
- 提醒：如需對外分享版，可再要求 `node .claude/skills/report-gcp/scripts/build-report.js --masked`
  （遮罩防呆）或發佈 Artifact
