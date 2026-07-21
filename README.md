# GCP 架構報告 Agent Team

以 Claude Code 多 agent 協作，對實際 GCP 專案進行**全程唯讀**掃描，
依 [Google Cloud Well-Architected Framework](https://cloud.google.com/architecture/framework) 五大支柱
（安全性、可靠性、效能最佳化、成本最佳化、卓越運維）產出繁體中文架構報告（Markdown + HTML）。

姊妹專案：[agent-team-aws-reports](https://github.com/Bright0505/agent-team-aws-reports)（AWS 版，四大支柱）。

## 特色

- **唯讀保證**：掃描只使用 `list` / `describe` / `get-iam-policy` 類指令，不對專案做任何變更；
  強制層在 IAM（唯讀身分），另有 deny 清單與 PreToolUse hook 兩道輔助防線
- **證據導向**：每項發現的現況證據必須對回 `data/` 內的實際掃描資料，不憑空推測
- **跨檔關聯確定性計算**：防火牆的實際暴露面、VM 對外路徑、Cloud SQL 可及性由腳本算成事實表，
  不交給 LLM 判斷（這正是最容易誤判的三件事）
- **並行分析**：五大支柱由五個 agent 並行分析，最後由 report-writer 彙整
- **固定版型**：HTML 報告由確定性腳本從模板＋結構化資料產生，不經過 LLM，逐月版型完全一致
- **敏感資訊保護**：掃描原始資料（`data/`）已列入 `.gitignore`，只留本機；
  需要對外分享時可用 `--masked` 產生遮罩版報告

## 前置條件

- [Google Cloud CLI](https://cloud.google.com/sdk/docs/install)、`jq`、`python3`、[Node.js](https://nodejs.org/)
- 有效的 GCP 憑證（`gcloud auth list` 須有 ACTIVE 帳號）。**強烈建議使用唯讀身分**：
  專用服務帳戶只掛 `roles/viewer`、`roles/iam.securityReviewer`、`roles/recommender.viewer`、
  `roles/billing.viewer`——唯讀保證的強制層在 IAM，專案內的 deny 清單與 agent 規則只是輔助防線
- [Claude Code](https://claude.com/claude-code)

## 使用方式

一鍵無人值守：在 Claude Code 輸入 `/report-gcp <專案 ID> <期別>`
（如 `/report-gcp my-project-123 2026-06`；都可留空），會依下列流程跑完全程、中途不停、結束才回報：

```
① gcp-scanner（同步執行）
     執行 .claude/skills/report-gcp/scripts/scan.sh → data/**.json + data/inventory.md
     末尾自動跑 digest.sh → data/digest/（精簡投影＋跨檔關聯事實表，含證據欄位斷言）
② 五個分析 agent（並行背景執行，等 ① 完成後才派工）
     security-auditor / reliability-reviewer / performance-reviewer / cost-optimizer / ops-reviewer
     各自輸出 findings/<pillar>.md
③ report-writer（等 ② 全部完成後才派工）
     彙整 → report/GCP架構報告.md + report/report-data.json
④ 確定性產生 HTML（不經過 LLM，版型逐月固定）
     node .claude/skills/report-gcp/scripts/build-report.js → report/gcp-report.html
⑤ 連結檢查（不經過 LLM，不碰 GCP 專案）
     bash .claude/skills/report-gcp/scripts/check-links.sh report/GCP架構報告.md findings/*.md
⑥ 存檔本期報告（跨期回歸比對的依據）
     bash .claude/skills/report-gcp/scripts/archive-report.sh → archive/<期別>/
```

也可以手動先跑掃描：

```bash
bash .claude/skills/report-gcp/scripts/scan.sh                      # 用 gcloud 目前設定的專案
bash .claude/skills/report-gcp/scripts/scan.sh my-project-123       # 指定專案
bash .claude/skills/report-gcp/scripts/scan.sh my-project-123 2026-06   # 指定專案與期別
```

API 未啟用或權限不足的項目會記錄到 `data/scan-errors.log` 並繼續執行，屬預期行為；
`data/digest/scan-gaps.md` 會把「回空結果＝未設定（有效證據）」與「查詢失敗＝資料缺口」分清楚。

HTML 報告產生器：

```bash
node .claude/skills/report-gcp/scripts/build-report.js                # report-data.json + 模板 → report/gcp-report.html
node .claude/skills/report-gcp/scripts/build-report.js --standalone   # 包成完整 HTML 供本機直接開啟
node .claude/skills/report-gcp/scripts/build-report.js --theme .claude/skills/report-gcp/templates/themes/<專案>.css
node .claude/skills/report-gcp/scripts/build-report.js --masked       # 對外分享版：啟用遮罩防呆檢查
```

版型與章節結構凍結在 `.claude/skills/report-gcp/templates/report.html.template`；配色 token 抽在
`.claude/skills/report-gcp/templates/themes/`，不同專案換主題檔即可。資料欄位規格見
`.claude/skills/report-gcp/templates/report-data.spec.md`，完整範例見
`.claude/skills/report-gcp/templates/report-data.example.json`。

## 目錄結構

| 路徑 | 用途 |
|---|---|
| `.claude/agents/` | 七個 agent 定義 |
| `.claude/skills/report-gcp/SKILL.md` | `/report-gcp` 一鍵無人值守流程 |
| `.claude/skills/report-gcp/scripts/scan.sh` | 唯讀掃描腳本（末尾自動呼叫 digest.sh） |
| `.claude/skills/report-gcp/scripts/digest.sh` | 掃描資料精簡（本機 jq；含證據欄位斷言，欄位遺失即失敗） |
| `.claude/skills/report-gcp/scripts/network-facts.py` | 跨檔關聯事實表（防火牆暴露面／VM 對外路徑／Cloud SQL 可及性） |
| `.claude/skills/report-gcp/scripts/check-links.sh` | 官方文件連結有效性檢查 |
| `.claude/skills/report-gcp/scripts/archive-report.sh` | 存檔本期報告到 archive/<期別>/ |
| `.claude/skills/report-gcp/scripts/build-report.js` | 確定性 HTML 報告產生器（模板＋資料填充，不經過 LLM） |
| `.claude/skills/report-gcp/references/` | 已驗證的官方文件連結目錄（依支柱拆分，agent 只讀自己那份） |
| `.claude/skills/report-gcp/templates/` | 發現格式、HTML 模板、主題、report-data 規格與範例 |
| `data/` | 掃描原始資料（gitignore，只留本機） |
| `data/digest/` | 原始資料的確定性投影——agent 的預設讀取來源（gitignore） |
| `findings/` | 各支柱分析結果（執行時產生） |
| `report/` | 最終報告（執行時產生，每次執行覆蓋） |
| `archive/` | 各期報告存檔（gitignore；跨期回歸比對靠它，**不要清掉**） |
| `CLAUDE.md` | Claude Code 專案指示（鐵則與流程細節） |

## Agent 一覽

| Agent | 角色 |
|---|---|
| `gcp-scanner` | 唯讀掃描 GCP 專案，產出 `data/**.json` 與資源盤點摘要 `data/inventory.md` |
| `security-auditor` | 安全性支柱分析 → `findings/security.md`（SEC-xx） |
| `reliability-reviewer` | 可靠性支柱分析 → `findings/reliability.md`（REL-xx） |
| `performance-reviewer` | 效能最佳化支柱分析 → `findings/performance.md`（PERF-xx） |
| `cost-optimizer` | 成本最佳化支柱分析 → `findings/cost.md`（COST-xx） |
| `ops-reviewer` | 卓越運維支柱分析 → `findings/operations.md`（OPS-xx） |
| `report-writer` | 彙整五大支柱發現 → `report/GCP架構報告.md` ＋ `report/report-data.json` |

## 已知限制

- **成本明細查不到**：GCP 沒有等同 AWS Cost Explorer 的成本明細 API，需 BigQuery 帳單匯出。
  本專案不接，成本支柱改以「預算設定 ＋ Recommender 官方估算 ＋ 資源組態推算」為依據，
  **實際帳單明細一律列為資料缺口**。若已設定帳單匯出，可另行擴充 `scan.sh` 以 `bq` 查詢。
- **單一專案**：掃描範圍為單一 GCP 專案；組織／資料夾層設定（Security Command Center、
  組織政策繼承）需組織層權限，目前不在範圍。
- **不含架構圖**：AWS 版有選配的 draw.io 架構圖產生器，GCP 版尚未移植。

## 慣例

- **發現編號**：`SEC-` / `REL-` / `PERF-` / `COST-` / `OPS-` + 流水號，全流程保留不改編
- **嚴重度**：高／中／低，定義見 `.claude/skills/report-gcp/templates/finding-format.md`
- **報告語言**：繁體中文，Google Cloud 服務名稱保留英文
- **參考文件**：建議必須附 Google Cloud 官方文件連結

## 安全注意事項

- `data/` 含專案內部資訊，**不得提交或外傳**
- 報告預設不遮罩（正式上線用途）；對外分享前用 `build-report.js --masked` 產生遮罩版並通過防呆檢查
- 憑證失效時請自行更新（`gcloud auth login`），agent 不會代為處理憑證
