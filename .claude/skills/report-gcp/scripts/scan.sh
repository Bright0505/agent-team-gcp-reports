#!/usr/bin/env bash
# GCP 唯讀掃描腳本
# 只使用 list / describe / get-iam-policy 等唯讀指令，不對專案做任何變更。
# 權限不足或 API 未啟用時記錄到 data/scan-errors.log 並繼續執行。
#
# 用法（從專案根目錄執行）：bash .claude/skills/report-gcp/scripts/scan.sh [project-id] [period]
#   bash .claude/skills/report-gcp/scripts/scan.sh my-project-123 2026-06   # 月報：2026 年 6 月
#   bash .claude/skills/report-gcp/scripts/scan.sh                          # 用 gcloud 目前設定的專案、上一個完整月
#   期別＝一個「已結束的完整週期」（報告主體）；資源盤點與組態一律為當下快照，不受期別影響。
#   期別來源優先序：PERIOD 環境變數 > 第二個位置參數 > 留空（上一個完整月）。
#
# 兩個刻意的設計（勿「修正」回去）：
#   1. GCP 的 `gcloud compute * list` 預設就跨全部區域／可用區列出，不需要逐區偵測迴圈。
#      少數真的要指定 location 的服務（Cloud Run／Redis／KMS）才從已掃到的資源推導位置清單。
#   2. 成本明細沒有可直接查詢的 API（要靠 BigQuery 帳單匯出）。本腳本改抓
#      billing 設定＋budgets＋Recommender 建議，成本明細在報告中標為「資料缺口」。
#
# ⚠️ 變數後若緊貼全形字元（如 `${PROJECT}（`）**必須加大括號**：bash 會把全形字元當成
#    變數名的一部分，在 set -u 下直接以 "unbound variable" 中止（2026-07-21 首次實跑即踩到）。
#    本檔訊息全為中文，幾乎每行 echo 都可能踩到，新增訊息時務必注意。

set -u
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

# ── 兩種根分離：資產（腳本/模板/目錄檔）跟著 skill 目錄走，輸出（data/ 等）跟著執行時的 cwd 走。
# 這讓整個 .claude/skills/report-gcp/ 可以原封拷到任何專案使用。
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="$PWD"
if [ ! -d "$WORK_ROOT/.claude/skills/report-gcp" ]; then
  echo "錯誤：請從裝有本 skill 的專案根目錄執行（cwd 下找不到 .claude/skills/report-gcp）" >&2
  exit 1
fi
DATA="$WORK_ROOT/data"
ERRLOG="$DATA/scan-errors.log"
mkdir -p "$DATA"
: > "$ERRLOG"

# ── 報告期別（嚴格週期；預設「上一個完整月」）────────────────────────────
# 期別指向一個「已結束的完整週期」，用於報告標題與存檔目錄名。
#   月報 YYYY-MM（留空＝上個月）、季報 YYYY-QN、年報 YYYY。
shift_month() {  # $1=YYYY-MM-01 錨點  $2=帶號月位移(如 +1 -2)  → YYYY-MM-01
  date -j -v"${2}"m -f "%Y-%m-%d" "$1" +%Y-%m-01 2>/dev/null \
    || date -d "$1 ${2} month" +%Y-%m-01
}

PERIOD="${PERIOD:-${2:-}}"
if [ -z "$PERIOD" ]; then
  REPORT_TYPE="month"; TARGET_START="$(shift_month "$(date +%Y-%m-01)" -1)"; PERIOD="${TARGET_START%-01}"
elif [[ "$PERIOD" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
  REPORT_TYPE="month"; TARGET_START="${PERIOD}-01"
elif [[ "$PERIOD" =~ ^([0-9]{4})-[Qq]([1-4])$ ]]; then
  REPORT_TYPE="quarter"
  TARGET_START="$(printf '%s-%02d-01' "${BASH_REMATCH[1]}" $(( (BASH_REMATCH[2]-1)*3 + 1 )))"
elif [[ "$PERIOD" =~ ^[0-9]{4}$ ]]; then
  REPORT_TYPE="year"; TARGET_START="${PERIOD}-01-01"
else
  echo "警告：無法解析期別 '$PERIOD'，退回上個月月報" >&2
  REPORT_TYPE="month"; TARGET_START="$(shift_month "$(date +%Y-%m-01)" -1)"; PERIOD="${TARGET_START%-01}"
fi
case "$REPORT_TYPE" in
  month)   SPAN=1 ;;
  quarter) SPAN=3 ;;
  year)    SPAN=12 ;;
esac
TARGET_END="$(shift_month "$TARGET_START" "+${SPAN}")"
THIS_MONTH="$(date +%Y-%m-01)"
if [[ "$TARGET_END" > "$THIS_MONTH" ]]; then
  echo "警告：期別 ${PERIOD} 尚未結束（週期結束後才跑才是慣例）" >&2
fi
echo "報告期別: ${PERIOD}（型別 ${REPORT_TYPE}，主體 [${TARGET_START}→${TARGET_END})）"

# ── 驗證身分與專案 ───────────────────────────────────────────────────
echo "=== 驗證身分 ==="
if ! command -v gcloud > /dev/null 2>&1; then
  echo "錯誤：找不到 gcloud，請先安裝 Google Cloud SDK（brew install --cask google-cloud-sdk）" >&2
  exit 1
fi

ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>>"$ERRLOG" | head -1)"
if [ -z "$ACTIVE_ACCOUNT" ]; then
  echo "錯誤：gcloud 未登入，請先執行 gcloud auth login（或 gcloud auth activate-service-account）" >&2
  exit 1
fi

PROJECT="${1:-}"
if [ -z "$PROJECT" ]; then
  PROJECT="$(gcloud config get-value project 2>/dev/null | grep -v '^(unset)$' || true)"
fi
if [ -z "$PROJECT" ]; then
  echo "錯誤：未指定專案且 gcloud 未設定預設專案。請執行：bash .claude/skills/report-gcp/scripts/scan.sh <project-id>" >&2
  exit 1
fi

if ! gcloud projects describe "$PROJECT" --format=json > "$DATA/project.json" 2>>"$ERRLOG"; then
  echo "錯誤：無法讀取專案 ${PROJECT}（憑證無效或無 resourcemanager.projects.get 權限）" >&2
  exit 1
fi
PROJECT_NUMBER="$(jq -r '.projectNumber // "?"' "$DATA/project.json")"
echo "專案: ${PROJECT}（編號 ${PROJECT_NUMBER}）/ 身分: $ACTIVE_ACCOUNT"

