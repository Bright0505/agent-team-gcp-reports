# GCP 架構報告 Agent Team

依 Google Cloud Well-Architected Framework 五大支柱（安全性、可靠性、效能最佳化、成本最佳化、
卓越運維），以唯讀掃描實際 GCP 專案為依據，產出繁體中文架構報告（Markdown + HTML）。

> 本專案的鐵則多數不是預先設計出來的，而是實際踩過坑後固化下來的機制
> （標「歷史教訓」者即是）。改動這些規則前請先讀懂它們擋的是什麼。

## 鐵則

- **對 GCP 專案全程唯讀**：只允許 `list` / `describe` / `get-iam-policy` 類指令，
  任何 agent 都不得執行變更專案狀態的指令
- **dontAsk 的語意是「不問＝自動拒絕」**：allow 內靜默放行、deny 內擋下、兩者皆非→自動拒。
  因此 **allow 清單是 dontAsk 下唯一的放行通道，不是死配置**——新增會被主對話或 agent 直接呼叫的
  腳本時，**必須同步加 allow 條目**（歷史教訓：曾因存檔腳本漏加 allow 而在無人值守中被拒，
  流程被迫用 Read/Write 手動複製）。權限類改動要用**全新 session** 驗證，改設定的 session 驗不出來。
- **唯讀的強制層在 IAM，不在權限提示**：掃描與補查一律使用唯讀身分——建議專用服務帳戶，
  只掛 `roles/viewer` + `roles/iam.securityReviewer` + `roles/recommender.viewer` +
  `roles/billing.viewer`，寫入 API 在專案側直接 PERMISSION_DENIED。
  `scan.sh` 會做**唯讀自檢**（查專案 IAM policy 中當前身分的角色），命中 `roles/owner`／`roles/editor`
  即大聲警告並記進 `data/scan-meta.json` 的 `credential_check`。
  模型層保留兩道輔助防線：settings 的 gcloud 寫入 deny 清單、以及「`gcloud` 指令必須是字面量」規則
  （deny 是字串比對，`$變數`/`$(...)` 展開會讓它失明，已由 PreToolUse hook 機制化強制）。
  本機權限已放寬為 `dontAsk`（不再逐條跳提示；deny 清單在此模式下仍然生效），
  **不要**把唯讀保證寄託在權限提示上
- **精簡只在本機做，不在擷取端做**：`scan.sh` 一律抓完整 JSON，精簡交給 `digest.sh`（本機 jq）。
  不要改用 gcloud 的 `--format` 投影裁切——那是「擷取時破壞、不可逆」，欄位判斷錯了只能重掃專案，
  而重掃時專案狀態已變，會破壞報告「期別＝已結束週期的快照」的稽核軌跡；且 `--format` 欄位名打錯時
  gcloud 靜默回空值且 exit 0，`run()` 完全接不住。digest 判斷錯了改 jq 重跑即可，原始證據永遠保留。
- **直譯器只處理本機資料**：`python3` / `awk` / `sed` 等只用於處理 `data/` 本機檔案；嚴禁透過任何
  直譯器、管線或子程序間接呼叫會變更 GCP 專案狀態的指令（deny 清單是字串比對，直譯器會繞過，
  故此條以指令層規範補上死角）
- `data/` 含專案內部資訊，已列入 .gitignore，不得提交或外傳
- 報告為正式上線用途，**預設不遮罩**專案 ID 等資訊；僅在使用者明確要求對外分享版時才產生遮罩版
  （`build-report.js --masked` 會做遮罩防呆檢查）

## GCP 特有的四件事（最容易誤判之處）

1. **成本明細查不到，但官方牌價查得到——這是兩件不同的事**：GCP 沒有可直接查詢成本明細
   （這個專案這個月實際花多少錢）的 API，需 BigQuery 帳單匯出，本專案不接，因此
   **實際帳單明細一律列為資料缺口**，成本支柱改以「預算設定 ＋ Recommender 官方估算 ＋
   資源組態推算」為依據。**絕不可用推算值冒充實際帳單數字。**
   資源組態推算所需的**官方單價**（某資源型號在某地區的牌價）則查得到，走
   `pricing-lookup.sh` 直查 Cloud Billing Catalog API——這與帳單明細不是同一回事，
   查得到牌價不代表查得到帳單。
