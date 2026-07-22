#!/usr/bin/env bash
# 查詢 Google Cloud Billing Catalog API 的官方牌價，取代舊有的 WebFetch 定價頁做法。
#
# 用法（從專案根目錄執行）：
#   bash .claude/skills/report-gcp/scripts/pricing-lookup.sh \
#     --service "Compute Engine" --sku-filter "Balanced PD Capacity" --region asia-east1
#   bash .claude/skills/report-gcp/scripts/pricing-lookup.sh --service-id 6F81-5844-456A --sku-filter "..."
#   bash .claude/skills/report-gcp/scripts/pricing-lookup.sh --list-services   # 除錯用：列出全部服務名稱與 ID
#   bash .claude/skills/report-gcp/scripts/pricing-lookup.sh --selftest       # 離線測換算/比對純函式，不連網
#
# 退出碼（agent 據此判斷如何寫發現）：
#   0 = 查到 SKU，stdout 印出精簡 JSON（一行一筆）
#   3 = API 呼叫成功，但查無符合的服務/SKU → 該金額應標「估算」，不可寫成查到的牌價
#   2 = 認證或 API 呼叫失敗（token 取不到、HTTP 非 2xx、網路問題）→ 列為資料缺口
#
# 為什麼不做幣別轉換：Cloud Billing Catalog API 不帶 currencyCode 參數時預設回美金（USD）；
# 本腳本一律回 USD，不做任何二次換算——報告若要呈現其他幣別是報告呈現層的事，不是本腳本的責任。
#
# 為什麼 service ID 對照表要進版控（`references/pricing-service-ids.json`）而不是 data/ 底下：
# 這份表存的是 Google 全域產品目錄代碼（如 Compute Engine = 6F81-5844-456A），跟任何 GCP 專案或客戶
# 資料無關、不含機密；`data/` 每次重掃前會被清掉，放那裡會讓已經查過的服務又要重查一次，
# 白白浪費「用過就記得」的價值。SKU 單價本身才會變動，所以單價快取仍然放在 data/cost/pricing-cache/。
#
# 為什麼不留「查不到就退回 WebFetch」的路：反覆 WebFetch 同一個定價頁、甚至抓非官方部落格，
# 正是這支腳本要根除的根因（2026-07-22 實測：cost-optimizer 單次因此多花約 800 萬 token）。
# 查不到就是查不到，改用估算並標註，不允許用不可靠的網頁抓取硬湊一個數字出來。

set -u
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="$PWD"
if [ ! -d "$WORK_ROOT/.claude/skills/report-gcp" ]; then
  echo "錯誤：請從裝有本 skill 的專案根目錄執行（cwd 下找不到 .claude/skills/report-gcp）" >&2
  exit 2
fi
SERVICE_IDS_FILE="$SKILL_DIR/references/pricing-service-ids.json"
CACHE_DIR="$WORK_ROOT/data/cost/pricing-cache"
SCAN_META="$WORK_ROOT/data/scan-meta.json"
API="https://cloudbilling.googleapis.com/v1"