# run <輸出檔名(不含.json)> <gcloud 參數...>
# 三種結果要分清楚，否則 agent 讀到會誤判（並且會回頭去問 GCP，觸發權限確認）：
#   ok    有內容
#   empty 呼叫成功但回空陣列／空回應 → 該項「未設定／不存在」（例：專案沒有任何預算、
#         沒有任何 Cloud SQL 執行個體）。這是**有效證據**，不是資料缺口。
#   fail  呼叫失敗 → 真正的資料缺口（權限不足／API 未啟用）
# 注意：gcloud list 對「沒有資源」回的是 `[]`（2 位元組）而非空字串，因此空判斷要看 JSON 內容。
run() {
  local out="$1"; shift
  local dir; dir="$(dirname "$DATA/$out")"; mkdir -p "$dir"
  local errtmp; errtmp="$(mktemp)"
  if gcloud "$@" --format=json > "$DATA/$out.json" 2>"$errtmp"; then
    if [ -s "$DATA/$out.json" ] && ! jq -e 'if type=="array" then length==0 elif type=="object" then length==0 else false end' \
         "$DATA/$out.json" > /dev/null 2>&1; then
      echo "  ok    $out"
    else
      echo "  empty $out (回空結果＝該項未設定／無此類資源)"
      echo "EMPTY: $out :: gcloud $*" >> "$ERRLOG"
    fi
  else
    echo "  fail  $out (見 scan-errors.log)"
    cat "$errtmp" >> "$ERRLOG"
    # 失敗原因首行寫進 FAILED 標記本身——下游（digest 的缺口分類）只讀這一行，
    # 不再用 grep -B1 猜「錯誤訊息在前一行」（gcloud 錯誤訊息常有多行，行距假設會誤分類）
    echo "FAILED: $out :: reason=$(head -1 "$errtmp" | tr -d '\n') :: gcloud $*" >> "$ERRLOG"
    rm -f "$DATA/$out.json"
  fi
  rm -f "$errtmp"
}

# ── 唯讀自檢 ─────────────────────────────────────────────────────────
# 鐵則的強制層在 IAM，但「這組憑證是唯讀」這個假設要驗證，不能只是假設。
# 查專案 IAM policy 中當前帳號綁到的角色；命中 owner/editor 即大聲警告。
CRED_CHECK="unverifiable"
if gcloud projects get-iam-policy "$PROJECT" --format=json > "$DATA/iam-policy.json" 2>>"$ERRLOG"; then
  MY_ROLES="$(jq -r --arg a "$ACTIVE_ACCOUNT" \
    '[.bindings[]? | select((.members // []) | any(. == ("user:"+$a) or . == ("serviceAccount:"+$a))) | .role] | join(" ")' \
    "$DATA/iam-policy.json" 2>/dev/null || true)"
  if [ -z "$MY_ROLES" ]; then
    # 可能是透過群組繼承或組織層授權，查不到不代表唯讀
    CRED_CHECK="unverifiable (未在專案層 IAM policy 中直接找到此身分)"
  elif printf '%s' "$MY_ROLES" | grep -qE 'roles/(owner|editor)$|roles/(owner|editor) '; then
    echo "" >&2
    echo "⚠️⚠️ 警告：此身分掛有寫入級角色（${MY_ROLES}）——唯讀鐵則的 IAM 強制層是空的！" >&2
    echo "         建議改用只掛 roles/viewer + roles/iam.securityReviewer 的專用身分（掃描仍繼續，風險自負）。" >&2
    echo "" >&2
    CRED_CHECK="write-capable: $MY_ROLES"
  else
    echo "身分角色: ${MY_ROLES}（未見 owner／editor）"
    CRED_CHECK="read-only-ish: $MY_ROLES"
  fi
fi

P=(--project "$PROJECT")

echo "=== 專案層 ==="
run "global/services-enabled"    services list --enabled "${P[@]}"
run "global/iam-service-accounts" iam service-accounts list "${P[@]}"
# 逐一服務帳戶：使用者自管金鑰（長期憑證，安全支柱重點證據）
mkdir -p "$DATA/global/sa-detail"
for sa in $(jq -r '.[].email // empty' "$DATA/global/iam-service-accounts.json" 2>/dev/null); do
  run "global/sa-detail/$sa-keys" iam service-accounts keys list --iam-account "$sa" \
      --managed-by user "${P[@]}"
done
run "global/iam-custom-roles"    iam roles list --project "$PROJECT"
run "global/org-policies"        resource-manager org-policies list --project "$PROJECT"

echo "=== 網路 ==="
run "network/networks"        compute networks list "${P[@]}"
run "network/subnets"         compute networks subnets list "${P[@]}"
run "network/routes"          compute routes list "${P[@]}"
run "network/firewall-rules"  compute firewall-rules list "${P[@]}"
run "network/addresses"       compute addresses list "${P[@]}"
run "network/routers"         compute routers list "${P[@]}"
run "network/vpn-tunnels"     compute vpn-tunnels list "${P[@]}"
run "network/vpn-gateways"    compute vpn-gateways list "${P[@]}"
run "network/interconnects"   compute interconnects list "${P[@]}"
run "network/vpc-connectors"  compute networks vpc-access connectors list --region - "${P[@]}"

echo "=== 運算 ==="
run "compute/instances"        compute instances list "${P[@]}"
run "compute/instance-groups"  compute instance-groups managed list "${P[@]}"
# ⚠️ 上一行只列出**受管**群組。負載平衡器的後端（backend-services 的 backends[].group）
#    很常是**未受管**群組——GKE 自建的 `k8s-ig--*` 與人工建立的群組都是，兩者都不會出現在
#    managed list 裡。少了這一行，「後端服務 → 執行個體群組」這一段流量鏈就完全查不到後端是誰
#    （2026-07-21 實測：7 個後端服務指向的 group 沒有一個查得到）。
run "compute/instance-groups-all" compute instance-groups list "${P[@]}"
run "compute/instance-templates" compute instance-templates list "${P[@]}"
run "compute/disks"            compute disks list "${P[@]}"
run "compute/snapshots"        compute snapshots list "${P[@]}"
run "compute/images"           compute images list --no-standard-images "${P[@]}"
run "compute/gke-clusters"     container clusters list "${P[@]}"
# 逐叢集 describe：list 拿不到 privateClusterConfig／masterAuthorizedNetworksConfig／
# ipAllocationPolicy／networkConfig 等網路欄位，必須逐一 describe（比照下方 Cloud SQL 逐個 describe）。
# 位置（region 或 zone）取自 list 結果的 .location（regional）或 .zone（zonal）；
# `--location` 同時吃 region／zone 兩種，不必分流。
mkdir -p "$DATA/compute/gke-detail"
while IFS=$'\t' read -r gname gloc; do
  [ -z "$gname" ] && continue
  run "compute/gke-detail/$gname-describe" container clusters describe "$gname" --location "$gloc" "${P[@]}"
done < <(jq -r '.[] | [.name, (.location // .zone // empty)] | @tsv' "$DATA/compute/gke-clusters.json" 2>/dev/null)