2. **沒有公有／私有子網**：GCP 的對外可及性看「VM 有沒有外部 IP」、對外連出看 Cloud NAT、
   存取 Google API 看 Private Google Access。套用「公有子網／私有子網」的心智模型會得到錯誤結論。
3. **防火牆是標籤導向**：一條 `allow 0.0.0.0/0 → tcp:22` 的規則可能一台機器都沒套用，
   也可能套用到全網路（沒有 targetTags ＝ 套用到該網路所有 VM）。
   **「規則存在」與「真的暴露」是兩回事**，只看 firewall-rules.json 必然誤判——
   故由 `network-facts.py` 把「規則 × VM 標籤 × 外部 IP」交叉算成結論。
4. **無伺服器／受管服務同樣沒有公有／私有子網的概念**：Cloud Run、Cloud Functions、App Engine、
   Dataproc、Dataflow、Vertex AI Endpoint 等的網路歸屬**不是看它在哪個子網**，而是看兩件事——
   **對外可及性**看 ingress／端點設定（Cloud Run 的 `ingress=INGRESS_TRAFFIC_ALL`、Vertex Endpoint
   無 PSC 且無 network peering ＝公開端點）；**對內連出（進哪個 VPC）**看 VPC egress 機制
   （Serverless VPC Access connector／Direct VPC egress／PSC／VPC peering）。**只看清單層級（list）
   看不到這些欄位，必須逐一 describe**——這正是最初那個誤判的根因：Cloud Run 明明直連 VPC，卻因為
   只掃了 list 而被畫成「不屬於任何 VPC」。相關判定由 `network-facts.py` 第四段與各服務的
   `digest/*.md` 算成結論，agent 讀結論即可。

## 執行流程（三階段）

一鍵無人值守請用 `/report-gcp <專案 ID> <期別>`（見 `.claude/skills/report-gcp/SKILL.md`），
會依下列流程不中途停頓跑完全程、結束才回報；憑證失效時在階段 0 快速失敗。手動逐段執行時流程相同：

```
① gcp-scanner（同步執行）
     掃描 → data/**.json + data/inventory.md
     scan.sh 末尾自動跑 digest.sh → data/digest/（精簡投影＋跨檔關聯事實表）
② 五個分析 agent（並行背景執行，等 ① 完成後才派工）
     security-auditor / reliability-reviewer / performance-reviewer / cost-optimizer / ops-reviewer
     各自輸出 findings/<pillar>.md
③ report-writer（等 ② 全部完成後才派工）
     彙整 → report/GCP架構報告.md + report/report-data.json（HTML 報告的結構化資料）
④ 主對話執行確定性產生器（不經過 LLM，版型逐月固定）
     node .claude/skills/report-gcp/scripts/build-report.js → report/gcp-report.html
⑤ 主對話執行連結檢查（不經過 LLM，不碰 GCP 專案）
     bash .claude/skills/report-gcp/scripts/check-links.sh report/GCP架構報告.md findings/*.md
⑥ 主對話存檔本期報告
     bash .claude/skills/report-gcp/scripts/archive-report.sh → archive/<期別>/
```

HTML 版型、配色、章節結構凍結在 `.claude/skills/report-gcp/templates/report.html.template` 與
`.claude/skills/report-gcp/templates/themes/*.css`，**不要每月重新設計**；逐月只換 report-data.json 的資料。
資料欄位規格見 `.claude/skills/report-gcp/templates/report-data.spec.md`。換專案配色時新增
`.claude/skills/report-gcp/templates/themes/<專案>.css` 並以 `--theme` 指定，版型不動。
**支柱數是 5，寫死在 `build-report.js` 的 `PILLAR_DEFS` 與模板的 `.cards` grid**，兩者要同步改。

各 agent 依工作性質分級指定模型（frontmatter `model:` 欄位，用別名以免模型改版逐檔改）：
scanner 走 `haiku`（純機械掃描）；performance-reviewer / cost-optimizer / ops-reviewer 走 `sonnet`
（規則比對、數字核對）；security-auditor / reliability-reviewer / report-writer 走 `opus`
（風險判斷與綜合寫作，品質優先）。

前置條件：gcloud 已安裝且已登入（`gcloud auth list` 有 ACTIVE 帳號）。
失效時請使用者更新，不要代為處理憑證。

