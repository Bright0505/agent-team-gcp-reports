# Google Cloud 官方文件連結目錄

五大支柱 agent 撰寫建議時的引用來源（背景說明與使用規則；連結本體依支柱拆在 `gcp-docs-<支柱>.md`）。
**最後驗證：2026-07-21（90 個連結全數有效，以 `check-links.sh` 確定性檢查）**

## 為什麼有這個檔案

CLAUDE.md 規定「建議必須附 Google Cloud 官方文件連結」。若讓 agent 每次用 WebFetch 逐頁抓取來確認連結，
會有兩個問題：

1. **浪費**：把整頁文件（單頁可達數萬字元）拉進 context 只為了確認連結能開，每個月重抓同樣的頁面。
2. **沒防到呆**：目視判斷抓不準。`cloud.google.com` 對不存在的頁面雖然**會**正確回 HTTP 404
   ，但它也會對某些路徑回「HTTP 200 的導向殼」，用 WebFetch 看起來像正常頁面。

因此改為：**連結由目錄檔提供（已驗證），有效性由 `.claude/skills/report-gcp/scripts/check-links.sh`
確定性檢查**（不經過 LLM、不花 token）。

## 使用規則（五大支柱 agent）

- 引用官方文件時，**從自己支柱的 `gcp-docs-<支柱>.md` 取用**，不要為了「確認連結有效」而 WebFetch。
- 目錄沒有涵蓋的主題，才用 WebFetch 查證；**查到後把新連結補進對應支柱的 `gcp-docs-<支柱>.md`**，供下個月重複使用。
- 不確定某連結是否仍有效時，跑 `bash .claude/skills/report-gcp/scripts/check-links.sh`，不要用 WebFetch 目視判斷。
- **例外**：成本金額估算需要當下單價時，仍應 WebFetch 定價頁（價格會變動，不可沿用舊值）。

---

## Well-Architected Framework（五大支柱進入點）

- [Google Cloud Well-Architected Framework](https://cloud.google.com/architecture/framework) — 總論
- [Security, privacy, and compliance](https://cloud.google.com/architecture/framework/security) — 安全性支柱
- [Reliability](https://cloud.google.com/architecture/framework/reliability) — 可靠性支柱
- [Performance optimization](https://cloud.google.com/architecture/framework/performance-optimization) — 效能最佳化支柱
- [Cost optimization](https://cloud.google.com/architecture/framework/cost-optimization) — 成本最佳化支柱
- [Operational excellence](https://cloud.google.com/architecture/framework/operational-excellence) — 卓越運維支柱

## 跨支柱通用

- [Architecture Center](https://cloud.google.com/architecture) — 參考架構與最佳實務總覽
- [Enterprise foundations blueprint](https://cloud.google.com/architecture/security-foundations) — 企業基礎環境的安全基準
- [Google Cloud Pricing Calculator](https://cloud.google.com/products/calculator) — 金額估算