# Cloud Run 不吃 `--region -`（會被當成 endpoint override 而報錯）；不給 --region 就是列全部區域
run "compute/run-services"     run services list "${P[@]}"
# 逐服務 describe：list 拿不到 ingress／vpcAccess（Direct VPC egress／connector）等網路欄位。
# ⚠️ gcloud run services list --format=json 的實際輸出可能是 v1 Knative 風格（.metadata.name）
#    也可能是 v2 風格（.name），故服務名用雙路 fallback；region 同理從
#    .metadata.labels["cloud.googleapis.com/location"] 或 .region 取（Cloud Run 服務有區域性，
#    describe 需帶 --region）。**本專案 Cloud Run API 未啟用，此段未經真實資料實測**——
#    實際輸出命中哪一路 fallback、需不需要 --region，待日後有真實資料時回來核對。
mkdir -p "$DATA/compute/run-detail"
while IFS=$'\t' read -r rname rloc; do
  [ -z "$rname" ] && continue
  if [ -n "$rloc" ]; then
    run "compute/run-detail/$rname-describe" run services describe "$rname" --region "$rloc" "${P[@]}"
  else
    run "compute/run-detail/$rname-describe" run services describe "$rname" "${P[@]}"
  fi
done < <(jq -r '.[] | [(.metadata.name // .name // empty), (.metadata.labels["cloud.googleapis.com/location"] // .region // empty)] | @tsv' "$DATA/compute/run-services.json" 2>/dev/null)

run "compute/functions"        functions list "${P[@]}"
# 逐函式 describe：list 拿不到 VPC connector／ingress 設定。Cloud Functions 的 .name 常是完整資源
# 路徑（projects/.../locations/<region>/functions/<短名>）。先解析出 region 與短名，帶
# --region＋短名 describe；解析不出 region 時退回用整個 .name 直接 describe（兩種都先嘗試）。
# **本專案 Functions API 未啟用，此段未經真實資料實測**——實際哪一路可行待日後核對。
mkdir -p "$DATA/compute/functions-detail"
while IFS=$'\t' read -r fname floc fshort; do
  [ -z "$fname" ] && continue
  if [ -n "$floc" ]; then
    run "compute/functions-detail/$fshort-describe" functions describe "$fshort" --region "$floc" "${P[@]}"
  else
    run "compute/functions-detail/$fshort-describe" functions describe "$fname" "${P[@]}"
  fi
done < <(jq -r '.[] | (.name // empty) as $n | ($n | split("/")) as $p | [$n, (if ($p|length) >= 4 then $p[3] else "" end), ($p | last)] | @tsv' "$DATA/compute/functions.json" 2>/dev/null)

# App Engine（無伺服器運算；有 VPC connector／ingress 網路歸屬，性質接近 Cloud Run）。
# 網路欄位分屬**兩個層級**（2026-07-23 查證官方 Admin API v1，勿沿用「都在 version 層」的舊假設）：
#   ‧ Ingress 控制在 **service** 層：`networkSettings.ingressTrafficAllowed`
#     （enum：INGRESS_TRAFFIC_ALLOWED_ALL／_INTERNAL_ONLY／_INTERNAL_AND_LB）→ `app services describe`
#   ‧ VPC 出口／環境在 **version** 層：`vpcAccessConnector.{name,egressSetting}`、
#     `network.{name,subnetworkName,instanceTag}`、`env`（standard／flexible）、`inboundServices[]`
#     → `app versions describe <VER> --service <SVC>`
# 故流程＝describe app → list services →（逐服務 describe 拿 ingress）→ list versions →（逐版本 describe 拿網路）。
# ⚠️ 為什麼不用 run()（2026-07-23 本專案 erp-greattree-prod 實測）：對「未建立 App Engine 應用」的專案，
#    `gcloud app describe` 回 **exit 1** ＋訊息「does not contain an App Engine application」。此訊息不符
#    scan-gaps.md 的 NOT_FOUND 樣式，若走 run() 會被歸為 FAILED（資料缺口）——但這其實是「未設定／
#    無此類資源」（有效證據），兩者結論相反、違反本專案鐵則。故本段自訂空判斷：偵測該訊息記為 EMPTY，
#    其餘錯誤（API 未啟用／權限不足）才記 FAILED。app 存在後的 services／versions list 仍可安全走 run()。
# ⚠️ 本專案未建立 App Engine 應用，service／version 層的網路欄位路徑**未經真實資料驗證**（同 Cloud Run
#    情形）；service 名／version id 的 jq 取法用雙路 fallback，digest 對應段落已加「欄位無法解析→斷言 FAIL」防呆。
mkdir -p "$DATA/appengine"
AE_APP="$DATA/appengine/app.json"
AE_ERR="$(mktemp)"
if gcloud app describe --project="$PROJECT" --format=json > "$AE_APP" 2>"$AE_ERR"; then
  echo "  ok    appengine/app"
  run "appengine/services" app services list "${P[@]}"
  # 逐服務 describe：ingress 控制（networkSettings）在 service 層，list 拿不到
  mkdir -p "$DATA/appengine/service-detail"
  while IFS= read -r aesvc; do
    [ -z "$aesvc" ] && continue
    run "appengine/service-detail/$aesvc-describe" app services describe "$aesvc" "${P[@]}"
  done < <(jq -r '.[]? | (.id // (.name | split("/") | last) // empty)' "$DATA/appengine/services.json" 2>/dev/null)
  run "appengine/versions" app versions list "${P[@]}"
  # 逐版本 describe：VPC connector／network／env／inboundServices 在 version 層，list 拿不到完整組態。
  # service 名與 version id 用雙路 fallback（頂層 .service／.id 為主，退回巢狀 .version.service／.version.id）。
  mkdir -p "$DATA/appengine/version-detail"
  while IFS=$'\t' read -r aesvc aever; do
    [ -z "$aesvc" ] && continue
    [ -z "$aever" ] && continue
    run "appengine/version-detail/$aesvc-$aever-describe" app versions describe "$aever" --service "$aesvc" "${P[@]}"
    # 迴圈這裡就已知 service 名（--service "$aesvc"），把它與 version 名注入 JSON 供 digest 回填：
    # version describe 的輸出若只有 .id 而無全路徑 .name（apps/.../services/SVC/versions/VER），
    # digest 從 .name 推 service 會得到「?」、network-facts 第 4 段該列的服務關聯就丟了。
    # 注入 _scan_service／_scan_version（不覆蓋任何 gcloud 原欄位，只補確定性的權威來源）避免此問題。
    # run() 只在成功時留檔，故先判存在再注入（本機 jq 處理 data/ 檔，不碰 GCP）。
    AEVF="$DATA/appengine/version-detail/$aesvc-$aever-describe.json"
    if [ -f "$AEVF" ]; then
      jq --arg svc "$aesvc" --arg ver "$aever" '. + {_scan_service: $svc, _scan_version: $ver}' \
         "$AEVF" > "$AEVF.tmp" 2>/dev/null && mv "$AEVF.tmp" "$AEVF" || rm -f "$AEVF.tmp"
    fi
  done < <(jq -r '.[]? | [(.service // .version.service // empty), (.id // .version.id // empty)] | @tsv' "$DATA/appengine/versions.json" 2>/dev/null)