# ── 純函式（--selftest 離線測這幾個，不連網）───────────────────────────
# 單價換算：取「付費階」（tieredRates 最後一階），不是 [0]——首階常是免費額度，
# 直接取 [0] 會在有免費階的 SKU 上把單價算成 0。
PRICE_FILTER='(.pricingInfo[0].pricingExpression.tieredRates | last) as $t
  | (($t.unitPrice.units // "0" | tonumber) + (($t.unitPrice.nanos // 0) / 1000000000))'

# region/zone 雙態比對：Regional SKU 的 serviceRegions[] 存地區字串（asia-east1），
# 但單一可用區版 SKU 可能存可用區字串（asia-east1-b）。只比對地區字串精確相等會漏掉後者。
REGION_MATCH_FILTER='(.serviceRegions // []) | any(. == $r or startswith($r + "-"))'

selftest() {
  local fail=0

  # 案例 1：單階定價，直接換算
  local out
  out="$(echo '{"pricingInfo":[{"pricingExpression":{"tieredRates":[{"unitPrice":{"units":"0","nanos":200000000}}]}}]}' \
    | jq -r "$PRICE_FILTER")"
  [ "$out" = "0.2" ] || { echo "FAIL 單階換算：預期 0.2，得到 $out"; fail=1; }

  # 案例 2：多階定價（首階免費額度 units=0/nanos=0，需取最後一階付費價，不能取 [0]）
  out="$(echo '{"pricingInfo":[{"pricingExpression":{"tieredRates":[{"unitPrice":{"units":"0","nanos":0}},{"unitPrice":{"units":"1","nanos":500000000}}]}}]}' \
    | jq -r "$PRICE_FILTER")"
  [ "$out" = "1.5" ] || { echo "FAIL 多階換算：預期 1.5（取付費階非 [0]），得到 $out"; fail=1; }

  # 案例 3：region 字串完全相等 → 命中
  out="$(echo '{"serviceRegions":["asia-east1","us-central1"]}' \
    | jq -r --arg r "asia-east1" "$REGION_MATCH_FILTER")"
  [ "$out" = "true" ] || { echo "FAIL region 精確比對：預期 true，得到 $out"; fail=1; }

  # 案例 4：zone 字串以 region 為前綴 → 命中（單一可用區 SKU 的情況）
  out="$(echo '{"serviceRegions":["asia-east1-b"]}' \
    | jq -r --arg r "asia-east1" "$REGION_MATCH_FILTER")"
  [ "$out" = "true" ] || { echo "FAIL region/zone 前綴比對：預期 true，得到 $out"; fail=1; }

  # 案例 5：不相干地區 → 不命中
  out="$(echo '{"serviceRegions":["us-central1"]}' \
    | jq -r --arg r "asia-east1" "$REGION_MATCH_FILTER")"
  [ "$out" = "false" ] || { echo "FAIL region 不相干：預期 false，得到 $out"; fail=1; }

  if [ "$fail" -eq 0 ]; then
    echo "selftest 全數通過（5/5，不連網）"
    exit 0
  else
    echo "selftest 有失敗項目，見上方 FAIL"
    exit 1
  fi
}

# ── 參數解析 ─────────────────────────────────────────────────────────
SERVICE_NAME=""
SERVICE_ID=""
SKU_FILTER=""
REGION=""
REFRESH=0
MODE="query"

while [ $# -gt 0 ]; do
  case "$1" in
    --service) SERVICE_NAME="$2"; shift 2 ;;
    --service-id) SERVICE_ID="$2"; shift 2 ;;
    --sku-filter) SKU_FILTER="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --refresh) REFRESH=1; shift ;;
    --list-services) MODE="list-services"; shift ;;
    --selftest) selftest ;;
    *) echo "未知參數：$1" >&2; exit 2 ;;
  esac
done

TOKEN="$(gcloud auth print-access-token 2>/dev/null || true)"
if [ -z "$TOKEN" ]; then
  echo "錯誤：無法取得 gcloud access token（憑證未登入或已過期）" >&2
  exit 2
fi

# services.list 分頁抓取所有頁，把每頁的 services 陣列串接輸出到 stdout（給呼叫端用 jq 處理）。
# 實測 Compute Engine 排在第 4 頁（每頁 200 筆）才出現，因此必須翻頁，不能只查第一頁。
#
# 累積結果一律用暫存檔＋兩檔案版 jq 合併，不把累積內容當 --argjson/--arg 的字串參數傳——
# 累積到一定筆數後字串會超過 OS 的指令列參數長度上限，導致 jq 直接被 shell 擋下
# "Argument list too long"（實測 skus.list 用 --argjson 傳累積結果就踩到這個）。
fetch_all_services() {
  local page_token="" url body http_code
  local acc; acc="$(mktemp)"; echo '[]' > "$acc"
  local merged
  local i=0
  while [ "$i" -lt 20 ]; do
    i=$((i + 1))
    url="$API/services?pageSize=200"
    [ -n "$page_token" ] && url="$url&pageToken=$page_token"
    body="$(mktemp)"
    http_code="$(curl -sS -o "$body" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$url" 2>/dev/null || echo "000")"
    if [ "$http_code" != "200" ]; then
      echo "錯誤：services.list 呼叫失敗（HTTP ${http_code}）" >&2
      cat "$body" >&2
      rm -f "$body" "$acc"
      return 2
    fi
    merged="$(mktemp)"
    jq -c -s '.[0] + (.[1].services // [])' "$acc" "$body" > "$merged"
    mv "$merged" "$acc"
    page_token="$(jq -r '.nextPageToken // empty' "$body")"
    rm -f "$body"
    [ -z "$page_token" ] && break
  done
  cat "$acc"
  rm -f "$acc"
  return 0
}

