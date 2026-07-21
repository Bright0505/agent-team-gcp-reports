---
name: gcp-diagram
description: 把 /report-gcp 的掃描產物（data/）確定性轉成 draw.io 架構圖（全景架構頁＋架構索引頁＋每 VPC 網路一頁，含防火牆實際暴露面）。選配功能，想到才跑，不在無人值守流程內。
---

把 `data/` 掃描資料轉成 draw.io 架構圖檔 `report/gcp-architecture.drawio`。

**鐵則：架構圖由腳本確定性產生，不要讓 LLM 手畫或手改 drawio XML。**
同樣輸入必得同樣輸出，逐月重跑版面固定、diff 即拓撲變化；LLM 手畫必然漂移、漏資源。
版面調整需求一律改 `scripts/build-diagram.js` 檔頭的版面常數（`SUM` / `LAYOUT`）或樣式表（`STYLES`）
後重跑——不要在產出的 `.drawio` 上手改後期待重跑保留（重跑會整檔覆蓋）。

## 版型為什麼長這樣（改動前先讀）

**版型是照 GCP 的網路模型設計的，不是通用雲端架構圖的樣板。**
CLAUDE.md 那三個「GCP 最容易誤判之處」，正是這張圖每一個版面決定的理由——
下面每一條都擋著一種很容易被「順手改掉」的錯誤：

1. **GCP 沒有公有／私有子網**。子網不分層，本圖的兩條通道是
   **「有外部 IP」vs「僅內部 IP」**——判準是**資源本身**，不是它在哪個子網。
   子網方塊因此畫成**橫跨兩條通道之上**的獨立區塊：版面本身就是那句結論。
   **不要改成依子網分層**，那會得到錯誤結論。
   對外連出看 Cloud NAT、存取 Google API 看 Private Google Access，兩者都標在子網方塊上。
2. **防火牆是標籤導向**。「規則存在」與「真的暴露」是兩回事。本圖把
   「規則 × VM 標籤／服務帳戶 × 外部 IP」交叉算出**真的有 VM 套用**的規則才畫紅框，
   判定邏輯（`ruleApplies`）與 report-gcp 的 `network-facts.py` 是同一套。
   **只有算得出成員 VM 的資源列才畫防火牆框**——後端服務、轉送規則、Cloud SQL 不受 VPC 防火牆
   規則管轄，硬畫一個框會是錯的結論。
3. **VPC 網路是全域的、子網是區域的**。所以層級是「VPC 框內含區域欄」，
   **不是「區域框內含 VPC」**——後者在 GCP 是顛倒的，一個 VPC 本來就橫跨所有區域。
   且**自動模式（auto mode）VPC 會在每一個 GCP 區域自動建一個子網**（實測 43 個），
   全部畫出來會淹掉整張圖——因此只畫「有資源參照」的區域，其餘計入 `subnetAccounted`
   並在圖上標明摺疊了幾個。**計數斷言仍然涵蓋全部子網**，不容許靜默漏畫。

## 前置依賴（資料契約）

本 skill 依賴 `/report-gcp` 的掃描產物檔案佈局，**全程只讀本機檔案，不碰 GCP 專案**：

- 必要：`data/scan-meta.json`、`data/network/networks.json`、`data/network/subnets.json`、
  `data/network/firewall-rules.json`、`data/compute/instances.json`
  （後者缺檔時退回 `data/digest/compute-instances.json`）
- 選配：`network/routers.json`、`network/addresses.json`、
  `compute/instance-groups.json`（受管）、`compute/instance-groups-all.json`（含未受管，
  **負載平衡器的後端常是未受管群組，少了它流量鏈會斷**）、
  `compute/gke-clusters.json`、`compute/run-services.json`、`compute/functions.json`、
  `lb/{forwarding-rules,backend-services,url-maps,target-http(s)-proxies,security-policies}.json`、
  `db/sql-instances.json`、`storage/buckets.json`、
  `ops/{dns-zones,logging-sinks,monitoring-policies,uptime-checks}.json`、
  `global/{org-policies,iam-service-accounts}.json`

**「空回應」與「查詢失敗」是相反的結論**（CLAUDE.md 的鐵則，本腳本照做）：
選配檔案**存在但是 `[]`** ＝ 該類資源確實不存在，圖上照實畫「未設定」；
選配檔案**不存在** ＝ 掃描查詢失敗（API 未啟用／權限不足）＝ 資料缺口，收進圖上的黃色缺口方塊
與 stdout 的 `⚠ 資料缺口` 區塊。**絕不可把資料缺口畫成「未設定」。**