else
  # 收斂成 App Engine 專屬訊息＋精確大寫 NOT_FOUND：裸 `not found`＋`-i` 會把任何含「not found」
  # 的錯誤（例如打錯專案 ID）誤歸成「未建立 App Engine＝未設定」——那是相反的結論，故移除。
  if grep -qE 'does not contain an App Engine application|NOT_FOUND' "$AE_ERR"; then
    echo "  empty appengine/app (回空結果＝本專案未建立 App Engine 應用)"
    echo "EMPTY: appengine/app :: gcloud app describe" >> "$ERRLOG"
  else
    echo "  fail  appengine/app (見 scan-errors.log)"
    cat "$AE_ERR" >> "$ERRLOG"
    echo "FAILED: appengine/app :: reason=$(head -1 "$AE_ERR" | tr -d '\n') :: gcloud app describe" >> "$ERRLOG"
  fi
  rm -f "$AE_APP"
fi
rm -f "$AE_ERR"

echo "=== 負載平衡與邊緣 ==="
run "lb/forwarding-rules"    compute forwarding-rules list "${P[@]}"
run "lb/backend-services"    compute backend-services list "${P[@]}"
run "lb/url-maps"            compute url-maps list "${P[@]}"
run "lb/target-https-proxies" compute target-https-proxies list "${P[@]}"
run "lb/target-http-proxies"  compute target-http-proxies list "${P[@]}"
run "lb/health-checks"       compute health-checks list "${P[@]}"
run "lb/ssl-policies"        compute ssl-policies list "${P[@]}"
run "lb/ssl-certificates"    compute ssl-certificates list "${P[@]}"
run "lb/security-policies"   compute security-policies list "${P[@]}"

echo "=== 資料庫 ==="
run "db/sql-instances"  sql instances list "${P[@]}"
mkdir -p "$DATA/db/sql-detail"
for inst in $(jq -r '.[].name // empty' "$DATA/db/sql-instances.json" 2>/dev/null); do
  run "db/sql-detail/$inst-describe" sql instances describe "$inst" "${P[@]}"
  run "db/sql-detail/$inst-backups"  sql backups list --instance "$inst" "${P[@]}"
done
run "db/spanner-instances"  spanner instances list "${P[@]}"
run "db/bigtable-instances" bigtable instances list "${P[@]}"
run "db/firestore-databases" firestore databases list "${P[@]}"
run "db/redis-instances"    redis instances list --region - "${P[@]}"

# Memorystore for Memcached（Memorystore 的另一個引擎，與上方 Redis 同族；區域性資源，用 --region -
# 萬用查詢跨全部區域，同 Redis）。
# ⚠️ 空狀態行為（2026-07-23 實測 erp-greattree-prod）：memcache.googleapis.com **未啟用**時，
#    `memcache instances list --region -` 回**標準的** SERVICE_DISABLED（「Cloud Memorystore for
#    Memcached API has not been used ... before or it is disabled」，reason=SERVICE_DISABLED，exit 1），
#    這**符合** run() 的 FAILED 分類（→ digest 的 scan-gaps.md 正確歸為「資料缺口：API 未啟用」）；
#    比照 Filestore／AlloyDB，**不是** App Engine 那種需特殊比對的錯誤訊息。API 啟用但無 instance 時
#    回標準 `[]`（→ EMPTY／未設定）。兩種空狀態都遵循標準 gcloud 慣例，故走**標準 run()**、不需自訂空判斷。
#    （互動式會先跳「是否啟用 API？(y/N)」提示，但本檔已設 CLOUDSDK_CORE_DISABLE_PROMPTS=1，不會卡住。）
# ⚠️ Memcached 與 Redis 同屬 Memorystore、**無公開 IP 的概念**：只能透過綁定的 authorizedNetwork VPC
#    以 private services access 存取。`list --format=json` 已回**完整 Instance 資源**（含 authorizedNetwork／
#    zones／nodeCount／nodeConfig／memcacheVersion／state），比照 Redis／Filestore 不需逐一 describe。
# ⚠️ 欄位路徑**未經真實資料驗證**（本專案 API 未啟用，list 回 SERVICE_DISABLED、迴圈實跑 0 筆）；
#    僅依官方 Memcached REST v1 Instance schema 撰寫，digest 對應段落已加「欄位無法解析→斷言 FAIL」防呆。
run "db/memcached-instances" memcache instances list --region - "${P[@]}"

# AlloyDB（cluster → instance 兩層結構；區域性資源，用 --region - 萬用查詢跨全部區域）
# ⚠️ 空狀態行為（2026-07-23 實測 erp-greattree-prod）：AlloyDB API（alloydb.googleapis.com）**已啟用**、
#    但**無任何 cluster** 時，`alloydb clusters list --region -` 回**標準空陣列** `[]`＋exit 0
#    （不是 App Engine 那種特殊訊息，也不是 Filestore 的 SERVICE_DISABLED）。故走**標準 run()**，
#    EMPTY 分類正確、不需自訂空判斷（比照 BigQuery：API 已啟用但無資源＝有效證據，非資料缺口）。
# cluster／instance 的 .name 是完整資源路徑
#   projects/{P}/locations/{region}/clusters/{cid}[/instances/{iid}]
#   → 逐一 describe 需要 region（[3]）與短 id（cluster=[5]、instance=[7]），故從 name 解析。
# ⚠️ 欄位路徑（含 .name 是否為完整路徑）**未經真實資料驗證**——本專案無 cluster，迴圈實跑 0 次；
#    僅依官方 AlloyDB REST v1 clusters／instances schema 撰寫。
run "db/alloydb-clusters"  alloydb clusters list --region - "${P[@]}"
mkdir -p "$DATA/db/alloydb-detail"
while IFS=$'\t' read -r acregion acid; do
  [ -z "$acid" ] && continue
  run "db/alloydb-detail/$acid-cluster"    alloydb clusters describe "$acid" --region "$acregion" "${P[@]}"
  run "db/alloydb-detail/$acid-instances"  alloydb instances list --cluster "$acid" --region "$acregion" "${P[@]}"
  while IFS= read -r aiid; do
    [ -z "$aiid" ] && continue
    run "db/alloydb-detail/$acid-$aiid-instance" alloydb instances describe "$aiid" --cluster "$acid" --region "$acregion" "${P[@]}"
  done < <(jq -r '.[]?.name // empty | split("/") | last' "$DATA/db/alloydb-detail/$acid-instances.json" 2>/dev/null)
done < <(jq -r '.[]? | select(.name != null) | [ (.name | split("/")[3]), (.name | split("/")[5]) ] | @tsv' "$DATA/db/alloydb-clusters.json" 2>/dev/null)