if [ "$MODE" = "list-services" ]; then
  services_json="$(fetch_all_services)" || exit 2
  echo "$services_json" | jq -r '.[] | "\(.serviceId)\t\(.displayName)"'
  exit 0
fi

if [ -z "$SKU_FILTER" ]; then
  echo "錯誤：需要 --sku-filter（要查的 SKU 描述關鍵字/regex）" >&2
  exit 2
fi

# ── 解析 service ID：直接指定 > 對照表命中 > 分頁查找後寫回對照表 ──────
if [ -z "$SERVICE_ID" ]; then
  if [ -z "$SERVICE_NAME" ]; then
    echo "錯誤：需要 --service 或 --service-id 其中之一" >&2
    exit 2
  fi
  SERVICE_ID="$(jq -r --arg s "$SERVICE_NAME" '.services[$s] // empty' "$SERVICE_IDS_FILE" 2>/dev/null || true)"
  if [ -z "$SERVICE_ID" ]; then
    echo "對照表沒有「${SERVICE_NAME}」，分頁查找 Cloud Billing 目錄……" >&2
    services_json="$(fetch_all_services)" || exit 2
    SERVICE_ID="$(echo "$services_json" | jq -r --arg s "$SERVICE_NAME" \
      '[.[] | select(.displayName == $s)][0].serviceId // empty')"
    if [ -z "$SERVICE_ID" ]; then
      echo "查無服務「${SERVICE_NAME}」（已翻完全部分頁）" >&2
      exit 3
    fi
    # 寫回對照表（先寫暫存檔再 mv，避免中途失敗留下半份檔案）
    tmp_file="$(mktemp)"
    jq --arg s "$SERVICE_NAME" --arg id "$SERVICE_ID" '.services[$s] = $id' "$SERVICE_IDS_FILE" > "$tmp_file" \
      && mv "$tmp_file" "$SERVICE_IDS_FILE"
    echo "已找到並寫回對照表：$SERVICE_NAME = $SERVICE_ID" >&2
  fi
fi

# ── SKU 單價快取：同一次報告執行內快取一次就夠，跨期（scanned_at 不同）一律重查 ──
mkdir -p "$CACHE_DIR"
SCANNED_AT="$(jq -r '.scanned_at // empty' "$SCAN_META" 2>/dev/null || true)"
SLUG="$(printf '%s__%s__%s' "$SERVICE_ID" "$SKU_FILTER" "${REGION:-any}" \
  | tr -c 'A-Za-z0-9_-' '_' | cut -c1-150)"
CACHE_FILE="$CACHE_DIR/$SLUG.json"

if [ "$REFRESH" -ne 1 ] && [ -f "$CACHE_FILE" ]; then
  CACHED_SCANNED_AT="$(jq -r '.scanned_at // empty' "$CACHE_FILE" 2>/dev/null || true)"
  if [ -n "$SCANNED_AT" ] && [ "$CACHED_SCANNED_AT" = "$SCANNED_AT" ]; then
    echo "（命中同期快取：${CACHE_FILE}）" >&2
    jq -c '.results[]' "$CACHE_FILE"
    [ "$(jq '.results | length' "$CACHE_FILE")" -eq 0 ] && exit 3
    exit 0
  fi
fi