必要檔案缺檔會明確報錯。**缺檔時請使用者先跑 `/report-gcp`（或至少階段①掃描），
不要自行呼叫 gcloud 補查**——那違反「期別快照」的稽核軌跡，而且臨場組出的指令含 `$(...)` 展開，
會被 `hook-gcloud-literal-guard.sh` 擋下。

## 執行步驟

1. 執行產生器（從專案根目錄）：
   ```
   node .claude/skills/gcp-diagram/scripts/build-diagram.js
   ```
   選用 `--out <路徑>` 改輸出位置（預設 `report/gcp-architecture.drawio`）。
2. 腳本 stdout 會印計數摘要，並內建**「畫出數量 ＋ 摺疊計數 == 來源 JSON 數量」斷言**，
   失敗即非零退出。摘要另外會直接印出這張圖最該被覆核的兩行：
   - **暴露面**：有外部 IP 的 VM 幾台、其中「外部 IP ＋ 被 0.0.0.0/0 的 allow 規則套用」幾台（列出機器名）
   - **Cloud SQL 公開 IP**：哪幾個有公開 IP、授權網段幾個、有沒有 `0.0.0.0/0`

   把摘要轉述給使用者，可對照 `data/inventory.md` 與 `data/digest/network-facts.md` 覆核。