echo "=== 資料分析（BigQuery）==="
# BigQuery 唯讀掃描：用原生 bq CLI（bq ls／bq show），不用 gcloud alpha bq，因此無法套用上方的 run()
# （run() 固定呼叫 gcloud）。以下為本節專屬的唯讀 list＋逐一 describe 區塊。
# ⚠️ 為什麼是 bq 而非 gcloud alpha bq（2026-07-23 實測）：`gcloud alpha bq datasets list/describe`
#    會對 quota 專案要求 serviceusage.services.use 權限，建議的唯讀身分（roles/viewer + securityReviewer
#    + recommender.viewer + billing.viewer）不一定具備——實測對非成員專案直接回 USER_PROJECT_DENIED。
#    bq CLI 走不同的配額機制，唯讀身分即可用；且 bq show 的 JSON 直接對應 BigQuery REST v2 Datasets
#    資源。欄位路徑（access[] 的 iamMember/specialGroup、location、defaultEncryptionConfiguration、
#    defaultTableExpirationMs）已用公開 dataset（bigquery-public-data:samples）實測驗證。
# ⚠️ bq 與 gcloud 的空值表現不同：dataset 為 0 時 `bq ls` 印**空字串**（非 gcloud 的 `[]`），
#    故下方自訂空判斷（空檔補成 `[]` 再判長度），不能沿用 run() 的空判斷。
# list 只回索引（datasetReference／location），拿不到 access[]／CMEK，故必須逐一 bq show。
mkdir -p "$DATA/bigquery/dataset-detail"
BQ_DS="$DATA/bigquery/datasets.json"
BQ_ERR="$(mktemp)"
if bq ls --datasets --format=prettyjson --project_id="$PROJECT" > "$BQ_DS" 2>"$BQ_ERR"; then
  [ -s "$BQ_DS" ] || echo "[]" > "$BQ_DS"
  BQ_N="$(jq -r 'length' "$BQ_DS" 2>/dev/null || echo 0)"
  if [ "${BQ_N:-0}" -eq 0 ]; then
    echo "  empty bigquery/datasets (回空結果＝本專案無 BigQuery dataset)"
    echo "EMPTY: bigquery/datasets :: bq ls --datasets" >> "$ERRLOG"
  else
    echo "  ok    bigquery/datasets（${BQ_N} 個）"
    while IFS= read -r dsid; do
      [ -z "$dsid" ] && continue
      dstmp="$(mktemp)"
      if bq show --format=prettyjson "$PROJECT:$dsid" > "$DATA/bigquery/dataset-detail/$dsid-describe.json" 2>"$dstmp"; then
        echo "  ok    bigquery/dataset-detail/$dsid"
      else
        echo "  fail  bigquery/dataset-detail/$dsid (見 scan-errors.log)"
        cat "$dstmp" >> "$ERRLOG"
        echo "FAILED: bigquery/dataset-detail/$dsid :: reason=$(head -1 "$dstmp" | tr -d '\n') :: bq show $PROJECT:$dsid" >> "$ERRLOG"
        rm -f "$DATA/bigquery/dataset-detail/$dsid-describe.json"
      fi
      rm -f "$dstmp"
    done < <(jq -r '.[].datasetReference.datasetId // empty' "$BQ_DS" 2>/dev/null)
  fi
else
  echo "  fail  bigquery/datasets (見 scan-errors.log)"
  cat "$BQ_ERR" >> "$ERRLOG"
  echo "FAILED: bigquery/datasets :: reason=$(head -1 "$BQ_ERR" | tr -d '\n') :: bq ls --datasets --project_id=$PROJECT" >> "$ERRLOG"
  rm -f "$BQ_DS"
fi
rm -f "$BQ_ERR"

echo "=== 訊息與事件（Pub/Sub）==="
# Pub/Sub 是**全域資源**（不像 Cloud Run／Redis／AlloyDB 有區域性），list **不需要** --region -。
# ⚠️ 空狀態行為（2026-07-23 實測 erp-greattree-prod）：pubsub.googleapis.com **已啟用**、但無任何
#    topic／subscription 時，`pubsub topics list`／`subscriptions list` 回**標準空陣列** `[]`＋exit 0
#    （與 AlloyDB／BigQuery 同情形＝有效證據，非資料缺口）。故走**標準 run()**、EMPTY 分類正確、
#    不需 App Engine／BigQuery 那種自訂空判斷。（Pub/Sub 常為預設啟用，本專案即已啟用但未建立任何資源。）
# ⚠️ `list --format=json` 已回**完整資源**（topic 含 kmsKeyName／messageStoragePolicy；subscription 含
#    pushConfig／bigqueryConfig／cloudStorageConfig／deadLetterPolicy 等），比照 Filestore／Memcached
#    不需逐一 describe 拿組態。唯一 list 拿不到的是**存取控制（IAM policy）**——誰能 publish／subscribe、
#    有沒有 allUsers／allAuthenticatedUsers 公開授權，這要逐一 get-iam-policy（唯讀，允許）。
# ⚠️ topic／subscription 的 .name 是完整路徑（projects/{P}/topics/{短名}、projects/{P}/subscriptions/{短名}），
#    取 last 當短名餵 get-iam-policy。
# ⚠️ 欄位路徑**未經真實資料驗證**（本專案無 topic／subscription，get-iam-policy 迴圈實跑 0 次）；僅依官方
#    Pub/Sub REST v1 projects.topics／projects.subscriptions schema 撰寫（pushConfig.pushEndpoint／
#    pushConfig.oidcToken.serviceAccountEmail／messageStoragePolicy.allowedPersistenceRegions／kmsKeyName），
#    digest 對應段落已加「欄位無法解析→斷言 FAIL」防呆。Pub/Sub 無傳統 VPC 網路歸屬（除非 VPC Service Controls，
#    掃不到），故不進 network-facts.py；push 訂閱指向外部 URL 的「對外資料流」由 digest 的 pubsub.md 呈現。
run "pubsub/topics" pubsub topics list "${P[@]}"
mkdir -p "$DATA/pubsub/topic-iam"
while IFS= read -r pstopic; do
  [ -z "$pstopic" ] && continue
  run "pubsub/topic-iam/$pstopic-iam" pubsub topics get-iam-policy "$pstopic" "${P[@]}"
done < <(jq -r '.[]?.name // empty | split("/") | last' "$DATA/pubsub/topics.json" 2>/dev/null)

run "pubsub/subscriptions" pubsub subscriptions list "${P[@]}"
mkdir -p "$DATA/pubsub/sub-iam"
while IFS= read -r pssub; do
  [ -z "$pssub" ] && continue
  run "pubsub/sub-iam/$pssub-iam" pubsub subscriptions get-iam-policy "$pssub" "${P[@]}"
done < <(jq -r '.[]?.name // empty | split("/") | last' "$DATA/pubsub/subscriptions.json" 2>/dev/null)