# ── skus.list 分頁查詢並過濾（不能只查第一頁就判定查無，理由同 services.list）──
# 累積結果一律走暫存檔＋兩檔案版 jq 合併（理由同 fetch_all_services 的註解：
# 累積內容一旦變大，用 --argjson 傳字串參數會撞上 OS 指令列長度上限，
# 實測用 "vCPU" 這種寬鬆關鍵字查 Cloud SQL 就踩到 "Argument list too long"）。
page_token=""
matched_acc="$(mktemp)"; echo '[]' > "$matched_acc"
i=0
http_failed=0
while [ "$i" -lt 20 ]; do
  i=$((i + 1))
  url="$API/services/$SERVICE_ID/skus?pageSize=5000"
  [ -n "$page_token" ] && url="$url&pageToken=$page_token"
  body="$(mktemp)"
  http_code="$(curl -sS -o "$body" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$url" 2>/dev/null || echo "000")"
  if [ "$http_code" != "200" ]; then
    echo "錯誤：skus.list 呼叫失敗（HTTP ${http_code}）" >&2
    cat "$body" >&2
    rm -f "$body"
    http_failed=1
    break
  fi
  page_matched="$(mktemp)"
  if [ -n "$REGION" ]; then
    jq -c --arg f "$SKU_FILTER" --arg r "$REGION" \
      '[.skus[]? | select(.description | test($f; "i")) | select('"$REGION_MATCH_FILTER"')]' "$body" > "$page_matched"
  else
    jq -c --arg f "$SKU_FILTER" \
      '[.skus[]? | select(.description | test($f; "i"))]' "$body" > "$page_matched"
  fi
  merged="$(mktemp)"
  jq -c -s '.[0] + .[1]' "$matched_acc" "$page_matched" > "$merged"
  mv "$merged" "$matched_acc"
  rm -f "$page_matched"
  page_token="$(jq -r '.nextPageToken // empty' "$body")"
  rm -f "$body"
  [ -z "$page_token" ] && break
done

if [ "$http_failed" -eq 1 ]; then
  rm -f "$matched_acc"
  exit 2
fi

# 精簡輸出：只留 agent 需要的欄位，換算單價，附 skuId 供對回證據。
# 寫進暫存檔而不是 shell 變數——理由同上：寬鬆關鍵字（如 "vCPU"）配對到的筆數可能不小，
# 若之後又用 --argjson 傳字串參數組 CACHE_FILE 會再踩一次 "Argument list too long"。
results_file="$(mktemp)"
jq -c --arg cache "$CACHE_FILE" '[.[] | {
  skuId: .skuId,
  description: .description,
  unitPriceUSD: ((.pricingInfo[0].pricingExpression.tieredRates | last) as $t
    | (($t.unitPrice.units // "0" | tonumber) + (($t.unitPrice.nanos // 0) / 1000000000))),
  usageUnit: .pricingInfo[0].pricingExpression.usageUnit,
  serviceRegions: .serviceRegions,
  cacheFile: $cache
}]' "$matched_acc" > "$results_file"
rm -f "$matched_acc"

# 存完整原始比對結果＋精簡結果，戳上 scanned_at 供下次比對是否同期
# --slurpfile 讀實體檔案（非指令列字串參數），累積結果再大也不會撞 OS 參數長度上限。
jq -n --slurpfile r "$results_file" --arg scanned_at "$SCANNED_AT" \
  --arg service_id "$SERVICE_ID" --arg sku_filter "$SKU_FILTER" --arg region "${REGION:-}" \
  '{scanned_at: $scanned_at, service_id: $service_id, sku_filter: $sku_filter, region: $region, results: $r[0]}' \
  > "$CACHE_FILE"

count="$(jq 'length' "$results_file")"
if [ "$count" -eq 0 ]; then
  rm -f "$results_file"
  echo "查無符合「${SKU_FILTER}」$( [ -n "$REGION" ] && echo "（地區 ${REGION}）" )的 SKU（已翻完全部分頁）" >&2
  exit 3
fi

jq -c '.[]' "$results_file"
rm -f "$results_file"
exit 0