3. 提示使用者用 [app.diagrams.net](https://app.diagrams.net) 或 VS Code 的 Draw.io
   Integration 擴充開啟 `.drawio` 檔目視確認；之後要匯出 PNG/SVG 也在那裡做。
4. 使用者若要調版面（間距、配色、圖示、頁面切分），改 `build-diagram.js` 的
   `SUM` / `LAYOUT` / `STYLES` 常數重跑；若是資料判讀規則（例如新增一種流量邊），改對應的
   join 函式——**邊一律只畫「可證明的 join」，證明不了就不畫、不猜**。

## 產出結構

單一 `.drawio` 檔、多分頁（資料驅動，不寫死環境名）：

頁 1 與頁 2 分工不同，不是重複：**頁 1 是「一張看完全部細節」，頁 2 是「一行看完規模＋分頁導覽」**。
專案長大到多 VPC 多區域時，頁 1 會失去一張看完的價值，頁 2 才是索引。

- **頁 1「全景架構」**：全專案一張，給對外簡報用。
  雲外左欄（網際網路使用者 → Cloud DNS → 外部轉送規則）→ Google Cloud 專案框，
  框內左側是專案層服務欄（Cloud Logging sink／Monitoring 告警／Uptime check／Cloud Armor／
  組織政策／服務帳戶，數量為 0 者灰化標「未設定」；下接 Cloud Storage 值區與無伺服器服務），
  右側每個 VPC 網路一個區塊：
  - 頂列 Cloud Router／Cloud NAT（沒有時明說「無外部 IP 的 VM 沒有對外連出的路徑」）
  - 中段**子網區塊**（橫跨兩通道之上，每區域一欄，標 CIDR／PGA／流量記錄／NAT 覆蓋）
  - 下段**兩條暴露通道**（左：有外部 IP，紅；右：僅內部 IP，藍），資源列由上而下＝流量方向：
    外部負載平衡 → 後端服務 → 內部 LB／PSC → GKE → MIG → 獨立 VM（依外部 IP 拆兩列）→ Cloud SQL
  - 每個「算得出成員 VM」的資源列外圈一個**防火牆框**：灰虛線＝有規則套用但無 `0.0.0.0/0`；
    紅粗框＝有來源 `0.0.0.0/0` 的 allow 規則實際套用（標出規則名與埠）
- **頁 2「架構索引」**：使用者 → 外部轉送規則 → 各 VPC 縮略框／Cloud Storage。
  縮略框標「有外部 IP 的 VM 幾台／共幾台」與「⚠ 實際暴露幾台」。
  無工作負載的 VPC 在此只有縮略框（但全景架構頁仍會完整畫出其子網）。
- **頁 3..N**：每個「有工作負載（VM／轉送規則／MIG／GKE／Cloud SQL 任一）」的 VPC 一頁——
  完整流量鏈（外部轉送規則 → 目標代理＋URL 對應 → 後端服務 → MIG → VM → Cloud SQL → 內部 LB），
  下方是子網表（**每區域一欄，不分公私**）。此頁的 VM 逐台畫出，不摺疊。

### 邊的規則（可證明才畫）

| 邊 | 依據 | 線型 |
|---|---|---|
| 轉送規則 → 目標代理 → URL 對應 → 後端服務 | selfLink 逐段比對 | 實線 |
| 後端服務 → 執行個體群組 | `backends[].group` 名稱比對 | 實線 |
| 未掃描到的群組 | 被後端服務指名＝存在有證據，組態不明 | 節點標 **⚠ 未掃描到此群組** |
| GKE → MIG | `cluster.instanceGroupUrls`（selfLink） | 實線 |
| MIG → VM | `baseInstanceName` 前綴＝GCP 受管群組的**命名規則**，非 selfLink | **虛線** |
| VM → Cloud SQL | `privateNetwork` == VM 網路，或 VM 外部 IP 落在 `authorizedNetworks` | 實線（標經由哪條路） |
| 唯讀複本 → 主執行個體 | `masterInstanceName` | 實線 |
| Cloud DNS → 負載平衡器 | **不畫** | — |

Cloud DNS 那一列是刻意的：`scan.sh` 只列出 managed-zones、**沒有 record set**，
「這個網域指向哪個 LB」證明不了。寧可少畫一條邊，也不要畫一條猜的。

**「證明不了就不畫」講的是關聯，不是節點。** 被 `backends[].group` 指名的執行個體群組，
存在本身是有證據的（後端服務明白指向它），只是組態沒掃到——這種一律畫成標示
「⚠ 未掃描到此群組」的節點。**靜默跳過會讓流量鏈憑空斷在後端服務，讀圖的人只會以為
「後面沒東西了」，比畫一個誠實標示未知的節點更容易誤導**（實際踩過：7 個後端服務
全部沒有往下的邊，正式環境對外 LB 的後端整段消失）。

同理，執行個體群組有三種來源，標籤上要分清楚，不可混為一談：
受管 MIG（有可用區與執行個體數）、未受管群組（有可用區，成員需另查 `listInstances`，本流程未掃）、
未掃描到（只有名稱）。

### 警示標記（確定性規則，不讀 findings/）

- VM 有外部 IP **且**被來源 `0.0.0.0/0` 的 allow 規則套用 → 標 ⚠ 與開放埠；所在資源列轉黃框、防火牆框轉紅
- Cloud SQL 有公開 IP → ⚠；再含 `0.0.0.0/0` 授權網路 → 標「⚠ 公開 IP ＋ 授權 0.0.0.0/0」
- Cloud SQL SSL 模式非 `REQUIRED`／`ENCRYPTED_ONLY`／`TRUSTED_CLIENT_CERTIFICATE_REQUIRED` → ⚠（`ALLOW_UNENCRYPTED_AND_ENCRYPTED` 等同未強制加密）
- Cloud SQL 未啟用自動備份 → ⚠
- 外部後端服務未掛 Cloud Armor → ⚠；存取記錄未開 → ⚠
- HTTPS 目標代理未指定 SSL 政策 → ⚠
- GKE 節點非私有／無主控授權網段 → ⚠
- 子網缺 Private Google Access **或** 缺 Cloud NAT 覆蓋 → 黃框 ⚠，並標明缺的是哪條路徑。
  **兩者管不同的事、不可互相替代**（官方：*"Traffic sent to Google APIs and services are routed
  through Private Google Access even if the VM instance initiating the connections uses Public NAT."*）：
  PGA 關 → 僅內部 IP 的 VM 到不了 Google API，**有 Cloud NAT 也救不了**；無 NAT → 連不出網際網路。
  寫成「兩者皆無才示警」會把「有 NAT 但 PGA 關」這個常見組態標成沒問題，是相反的結論。
- Cloud Storage 值區 PAP 非 `enforced`／UBLA 未啟用 → ⚠
- 自動模式 VPC → 標題列 ⚠

## 圖示：`mxgraph.gcp2.*`，名字必須對 stencil 查

用 draw.io 的 **`mxgraph.gcp2.*`**。draw.io 目前（查證於 2026-07-21）同時維護三組 GCP 圖庫：

| 圖庫 | draw.io UI 名稱 | shape 數 | stencil 最後更新 | 說明 |
|---|---|---:|---|---|
| `gcp` | GCP / Cards | 少 | — | 最早的一組，只有卡片樣式 |
| **`gcp2`** | GCP / Networking、Compute、Databases…（17 組） | **298** | 2026-05-16（sidebar 2026-06-19） | **本 skill 採用** |
| `gcp3` | GCP Categories、GCP Core Products（2 組） | 46 | 2026-05-27（首次提交，僅 1 次） | 2026 新增，最新品牌 |

**`gcp3` 是新增、不是取代。** 它 2026-05-27 才進 repo（至今只有 1 次提交），內容是
「產品分類圖示」＋約 20 個主打產品（Vertex AI／AI Hypercomputer／Mandiant／AlloyDB…），
採用 Google 最新的品牌視覺。但它**沒有** Cloud DNS、Load Balancing、Cloud NAT、Cloud Router、
Cloud Functions、users——這張圖有 11 個圖示，`gcp3` 只湊得出 5 個，畫不了網路拓撲。
而且 `gcp2` 的 sidebar 在 `gcp3` 進 repo 之後（2026-06-19）仍在更新，並未被棄用。

**因此結論是「`gcp2` 是這張圖唯一可用的完整圖庫」，不是「`gcp2` 比較新」。**
若日後 `gcp3` 補齊網路元件，再整組換過去（**不要兩組混用**——視覺風格不一致，
而且會讓 `GCP2_SHAPES` 白名單失去意義）。重新查證的方式見下方指令。

**shape 名必須逐字對得上 stencil，格式是「小寫＋底線」**：draw.io 把 stencil 裡的
`<shape name="Container Engine">` 正規化成 `container_engine`。

⚠️ **名字打錯不會報錯**——draw.io 靜默退成一個帶標籤的方框，看起來只是「圖示醜了點」，
很容易矇混過去。因此 `build-diagram.js` 內建 `GCP2_SHAPES` 白名單，`STYLES` 用到白名單外的名字
就直接 exit 1。**新增圖示時先查 stencil、把名字加進白名單**：

```
# 查某個圖庫有哪些 shape（名字要再做「小寫＋空格轉底線」正規化）
gh api repos/jgraph/drawio/contents/src/main/webapp/stencils/gcp2.xml \
   -H "Accept: application/vnd.github.raw" | grep -o '<shape name="[^"]*"'

# 查 gcp3 是否已補齊網路元件（補齊了才值得整組換過去）
gh api repos/jgraph/drawio/contents/src/main/webapp/stencils/gcp3.xml \
   -H "Accept: application/vnd.github.raw" | grep -oiE '<shape name="[^"]*(dns|balanc|nat|router)[^"]*"'
```

**不要只讀部落格文章判斷哪組最新**——drawio-app.com 那篇〈Updated Google Cloud Platform Icons
and Templates〉發表於 2022 年，它說的「updated GCP Icons」指的就是 `gcp2`，並不涵蓋 2026 年才
出現的 `gcp3`。權威來源是 stencil 檔本身與它的 commit 紀錄。

產品名的直覺拼法常常是錯的（本 skill 實際踩過的三個）：

| 用途 | 直覺（錯，會變方框） | stencil 實際名稱 |
|---|---|---|
| GKE | `google_kubernetes_engine` | `container_engine`（GKE 的舊稱 Container Engine） |
| 受管執行個體群組 | `instance_group` | `servers_stacked`（gcp2 沒有 MIG 專屬圖示） |
| Private Service Connect | `cloud_interconnect` | `service_discovery`（gcp2 沒有 PSC 專屬圖示） |

樣式字串比照官方 `Sidebar-GCP2.js` 的寫法。**漏給 `fillColor` 會變白圖形（等於隱形）、
漏給 `aspect=fixed` 圖形會被拉變形**，兩者都改 `gcpIcon()` 一處即可。

## 其他已知取捨
- **全景架構頁摺疊 MIG／GKE 的節點 VM**（只畫叢集／群組並標節點數），否則幾十顆節點會淹掉整張圖。
  摺疊掉的一律計入 `vmAccounted`／`migAccounted`，計數斷言照樣守住總數。逐 VPC 頁不摺疊。

`report/` 會被下一輪報告流程覆蓋；本期定稿後由 report-gcp 的 `archive-report.sh`
一併存到 `archive/<期別>/`。