echo "=== 儲存 ==="
# GCS 一次呼叫就含 iamConfiguration（PAP／UBLA）／versioning／lifecycle／encryption，
# 不需要逐 bucket 分多次查詢。
run "storage/buckets" storage buckets list "${P[@]}"
# Filestore（受管 NFS 檔案儲存；概念上與 Cloud Storage 同屬儲存類，故放本段）。
# ⚠️ 位置查法（2026-07-23 查證 gcloud reference）：Filestore 是區域性資源，但 `filestore instances
#    list` 在**省略位置旗標時「uses all locations by default」**，預設就跨全部 zone／region 列出，
#    **不需要** Redis 那種 `--region -` 萬用查詢。且 `list --format=json` 已回**完整 Instance 資源**
#    （含 networks[]／fileShares[]／tier／state），不像 Cloud Run 要逐一 describe 才有網路欄位，
#    故本段只需一次 list、不另開 describe 迴圈。
# ⚠️ 為什麼可以走標準 run()（與 App Engine 不同，2026-07-23 本專案 erp-greattree-prod 實測）：
#    本專案 file.googleapis.com 未啟用，`filestore instances list` 回**標準的** SERVICE_DISABLED
#    （「Cloud Filestore API has not been used ... before or it is disabled」），這**符合** run() 的
#    FAILED 分類（→ digest 的 scan-gaps.md 正確歸為「資料缺口：API 未啟用」）；API 啟用但無執行個體時
#    gcloud 回標準 `[]`（→ EMPTY／未設定）。兩種空狀態都遵循標準 gcloud 慣例，無 App Engine 那種需要
#    特殊比對的錯誤訊息，故直接用 run()，不必自訂空判斷。
# ⚠️ Filestore **無公開 IP 的概念**：只能透過同 VPC／VPC Peering／Private Service Access 存取
#    （networks[].network＝綁定的 VPC、networks[].reservedIpRange＝保留網段、connectMode＝連線模式）。
#    欄位路徑本專案無真實資料驗證（API 未啟用），digest 對應段落已加「欄位無法解析→斷言 FAIL」防呆。
run "storage/filestore-instances" filestore instances list "${P[@]}"

echo "=== 維運與偵測 ==="
run "ops/logging-sinks"      logging sinks list "${P[@]}"
run "ops/logging-buckets"    logging buckets list --location=global "${P[@]}"
run "ops/logging-metrics"    logging metrics list "${P[@]}"
run "ops/monitoring-policies" alpha monitoring policies list "${P[@]}"
run "ops/uptime-checks"      monitoring uptime list-configs "${P[@]}"
run "ops/kms-keyrings"       kms keyrings list --location global "${P[@]}"
run "ops/dns-zones"          dns managed-zones list "${P[@]}"

echo "=== 成本訊號（GCP 無可直接查詢的成本明細 API）==="
run "cost/billing-info"    billing projects describe "$PROJECT"
BILLING_ACCOUNT="$(jq -r '.billingAccountName // empty' "$DATA/cost/billing-info.json" 2>/dev/null | sed 's|^billingAccounts/||')"
if [ -n "$BILLING_ACCOUNT" ]; then
  echo "帳單帳戶: $BILLING_ACCOUNT"
  run "cost/budgets" billing budgets list --billing-account "$BILLING_ACCOUNT"
else
  echo "  skip  cost/budgets（未取得帳單帳戶，可能未連結帳單或無 billing.viewer 權限）"
  echo "FAILED: cost/budgets :: reason=未取得帳單帳戶（未連結帳單或無 billing.resourceAssociations.list 權限） :: gcloud billing budgets list" >> "$ERRLOG"
fi

# Recommender：GCP 獨有的唯讀建議 API。沒有成本明細時，這是成本／效能支柱的主要量化依據。
# 逐 recommender × location 查詢；location 從已掃到的資源推導（見下方 write_locations）。
echo "=== Recommender（閒置資源／規格建議）==="
# 先算出實際有資源的 zone / region，避免對全部 GCP 位置盲掃
{
  jq -r '.[].zone // empty' "$DATA/compute/instances.json" 2>/dev/null
  jq -r '.[].zone // empty' "$DATA/compute/disks.json" 2>/dev/null
} | sed 's|.*/||' | sort -u > "$DATA/active-zones.txt"

# ⚠️ 子網不能直接拿來推導區域：**自動模式（auto mode）VPC 會在「每一個」GCP 區域自動建一個子網**，
#    直接取 subnets[].region 會得到全部 40+ 個區域（2026-07-21 首次實跑就這樣，Recommender
#    因此多跑了上百次查詢）。因此只採用「非自動模式網路」的子網區域，其餘一律看實際資源。
AUTO_NETS="$(jq -r '[.[] | select(.autoCreateSubnetworks == true) | .name] | join("|")' \
             "$DATA/network/networks.json" 2>/dev/null || true)"
{
  if [ -n "${AUTO_NETS:-}" ]; then
    jq -r --arg auto "$AUTO_NETS" \
      '[.[] | select((.network | split("/") | last) as $n | ($auto | split("|") | index($n)) == null)
        | .region] | .[]' "$DATA/network/subnets.json" 2>/dev/null
  else
    jq -r '.[].region // empty' "$DATA/network/subnets.json" 2>/dev/null
  fi
  jq -r '.[].region // empty' "$DATA/network/addresses.json" 2>/dev/null
  jq -r '.[].region // empty' "$DATA/network/routers.json" 2>/dev/null
  jq -r '.[].region // empty' "$DATA/lb/forwarding-rules.json" 2>/dev/null
  jq -r '.[].region // empty' "$DATA/db/redis-instances.json" 2>/dev/null
  jq -r '.[].region // empty' "$DATA/db/sql-instances.json" 2>/dev/null
  sed -E 's/-[a-z]$//' "$DATA/active-zones.txt"
} | sed 's|.*/||' | sed '/^$/d' | sort -u > "$DATA/active-regions.txt"
echo "有資源的 zone: $(tr '\n' ' ' < "$DATA/active-zones.txt")"
echo "有資源的 region: $(tr '\n' ' ' < "$DATA/active-regions.txt")"

while IFS= read -r Z; do
  [ -z "$Z" ] && continue
  run "cost/recommender/$Z-idle-vm" recommender recommendations list \
      --location "$Z" --recommender google.compute.instance.IdleResourceRecommender "${P[@]}"
  run "cost/recommender/$Z-vm-rightsizing" recommender recommendations list \
      --location "$Z" --recommender google.compute.instance.MachineTypeRecommender "${P[@]}"
  run "cost/recommender/$Z-idle-disk" recommender recommendations list \
      --location "$Z" --recommender google.compute.disk.IdleResourceRecommender "${P[@]}"
done < "$DATA/active-zones.txt"
while IFS= read -r R; do
  [ -z "$R" ] && continue
  run "cost/recommender/$R-idle-address" recommender recommendations list \
      --location "$R" --recommender google.compute.address.IdleResourceRecommender "${P[@]}"
  run "cost/recommender/$R-idle-sql" recommender recommendations list \
      --location "$R" --recommender google.cloudsql.instance.IdleRecommender "${P[@]}"