**架構圖是選配的另一條線**：`.claude/skills/gcp-diagram/` 吃同一份 `data/`，產出
`report/gcp-architecture.drawio`。**它不在上面的六個階段內**，使用者想要時才單獨跑；
產物由 `archive-report.sh` 一併存檔（該腳本對它有 `[ -f ]` 守衛，沒跑就跳過）。

備註：報告產到本機檔案為止，**無人值守流程不自動發佈 Artifact**（報告預設不遮罩、含專案 ID）；
要發佈是使用者事後另外指定的動作。另，`dontAsk` 下**改不動 `.claude/` 底下的檔案**——
Edit/Write 一律被拒，補 allow 條目也沒用（這與「新增腳本要同步加 allow」是兩件事：
allow 管的是「能不能執行」，不管「能不能改 `.claude/` 裡的檔」）。要改 agent／skill／腳本本身時，
請使用者按 Shift+Tab 把當下 session 切成 acceptEdits，改完切回，不要去動 `settings.json` 的 `defaultMode`。

## 目錄結構

| 路徑 | 用途 |
|---|---|
| `.claude/agents/` | 七個 agent 定義 |
| `.claude/skills/report-gcp/scripts/scan.sh` | 唯讀掃描腳本（scanner 執行；`scan.sh <project-id> <期別>`） |
| `.claude/skills/report-gcp/scripts/digest.sh` | 掃描資料精簡（本機 jq，scan.sh 末尾自動呼叫；含證據欄位斷言） |
| `.claude/skills/report-gcp/scripts/network-facts.py` | 跨檔關聯（防火牆實際暴露面／VM 對外路徑／Cloud SQL 可及性）——確定性計算，不交給 LLM 判斷 |
| `.claude/skills/report-gcp/scripts/archive-report.sh` | 存檔本期報告到 archive/<期別>/（放頂層，不放 report/ 底下——清報告時會一起毀掉） |
| `.claude/skills/report-gcp/scripts/check-links.sh` | 官方文件連結有效性檢查（確定性，8 路平行；不碰 GCP 專案） |
| `.claude/skills/report-gcp/scripts/build-report.js` | 確定性 HTML 產生器（report-data.json＋模板→HTML；schema 契約見 spec） |
| `.claude/skills/report-gcp/scripts/hook-gcloud-literal-guard.sh` | PreToolUse hook：機制化攔截含展開的 gcloud/gsutil/bq 指令 |
| `.claude/skills/report-gcp/scripts/pricing-lookup.sh` | 直查 Cloud Billing Catalog API 取官方牌價（美金），取代 WebFetch 定價頁；cost-optimizer 呼叫 |
| `.claude/skills/report-gcp/references/gcp-docs-*.md` | 已驗證的官方文件連結目錄，依支柱拆分——各 agent 只讀自己那份（common 檔含使用規則） |
| `.claude/skills/report-gcp/references/pricing-service-ids.json` | Cloud Billing Catalog 的 serviceId 對照表（Google 全域產品代碼，不含專案機密；用到才查、查過自動寫回）。**目前不進版控**（見 `.gitignore`：本專案還在 template 階段），不存在時 `pricing-lookup.sh` 會自動建立空表 |
| `.claude/skills/report-gcp/templates/finding-format.md` | 發現統一格式——agent 之間的檔案介面，改動需同步引用它的六個 agent（gcp-scanner 不產 findings，不引用） |
| `.claude/skills/report-gcp/templates/report-data.spec.md` | report-data.json 的完整契約（含必填與驗證規則）——即完整規格，不需讀 build-report.js |
| `.claude/skills/gcp-diagram/` | **選配**：draw.io 架構圖產生器（`build-diagram.js`＋SKILL.md），不在無人值守流程內，想到才跑 |
| `data/` | 掃描原始資料（gitignore） |
| `data/digest/` | 原始資料的確定性投影，agent 的預設讀取來源（gitignore） |
| `findings/` | 各支柱分析結果（gitignore） |
| `report/` | 最終報告（gitignore，每次執行覆蓋） |
| `archive/` | 各期報告存檔（gitignore；跨期回歸比對靠它，**不要清掉**） |
| `tmp/` | 暫存檔專用目錄（gitignore）。**內容完全不得提交**；目錄本身要保留，不是無用殘留 |

## 慣例