done < "$DATA/active-regions.txt"
run "cost/recommender/global-iam-policy" recommender recommendations list \
    --location global --recommender google.iam.policy.Recommender "${P[@]}"

# 逐區域的 KMS keyring（keyrings list 的 --location global 只涵蓋全域 keyring）
while IFS= read -r R; do
  [ -z "$R" ] && continue
  run "ops/kms-keyrings-$R" kms keyrings list --location "$R" "${P[@]}"
done < "$DATA/active-regions.txt"

# ── 掃描中繼資料 ─────────────────────────────────────────────────────
NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
METRICS_START="$(date -u -v-14d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-14 days' +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg project "$PROJECT" \
      --arg project_number "$PROJECT_NUMBER" \
      --arg account "$ACTIVE_ACCOUNT" \
      --arg cred_check "$CRED_CHECK" \
      --arg billing "${BILLING_ACCOUNT:-}" \
      --arg time "$NOW_UTC" \
      --arg regions "$(tr '\n' ' ' < "$DATA/active-regions.txt")" \
      --arg zones "$(tr '\n' ' ' < "$DATA/active-zones.txt")" \
      --arg period "$PERIOD" \
      --arg report_type "$REPORT_TYPE" \
      --arg target_start "$TARGET_START" \
      --arg target_end "$TARGET_END" \
      --arg metrics_start "$METRICS_START" \
      --arg metrics_end "$NOW_UTC" \
      '{project: $project, project_number: $project_number, identity: $account,
        credential_check: $cred_check, billing_account: $billing,
        scanned_at: $time, regions: $regions, zones: $zones,
        period: $period, report_type: $report_type,
        report_period: {start: $target_start, end: $target_end},
        metrics_window: {start: $metrics_start, end: $metrics_end}}' > "$DATA/scan-meta.json"

# ── 確定性產生 data/inventory.md ─────────────────────────────────────
# 數量、服務啟用狀態、關鍵安全旗標一律由 jq 從原始 JSON 算出、直接寫檔，
# 不經 LLM 手抄，確保 inventory 與 data/ 完全一致（消除摘要與原始檔矛盾）。
jqlen() {  # $1=檔案  $2=jq 運算式  → 長度（檔不存在/錯誤時 0）
  [ -f "$1" ] && jq -r "try ((${2}) | length) catch 0" "$1" 2>/dev/null || echo 0
}

write_inventory() {
  local INV="$DATA/inventory.md"
  local n_net n_sub n_fw n_vm n_mig n_ig n_disk n_snap n_gke n_run n_fn n_ae n_lb n_be n_sql n_alloydb n_memcached n_bq n_bucket n_fs n_sa n_alert n_zone n_pstopic n_pssub
  n_net="$(jqlen "$DATA/network/networks.json" '.')"
  n_sub="$(jqlen "$DATA/network/subnets.json" '.')"
  n_fw="$(jqlen "$DATA/network/firewall-rules.json" '.')"
  n_vm="$(jqlen "$DATA/compute/instances.json" '.')"
  n_mig="$(jqlen "$DATA/compute/instance-groups.json" '.')"
  n_ig="$(jqlen "$DATA/compute/instance-groups-all.json" '.')"
  n_disk="$(jqlen "$DATA/compute/disks.json" '.')"
  n_snap="$(jqlen "$DATA/compute/snapshots.json" '.')"
  n_gke="$(jqlen "$DATA/compute/gke-clusters.json" '.')"
  n_run="$(jqlen "$DATA/compute/run-services.json" '.')"
  n_fn="$(jqlen "$DATA/compute/functions.json" '.')"
  n_ae="$(jqlen "$DATA/appengine/services.json" '.')"
  n_lb="$(jqlen "$DATA/lb/forwarding-rules.json" '.')"
  n_be="$(jqlen "$DATA/lb/backend-services.json" '.')"
  n_sql="$(jqlen "$DATA/db/sql-instances.json" '.')"
  n_alloydb="$(jqlen "$DATA/db/alloydb-clusters.json" '.')"
  n_memcached="$(jqlen "$DATA/db/memcached-instances.json" '.')"
  n_bq="$(jqlen "$DATA/bigquery/datasets.json" '.')"
  n_pstopic="$(jqlen "$DATA/pubsub/topics.json" '.')"
  n_pssub="$(jqlen "$DATA/pubsub/subscriptions.json" '.')"
  n_bucket="$(jqlen "$DATA/storage/buckets.json" '.')"
  n_fs="$(jqlen "$DATA/storage/filestore-instances.json" '.')"
  n_sa="$(jqlen "$DATA/global/iam-service-accounts.json" '.')"
  n_alert="$(jqlen "$DATA/ops/monitoring-policies.json" '.')"
  n_zone="$(jqlen "$DATA/ops/dns-zones.json" '.')"

  {
    echo "# 資源盤點摘要"
    echo
    echo "> 本檔的數量與啟用狀態由 \`.claude/skills/report-gcp/scripts/scan.sh\` 以 jq 從 \`data/\` 原始 JSON"
    echo "> 確定性產生，保證與原始檔一致；分析 agent 若需明細請直接讀對應 JSON 或 \`data/digest/\`。"
    echo
    echo "- 專案：${PROJECT}（編號 ${PROJECT_NUMBER}）"
    echo "- 掃描身分：${ACTIVE_ACCOUNT}（唯讀自檢：${CRED_CHECK}）"
    echo "- 掃描時間：$(jq -r .scanned_at "$DATA/scan-meta.json")"
    echo "- 有資源的區域：$(tr '\n' ' ' < "$DATA/active-regions.txt")"
    echo "- 報告期別：${PERIOD} / ${REPORT_TYPE}"
    echo "- 帳單帳戶：${BILLING_ACCOUNT:-（未取得）}"
    echo
    echo "## 資源數量"
    echo
    echo "| 資源 | 數量 |"
    echo "|---|---:|"
    echo "| VPC 網路 | $n_net |"
    echo "| 子網路 | $n_sub |"
    echo "| 防火牆規則 | $n_fw |"
    echo "| Compute Engine VM | $n_vm |"
    echo "| 受管執行個體群組 (MIG) | $n_mig |"
    # 全部群組（含未受管）——負載平衡器的後端常是未受管群組，只看 MIG 會漏掉
    echo "| 執行個體群組（全部，含未受管） | $n_ig |"
    echo "| 永久磁碟 | $n_disk |"
    echo "| 磁碟快照 | $n_snap |"
    echo "| GKE 叢集 | $n_gke |"
    echo "| Cloud Run 服務 | $n_run |"
    echo "| Cloud Functions | $n_fn |"
    echo "| App Engine 服務 | $n_ae |"
    echo "| 轉送規則（負載平衡前端） | $n_lb |"
    echo "| 後端服務 | $n_be |"
    echo "| Cloud SQL 執行個體 | $n_sql |"
    echo "| AlloyDB cluster | $n_alloydb |"
    echo "| Memorystore Memcached 執行個體 | $n_memcached |"
    echo "| BigQuery dataset | $n_bq |"
    echo "| Pub/Sub topic | $n_pstopic |"
    echo "| Pub/Sub subscription | $n_pssub |"
    echo "| Cloud Storage 值區 | $n_bucket |"
    echo "| Filestore 執行個體 | $n_fs |"
    echo "| 服務帳戶 | $n_sa |"
    echo "| Cloud Monitoring 告警政策 | $n_alert |"
    echo "| Cloud DNS 區域 | $n_zone |"
    echo
    echo "## 偵測與治理啟用狀態"
    echo
    echo "| 項目 | 狀態 |"
    echo "|---|---|"
    local n_sink n_pol n_armor n_uptime
    n_sink="$(jqlen "$DATA/ops/logging-sinks.json" '.')"
    n_pol="$(jqlen "$DATA/global/org-policies.json" '.')"
    n_armor="$(jqlen "$DATA/lb/security-policies.json" '.')"
    n_uptime="$(jqlen "$DATA/ops/uptime-checks.json" '.')"
    echo "| Cloud Logging 匯出 sink | $( [ "${n_sink:-0}" -gt 0 ] && echo "設定 ${n_sink} 個" || echo "未設定（僅預設 _Default／_Required）" ) |"
    echo "| Cloud Monitoring 告警政策 | $( [ "${n_alert:-0}" -gt 0 ] && echo "設定 ${n_alert} 個" || echo "**未設定**" ) |"
    echo "| Uptime check | $( [ "${n_uptime:-0}" -gt 0 ] && echo "設定 ${n_uptime} 個" || echo "未設定" ) |"
    echo "| Cloud Armor 安全政策 | $( [ "${n_armor:-0}" -gt 0 ] && echo "設定 ${n_armor} 個" || echo "未設定" ) |"
    echo "| 組織政策（專案層） | $( [ "${n_pol:-0}" -gt 0 ] && echo "${n_pol} 條" || echo "未設定或無讀取權限" ) |"
    echo
    echo "## Cloud Storage 值區關鍵旗標"
    echo
    # ⚠️ `gcloud storage buckets list` 回 snake_case、JSON API 回 camelCase，**兩種都要接**；
    #    只寫 camelCase 會讓 enforced/true 印成「未設定／未啟用」——結論相反（見 digest.sh 同段註解）
    echo "| 值區 | 位置 | 公開存取防護 (PAP) | 統一值區層級存取 | 版本控制 | 生命週期 | Autoclass | CMEK |"
    echo "|---|---|---|---|---|---|---|---|"
    jq -r 'try (.[] | "| \(.name) | \(.location // "?") | \(.public_access_prevention // .iamConfiguration.publicAccessPrevention // "⚠️ 欄位無法解析") | \(if (.uniform_bucket_level_access // .iamConfiguration.uniformBucketLevelAccess.enabled) == true then "啟用" else "**未啟用**" end) | \(if (.versioning_enabled // .versioning.enabled) == true then "啟用" else "未啟用" end) | \(if ((.lifecycle_config.rule // .lifecycle.rule // []) | length) > 0 then "有" else "未設定" end) | \(if (.autoclass.enabled // false) then "啟用" else "未啟用" end) | \(if (.default_kms_key // .encryption.defaultKmsKeyName) then "有" else "Google 管理" end) |") catch empty' \
      "$DATA/storage/buckets.json" 2>/dev/null
    echo
    echo "## Cloud SQL 關鍵旗標"
    echo
    echo "| 執行個體 | 版本 | 公開 IP | 授權網路含 0.0.0.0/0 | 高可用 | 自動備份 | 需要 SSL | 刪除保護 |"
    echo "|---|---|---|---|---|---|---|---|"
    jq -r 'try (.[] |
      "| \(.name) | \(.databaseVersion // "?") | \(if ((.ipAddresses // []) | any(.type == "PRIMARY")) then "**是**" else "否" end) | \(if ((.settings.ipConfiguration.authorizedNetworks // []) | any(.value == "0.0.0.0/0")) then "**是**" else "否" end) | \(.settings.availabilityType // "?") | \(if .settings.backupConfiguration.enabled then "啟用" else "**未啟用**" end) | \(.settings.ipConfiguration.requireSsl // .settings.ipConfiguration.sslMode // "未設定" | tostring) | \(.settings.deletionProtectionEnabled // false | tostring) |") catch empty' \
      "$DATA/db/sql-instances.json" 2>/dev/null
    echo
    echo "## 對外開放的防火牆規則（來源含 0.0.0.0/0 的 allow 規則）"
    echo
    echo "> 「規則存在」不等於「真的有機器套用」——GCP 防火牆是標籤／服務帳戶導向。"
    echo "> 實際暴露面請讀 \`data/digest/network-facts.md\`（已把規則 × VM 標籤 × 外部 IP 交叉算出）。"
    echo
    jq -r 'try (.[] | select(.direction == "INGRESS" and ((.sourceRanges // []) | any(. == "0.0.0.0/0")) and (.allowed // []) != [] and (.disabled != true)) |
      "- `\(.name)`（網路 \(.network | split("/") | last)）allow: " +
      ([.allowed[] | .IPProtocol + (if (.ports // []) == [] then ":all" else ":" + (.ports | join(",")) end)] | join(" ")) +
      (if (.targetTags // []) == [] and (.targetServiceAccounts // []) == [] then "　→ **套用到全網路所有 VM**" else "　→ 目標標籤: " + (((.targetTags // []) + (.targetServiceAccounts // [])) | join(",")) end)) catch empty' \
      "$DATA/network/firewall-rules.json" 2>/dev/null
    echo
    echo "## 資料缺口（掃描失敗項目）"
    echo
    if [ -s "$ERRLOG" ] && grep -q '^FAILED' "$ERRLOG"; then
      grep '^FAILED' "$ERRLOG" | sed 's/^FAILED: /- /'
    else
      echo "- （無）"
    fi
  } > "$INV"
  echo "已產生 data/inventory.md（確定性）"
}
write_inventory

echo ""
echo "=== 掃描完成 ==="
echo "資料位置: $DATA"
FAILS="$(grep -c '^FAILED' "$ERRLOG" 2>/dev/null || true)"
echo "失敗項目: ${FAILS}（詳見 data/scan-errors.log，多為 API 未啟用或權限不足，屬預期）"

# 精簡樣板欄位多的掃描資料到 data/digest/（純本機 jq，不呼叫 GCP）。
# 原始 JSON 保持完整不動，digest 只是它的確定性投影。
echo ""
bash "$SKILL_DIR/scripts/digest.sh"