- **`gcloud` 指令必須是字面量**（約束對象：agent 在 Bash **臨場輸入**的指令；版控內經審查的固定腳本
  如 scan.sh 不在此限——其動詞是寫死的唯讀字面量，變數只出現在參數位）：不得含 `$變數`、`$(...)`、
  迴圈或萬用字元——deny 清單靠字串比對，展開會讓它失明。需要值就先讀出來、直接寫進指令。
  此規則已由 PreToolUse hook（`hook-gcloud-literal-guard.sh`）**機制化強制**，不再只靠 prompt 服從。
  本機資料處理（jq/python3/awk 對 `data/` 檔案）不受此限。
  **大檔只需少數欄位時優先用 jq 過濾而非 Read 整檔**（Read 一次拉整份數千字元，五支柱平行時同檔重複計費）。
- **空回應 ≠ 資料缺口**：gcloud 對「沒有這類資源」回的是空清單，例如專案沒有任何預算、
  沒有任何告警政策。這是**有效證據**，可直接下發現。`data/digest/scan-gaps.md` 已把
  「回空結果＝未設定」與「查詢失敗（API 未啟用／權限不足）＝資料缺口」分清楚——
  agent 看到查不到的東西先讀它，不要自己回頭呼叫 gcloud 補查。
  **把資料缺口寫成「未設定」是相反的結論，不可發生。**
  ⚠️ **各服務「API 未啟用」的回應樣式並不一致，新增服務掃描時務必逐一實測**（歷史教訓，
  Phase 4-10 逐一踩過）：多數服務未啟用回 `SERVICE_DISABLED`（`run()` 能正確歸資料缺口）；
  但 **Dataflow 未啟用時 `jobs list` 竟靜默回 `[]`＋exit 0**，若直接 `run()` 會被誤歸成「未設定」
  （相反結論）；App Engine 回的錯誤訊息不符 `NOT_FOUND` 樣式；`bq ls` 空清單回空字串而非 `[]`；
  Dataproc／Vertex AI 不吃 `--region -` 且 `gcloud ai` 的 stderr 首行固定是「Using endpoint …」
  會污染 `run()` 的 FAILED reason。這幾類都在 `scan.sh` 用**「先讀 `services-enabled.json` 做
  API 啟用預檢」或自訂空判斷**繞過——絕不能假設所有服務都遵循標準 `[]` 慣例。
- **機械性的跨檔比對交給腳本，不要交給 LLM 判斷**：像「這條 0.0.0.0/0 的防火牆規則到底有沒有
  機器套用」這種要同時看三個檔才看得出來的關聯，一律在 `network-facts.py` 算成事實表，agent 讀結論。
  LLM 會忘、會隨機（歷史教訓：曾因漏做這一步把 [高] 發現降級成 [中]，還給出該環境做不到的修復建議）。
- **寫完要自我複查、不讀回、修訂用 Edit**：`Write` 成功即已寫入，內容還在 context 裡，
  再 `Read` 一次是重複計費；但**自我複查那一輪不能省**——逐條對照檢查重點，有遺漏用 `Edit` 補。
- 發現編號：SEC- / REL- / PERF- / COST- / OPS- + 流水號，全流程保留不改編
- 嚴重度：高／中／低，定義見 `.claude/skills/report-gcp/templates/finding-format.md`
- 報告語言：繁體中文，Google Cloud 服務名稱保留英文
- 建議必須附 Google Cloud 官方文件連結（Well-Architected Framework、服務文件、Architecture Center）
- **連結一律取自 `.claude/skills/report-gcp/references/gcp-docs-<支柱>.md`**（依支柱拆分，各 agent 只讀自己那份），
  不要為了確認連結有效而 WebFetch 整頁文件。有效性一律用
  `bash .claude/skills/report-gcp/scripts/check-links.sh` 檢查；目錄未涵蓋的主題才 WebFetch，
  查完把新連結補回**對應支柱的檔案**。例外：成本金額估算需要當下單價時，改跑
  `bash .claude/skills/report-gcp/scripts/pricing-lookup.sh` 直查官方 Cloud Billing Catalog API
  取美金牌價（同一次報告執行內快取，跨期一律重查，不沿用舊值），不再 WebFetch 定價頁——
  `gcp-docs-cost.md` 的定價頁連結現在只當引用，不是查價來源。
