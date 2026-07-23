#!/usr/bin/env bash
# 掃描資料精簡（本機 jq，確定性；不呼叫 GCP、不需要憑證）
#
# 用法（從專案根目錄）：bash .claude/skills/report-gcp/scripts/digest.sh （scan.sh 末尾自動呼叫；也可單獨重跑）
#
# 為什麼不在 scan.sh 用 gcloud 的 --format 裁切：
#   那是「擷取時破壞、不可逆」——欄位判斷錯了只能重掃專案，但重掃時專案狀態已變，
#   會破壞報告「期別＝已結束週期的快照」的稽核軌跡。且 --format 投影欄位名打錯時 gcloud
#   靜默回空值且 exit 0，run() 完全接不住。
#   改由本機 jq 從完整的 data/ 衍生 data/digest/：判斷錯了改 jq 重跑即可，秒級、離線、
#   可重現，原始證據永遠保留。
#
# ⚠️ 必要欄位斷言：每個 digest 產出後會斷言關鍵證據欄位仍存在，少一個就 exit 1。
#    這些欄位是發現的唯一證據來源，刪掉不會讓 agent 寫「資料缺口」，而是讓它推出相反的結論
#    （例：backend-services 的 securityPolicy 消失 → 從「未掛 Cloud Armor」變成「沒問題」）。
#    新增檢查重點而需要新欄位時，補進投影並在此加斷言。
#
# 📌 架構取捨：本檔只放**純 jq 投影**。「衍生表／跨檔關聯」一律加在 network-facts.py（python），
#    不要在這裡新增 bash 產表段落（那會讓本檔逐漸長成 jq/bash/grep 的多語言拼接）。

set -u
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_ROOT="$PWD"
if [ ! -d "$WORK_ROOT/.claude/skills/report-gcp" ]; then
  echo "錯誤：請從裝有本 skill 的專案根目錄執行（cwd 下找不到 .claude/skills/report-gcp）" >&2
  exit 1
fi
DATA="$WORK_ROOT/data"
DIGEST="$DATA/digest"

# 沒有掃描資料就直接失敗——若放任 if [ -f ] 守衛逐一跳過，腳本會什麼都沒做卻回報成功，
# 正是「靜默無作為」的失敗模式。
if [ ! -f "$DATA/scan-meta.json" ]; then
  echo "錯誤：找不到 $DATA/scan-meta.json，請先執行 bash .claude/skills/report-gcp/scripts/scan.sh" >&2
  exit 1
fi

mkdir -p "$DIGEST"
FAIL=0
MADE=0

# assert <說明> <jq 條件> <檔案>
assert() {
  if jq -e "$2" "$3" > /dev/null 2>&1; then
    echo "    ✅ $1"
  else
    echo "    ❌ 斷言失敗：$1（$3）" >&2
    FAIL=$((FAIL + 1))
  fi
}

echo "=== 產生 data/digest/ ==="

# ── Compute 執行個體：原始 JSON 每台 VM 有 60+ 欄樣板 ────────────────────
# 必留證據：networkInterfaces[].accessConfigs（外部 IP＝實際暴露面的必要條件）、
#           tags.items（防火牆規則靠標籤生效，少了它「規則 × VM」關聯就算不出來）、
#           serviceAccounts[].scopes（cloud-platform 全域 scope 是常見的過度授權）、
#           shieldedInstanceConfig、status、machineType、deletionProtection
SRC="$DATA/compute/instances.json"
if [ -f "$SRC" ]; then
  jq '[.[] | {
    name, id, status, zone: (.zone | split("/") | last),
    machineType: (.machineType | split("/") | last),
    creationTimestamp, deletionProtection, canIpForward,
    tags: (.tags.items // []),
    labels: (.labels // {}),
    serviceAccounts: [(.serviceAccounts // [])[] | {email, scopes}],
    shielded: (.shieldedInstanceConfig // {}),
    confidential: (.confidentialInstanceConfig.enableConfidentialCompute // false),
    metadataKeys: [((.metadata.items // [])[] | .key)],
    networkInterfaces: [(.networkInterfaces // [])[] | {
      network: (.network | split("/") | last),
      subnetwork: ((.subnetwork // "") | split("/") | last),
      networkIP,
      accessConfigs: [((.accessConfigs // [])[] | {type, natIP})]
    }],
    disks: [(.disks // [])[] | {deviceName, boot, autoDelete, type,
      source: ((.source // "") | split("/") | last),
      diskEncryptionKey: (if .diskEncryptionKey then "CMEK/CSEK" else "Google 管理" end)}],
    scheduling: {preemptible: (.scheduling.preemptible // false),
                 automaticRestart: (.scheduling.automaticRestart // null),
                 provisioningModel: (.scheduling.provisioningModel // null)}
  }]' "$SRC" > "$DIGEST/compute-instances.json"
  echo "  compute-instances.json  $(wc -c < "$SRC") → $(wc -c < "$DIGEST/compute-instances.json") 位元組"
  MADE=$((MADE + 1))
  N="$(jq -r 'length' "$SRC")"
  D="$DIGEST/compute-instances.json"
  assert "VM 數一致（${N} 台）"      "length == $N" "$D"
  if [ "$N" -gt 0 ]; then
    assert "networkInterfaces.accessConfigs 保留（外部 IP 判斷）" \
           "[.[] | select((.networkInterfaces | length) > 0) | .networkInterfaces[] | select(has(\"accessConfigs\"))] | length > 0" "$D"
    assert "tags 保留（防火牆規則關聯）" "[.[] | select(has(\"tags\"))] | length == $N" "$D"
    assert "serviceAccounts 保留（scope 過度授權判斷）" "[.[] | select(has(\"serviceAccounts\"))] | length == $N" "$D"
  fi
fi

# ── 負載平衡與邊緣：Cloud CDN 與 Cloud Armor 是 backend-service 上的欄位 ──
# 必留證據：enableCDN（快取／效能）、securityPolicy（Cloud Armor 是否掛上＝WAF 缺口）、
#           logConfig（存取記錄是否開啟）、protocol／port、healthChecks（有無健康檢查）
SRC="$DATA/lb/backend-services.json"
if [ -f "$SRC" ]; then
  jq '[.[] | {
    name, description,
    protocol, portName, port,
    loadBalancingScheme,
    enableCDN: (.enableCDN // false),
    cdnPolicy: (.cdnPolicy.cacheMode // null),
    securityPolicy: (.securityPolicy // null),
    edgeSecurityPolicy: (.edgeSecurityPolicy // null),
    logConfig: (.logConfig // {}),
    sessionAffinity, timeoutSec,
    healthChecks: [((.healthChecks // [])[] | split("/") | last)],
    backends: [((.backends // [])[] | {group: ((.group // "") | split("/") | last),
                balancingMode, capacityScaler})],
    iap: (.iap.enabled // false)
  }]' "$SRC" > "$DIGEST/backend-services.json"
  echo "  backend-services.json  $(wc -c < "$SRC") → $(wc -c < "$DIGEST/backend-services.json") 位元組"
  MADE=$((MADE + 1))
  N="$(jq -r 'length' "$SRC")"
  D="$DIGEST/backend-services.json"
  assert "後端服務數一致（${N} 個）" "length == $N" "$D"
  if [ "$N" -gt 0 ]; then
    assert "securityPolicy 保留（Cloud Armor 缺口判斷）" "[.[] | select(has(\"securityPolicy\"))] | length == $N" "$D"
    assert "enableCDN 保留（快取判斷）"                  "[.[] | select(has(\"enableCDN\"))] | length == $N" "$D"
    assert "logConfig 保留（存取記錄判斷）"              "[.[] | select(has(\"logConfig\"))] | length == $N" "$D"
  fi
fi

# ── Cloud Run 服務網路投影 ────────────────────────────────────────────
# 來源：compute/run-detail/*-describe.json（scan.sh 逐服務 describe）。
# 必留證據：ingress（對外暴露面）、vpcAccess.{connector,egress,networkInterfaces}（路由進哪個 VPC）。
# ⚠️⚠️ 本專案 Cloud Run API 未啟用，這些欄位路徑**未經真實資料驗證**（同 GCS 值區踩過的
#      snake/camel 教訓）。沿用同一套防呆：抓不到 ingress／name 就印「⚠️ 欄位無法解析」並讓斷言
#      FAIL，**絕不可默默印「未設定」**——寧可斷言失敗逼人發現路徑錯了。ingress／vpcAccess
#      用雙路 fallback：v2（頂層 .ingress、.template.vpcAccess）與 v1 Knative（annotations）都試。
# ⚠️ ingress **必須正規化成單一 v2 詞彙**：v1 Knative annotation 的值是小寫短詞
#    （"all"／"internal"／"internal-and-cloud-load-balancing"），但下游 network-facts.py 與
#    build-diagram.js 只認 v2 enum（INGRESS_TRAFFIC_ALL 等）。不正規化的話，v1 風格、對外開放
#    （"all"）的服務不會被判成暴露面——確定性腳本靜默漏標暴露面，是本專案最不能接受的錯。
#    故此處把 v1 值對應成 v2；v2 值原樣保留；無法辨識的值（含 null→「欄位無法解析」）保留原字串，
#    落到既有防呆，絕不靜默吞掉。
# ⚠️ ingress 缺席（v1／v2 皆取不到）＝印「⚠️ 欄位無法解析」讓斷言 FAIL，這與下方 App Engine
#    「缺席＝合法預設 ALL、不 FAIL」是**刻意相反**的處理：Cloud Run v2 的 ingress 一定有值，
#    缺席代表 schema 假設錯了，寧可 loud-fail 逼人核對；App Engine 的 networkSettings 缺席則是
#    官方定義的合法預設（見該段註解）。方向不同是有意的，不是漏改。
RUN_DETAIL="$DATA/compute/run-detail"
if [ -d "$RUN_DETAIL" ] && ls "$RUN_DETAIL"/*-describe.json > /dev/null 2>&1; then
  jq -s '[.[] | {
    name: (.metadata.name // .name // "⚠️ 欄位無法解析"),
    ingress: ((.ingress
               // .metadata.annotations["run.googleapis.com/ingress"]
               // "⚠️ 欄位無法解析") as $raw |
              {
                "all": "INGRESS_TRAFFIC_ALL",
                "internal": "INGRESS_TRAFFIC_INTERNAL_ONLY",
                "internal-and-cloud-load-balancing": "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
              }[$raw] // $raw),
    vpcAccess: {
      connector: (.template.vpcAccess.connector
                  // .spec.template.metadata.annotations["run.googleapis.com/vpc-access-connector"]
                  // null),
      egress: (.template.vpcAccess.egress
               // .spec.template.metadata.annotations["run.googleapis.com/vpc-access-egress"]
               // null),
      networkInterfaces: (.template.vpcAccess.networkInterfaces // [])
    }
  }]' "$RUN_DETAIL"/*-describe.json > "$DIGEST/run-services.json"
  RN="$(ls "$RUN_DETAIL"/*-describe.json | wc -l | tr -d ' ')"
  echo "  run-services.json  ← ${RN} 個 describe"
  MADE=$((MADE + 1))
  D="$DIGEST/run-services.json"
  N="$(jq -r 'length' "$D")"
  assert "Cloud Run 服務數 > 0（${N}）" "length > 0" "$D"
  if grep -q '欄位無法解析' "$D"; then
    echo "    ❌ 斷言失敗：Cloud Run 的 name／ingress 欄位解析不出來（gcloud 輸出 schema 與假設不同），請修正 digest.sh 投影" >&2
    FAIL=$((FAIL + 1))
  else
    [ "$N" -gt 0 ] && echo "    ✅ name／ingress 欄位皆解析成功（未出現「欄位無法解析」）"
  fi
  # vpcAccess 三個子欄位的 key 必須都在（值可為 null，但缺 key 會讓 network-facts 讀不到）
  [ "$N" -gt 0 ] && assert "vpcAccess 結構保留（connector/egress/networkInterfaces）" \
    "[.[] | select(.vpcAccess | has(\"connector\") and has(\"egress\") and has(\"networkInterfaces\"))] | length == $N" "$D"
else
  echo "  run-services.json  略過（無 compute/run-detail/，Cloud Run API 未啟用或無服務）"
fi

# ── Cloud Functions 網路投影 ──────────────────────────────────────────
# 來源：compute/functions-detail/*-describe.json（scan.sh 逐函式 describe）。
# 2nd gen 底層即 Cloud Run，用 serviceConfig.{ingressSettings,vpcConnector}；1st gen 是舊 schema
# （頂層 ingressSettings／vpcConnector）。兩代欄位名不同，分開判斷並在 generation 欄註明是哪一代。
# ⚠️ 本專案 Functions API 未啟用，欄位路徑**未經真實資料驗證**；同樣加「欄位無法解析」防呆。
# ⚠️ Functions 的 ingress（ingressSettings）值域是 ALLOW_ALL／ALLOW_INTERNAL_ONLY／ALLOW_INTERNAL_AND_GCLB，
#    **與 Cloud Run 的 INGRESS_TRAFFIC_* enum 不同**，故此處不套用 Cloud Run 的正規化對應。目前
#    **Cloud Functions 尚未納入 network-facts.py 的對外開放判定**（serverless_paths 只吃 runs／App Engine，
#    不吃 functions）；日後要納入時，記得這裡的 ingress 值域與 Cloud Run 不同，需在判定端另立對應或先正規化。
FN_DETAIL="$DATA/compute/functions-detail"
if [ -d "$FN_DETAIL" ] && ls "$FN_DETAIL"/*-describe.json > /dev/null 2>&1; then
  jq -s '[.[] |
    (if (.serviceConfig or .buildConfig) then "2nd gen" else "1st gen" end) as $gen |
    {
      name: ((.name // "⚠️ 欄位無法解析") | split("/") | last),
      generation: $gen,
      ingress: (.serviceConfig.ingressSettings
                // .ingressSettings
                // "⚠️ 欄位無法解析"),
      vpcConnector: (.serviceConfig.vpcConnector
                     // .vpcConnector
                     // null),
      vpcConnectorEgressSettings: (.serviceConfig.vpcConnectorEgressSettings
                                   // .vpcConnectorEgressSettings // null)
    }]' "$FN_DETAIL"/*-describe.json > "$DIGEST/functions.json"
  FNN="$(ls "$FN_DETAIL"/*-describe.json | wc -l | tr -d ' ')"
  echo "  functions.json  ← ${FNN} 個 describe"
  MADE=$((MADE + 1))
  D="$DIGEST/functions.json"
  N="$(jq -r 'length' "$D")"
  assert "Cloud Functions 數 > 0（${N}）" "length > 0" "$D"
  if grep -q '欄位無法解析' "$D"; then
    echo "    ❌ 斷言失敗：Cloud Functions 的 name／ingress 欄位解析不出來，請修正 digest.sh 投影" >&2
    FAIL=$((FAIL + 1))
  else
    [ "$N" -gt 0 ] && echo "    ✅ name／ingress 欄位皆解析成功（未出現「欄位無法解析」）"
  fi
  [ "$N" -gt 0 ] && assert "vpcConnector 欄位保留（VPC 依賴判斷）" "[.[] | select(has(\"vpcConnector\"))] | length == $N" "$D"
else
  echo "  functions.json  略過（無 compute/functions-detail/，Cloud Functions API 未啟用或無函式）"
fi

# ── GKE 叢集網路投影 ──────────────────────────────────────────────────
# 來源：compute/gke-detail/*-describe.json（scan.sh 逐叢集 describe）。GKE v1 API 欄位穩定多年，
# 風險低，可直接照抓（本專案有 1 個叢集，此段欄位路徑已用真實 describe 驗證通過）。
# 必留證據：privateClusterConfig（私有節點／端點）、masterAuthorizedNetworksConfig（主控授權網段）、
#           ipAllocationPolicy.useIpAliases（VPC-native 判定）、networkConfig.{network,subnetwork}。
# ⚠️ enablePrivateNodes／masterIpv4CidrBlock／cidrBlocks 在非私有叢集會整個欄位缺席（實測本專案叢集
#    只有 enablePrivateEndpoint），故一律 // false／// null／// [] 補預設：缺席＝未啟用，不是解析失敗。
GKE_DETAIL="$DATA/compute/gke-detail"
if [ -d "$GKE_DETAIL" ] && ls "$GKE_DETAIL"/*-describe.json > /dev/null 2>&1; then
  jq -s '[.[] | {
    name,
    location: (.location // "?"),
    privateCluster: {
      enablePrivateNodes: (.privateClusterConfig.enablePrivateNodes // false),
      enablePrivateEndpoint: (.privateClusterConfig.enablePrivateEndpoint // false),
      masterIpv4CidrBlock: (.privateClusterConfig.masterIpv4CidrBlock // null),
      publicEndpoint: (.privateClusterConfig.publicEndpoint // null)
    },
    masterAuthorizedNetworks: {
      enabled: (.masterAuthorizedNetworksConfig.enabled // false),
      cidrBlocks: [((.masterAuthorizedNetworksConfig.cidrBlocks // [])[] | {cidrBlock, displayName})]
    },
    vpcNative: (.ipAllocationPolicy.useIpAliases // false),
    network: ((.networkConfig.network // .network // null) | if . then (. | split("/") | last) else null end),
    subnetwork: ((.networkConfig.subnetwork // .subnetwork // null) | if . then (. | split("/") | last) else null end)
  }]' "$GKE_DETAIL"/*-describe.json > "$DIGEST/gke-clusters.json"
  GN="$(ls "$GKE_DETAIL"/*-describe.json | wc -l | tr -d ' ')"
  echo "  gke-clusters.json  ← ${GN} 個 describe"
  MADE=$((MADE + 1))
  D="$DIGEST/gke-clusters.json"
  N="$(jq -r 'length' "$D")"
  assert "GKE 叢集數 > 0（${N}）" "length > 0" "$D"
  assert "privateCluster 保留（私有叢集判斷）"                 "[.[] | select(has(\"privateCluster\"))] | length == $N" "$D"
  assert "masterAuthorizedNetworks 保留（主控授權網段判斷）"   "[.[] | select(has(\"masterAuthorizedNetworks\"))] | length == $N" "$D"
  assert "vpcNative 保留（VPC-native／IP 別名判斷）"           "[.[] | select(has(\"vpcNative\"))] | length == $N" "$D"
else
  echo "  gke-clusters.json  略過（無 compute/gke-detail/，無 GKE 叢集或 API 未啟用）"
fi

# ── App Engine 服務 Ingress 投影（service 層）─────────────────────────
# 來源：appengine/service-detail/*-describe.json（scan.sh 逐服務 describe）。
# 必留證據：networkSettings.ingressTrafficAllowed（對外暴露面：誰能呼叫這個服務）。
# ⚠️ 本專案未建立 App Engine 應用，欄位路徑**未經真實資料驗證**（同 Cloud Run 情形）。防呆錨點是
#    **服務名**（.id／.name 皆解析不出來＝gcloud schema 變了→印「⚠️ 欄位無法解析」讓斷言 FAIL）。
#    ingress 不當防呆錨點：官方定義 networkSettings 缺席＝預設 INGRESS_TRAFFIC_ALLOWED_ALL（對外開放），
#    這是「有意義的缺席」而非解析失敗（同 GKE 非私有叢集欄位缺席的教訓），故缺席時補上帶標註的預設值。
# ⚠️ 這裡「ingress 缺席＝合法預設 ALL、不 FAIL」與上方 Cloud Run／Functions「ingress 缺席＝欄位無法解析→
#    斷言 FAIL」是**刻意相反**的：App Engine 官方定義 networkSettings 缺席就是預設對外開放（合法預設），
#    而 Cloud Run v2 的 ingress 一定有值、缺席代表 schema 假設錯了。兩段方向不同是有意為之，不是漏改。
AE_SVC_DETAIL="$DATA/appengine/service-detail"
if [ -d "$AE_SVC_DETAIL" ] && ls "$AE_SVC_DETAIL"/*-describe.json > /dev/null 2>&1; then
  jq -s '[.[] | {
    name: (.id // (.name | split("/") | last) // "⚠️ 欄位無法解析"),
    ingress: (.networkSettings.ingressTrafficAllowed
              // "INGRESS_TRAFFIC_ALLOWED_ALL（networkSettings 缺席＝預設對外開放）")
  }]' "$AE_SVC_DETAIL"/*-describe.json > "$DIGEST/appengine-services.json"
  AESN="$(ls "$AE_SVC_DETAIL"/*-describe.json | wc -l | tr -d ' ')"
  echo "  appengine-services.json  ← ${AESN} 個 describe"
  MADE=$((MADE + 1))
  D="$DIGEST/appengine-services.json"
  N="$(jq -r 'length' "$D")"
  assert "App Engine 服務數 > 0（${N}）" "length > 0" "$D"
  if grep -q '欄位無法解析' "$D"; then
    echo "    ❌ 斷言失敗：App Engine 服務名（.id／.name）解析不出來（gcloud 輸出 schema 與假設不同），請修正 digest.sh 投影" >&2
    FAIL=$((FAIL + 1))
  else
    [ "$N" -gt 0 ] && echo "    ✅ 服務名／ingress 欄位皆解析成功（未出現「欄位無法解析」）"
  fi
else
  echo "  appengine-services.json  略過（無 appengine/service-detail/，未建立 App Engine 應用或無服務）"
fi

# ── App Engine 版本網路投影（version 層）─────────────────────────────
# 來源：appengine/version-detail/*-describe.json（scan.sh 逐版本 describe）。
# 必留證據：vpcAccessConnector.{name,egressSetting}（Serverless VPC Access 出口＝連進哪個 VPC）、
#           network.{name,subnetworkName}（Flexible 環境的直接網路綁定）、env（standard／flexible）。
# service／version 名優先從資源全名 .name（apps/APP/services/SVC/versions/VER）推導；describe 只回 .id
# 而無全路徑 .name 時，退回 scan.sh 注入的 _scan_service／_scan_version（掃描迴圈已知的權威來源，
# 見 scan.sh 版本 describe 段），最後才落到「?」／「欄位無法解析」——確保 service 不會因缺全路徑變「?」
# 而丟掉 network-facts 第 4 段的服務關聯。env 依官方預設 standard。
# ⚠️ 未經真實資料驗證；防呆錨點是版本名（.id／_scan_version／.name 皆無→「⚠️ 欄位無法解析」→斷言 FAIL）。
AE_VER_DETAIL="$DATA/appengine/version-detail"
if [ -d "$AE_VER_DETAIL" ] && ls "$AE_VER_DETAIL"/*-describe.json > /dev/null 2>&1; then
  jq -s '[.[] |
    ((.name // "") | split("/")) as $p |
    {
      service: ((if ($p | length) >= 4 then $p[3] else null end) // ._scan_service // "?"),
      version: (.id // ._scan_version // (if ($p | length) >= 1 then ($p | last) else null end) // "⚠️ 欄位無法解析"),
      env: (.env // "standard"),
      servingStatus: (.servingStatus // null),
      vpcConnector: (.vpcAccessConnector.name // null),
      vpcEgressSetting: (.vpcAccessConnector.egressSetting // null),
      network: (.network.name // null),
      subnetwork: (.network.subnetworkName // null),
      instanceTag: (.network.instanceTag // null),
      inboundServices: (.inboundServices // [])
    }]' "$AE_VER_DETAIL"/*-describe.json > "$DIGEST/appengine-versions.json"
  AEVN="$(ls "$AE_VER_DETAIL"/*-describe.json | wc -l | tr -d ' ')"
  echo "  appengine-versions.json  ← ${AEVN} 個 describe"
  MADE=$((MADE + 1))
  D="$DIGEST/appengine-versions.json"
  N="$(jq -r 'length' "$D")"
  assert "App Engine 版本數 > 0（${N}）" "length > 0" "$D"
  if grep -q '欄位無法解析' "$D"; then
    echo "    ❌ 斷言失敗：App Engine 版本名解析不出來（gcloud 輸出 schema 與假設不同），請修正 digest.sh 投影" >&2
    FAIL=$((FAIL + 1))
  else
    [ "$N" -gt 0 ] && echo "    ✅ 版本名／env／vpcAccessConnector 欄位皆解析成功（未出現「欄位無法解析」）"
  fi
  [ "$N" -gt 0 ] && assert "vpcConnector 欄位保留（VPC 出口判斷）" "[.[] | select(has(\"vpcConnector\"))] | length == $N" "$D"
else
  echo "  appengine-versions.json  略過（無 appengine/version-detail/，未建立 App Engine 應用或無版本）"
fi

# ── BigQuery dataset 存取控制總表 ────────────────────────────────────
# 來源：bigquery/datasets.json（bq ls 索引）＋ bigquery/dataset-detail/*-describe.json（bq show 完整組態）。
# 一眼看出哪些 dataset 有公開／匿名授權（allUsers／allAuthenticatedUsers）、資料所在地、CMEK、
# 預設資料表過期治理——這裡的重點是安全（資料外洩），不是機器可讀 JSON，故用 gcs-buckets.md 那種總表風格。
# ⚠️ 空值語意：bigquery/datasets.json **不存在**＝bq ls 查詢失敗（資料缺口，API 未啟用／權限不足）；
#    **存在但為 []**＝專案真的沒有任何 dataset（有效證據）。兩者結論相反，不可混。
# ✅ 欄位路徑已用公開 dataset（bigquery-public-data:samples）真實 bq show 驗證：
#      公開授權以 `access[].iamMember == "allUsers"`（實測命中）呈現；allAuthenticatedUsers 可能落在
#      `iamMember` 或舊式 `specialGroup`，兩路都接。CMEK 未啟用時 defaultEncryptionConfiguration **整欄缺席**
#      （非解析失敗，故以「Google 管理」補），同理 defaultTableExpirationMs 缺席＝未設過期。
#    這與 Phase 1 的 Cloud Run（API 未啟用、欄位純靠文件猜）不同：本節 bq show 輸出結構已實測。
BQ_LIST="$DATA/bigquery/datasets.json"
BQ_DETAIL="$DATA/bigquery/dataset-detail"
if [ -f "$BQ_LIST" ]; then
  {
    echo "# BigQuery dataset 存取控制總表"
    echo ""
    echo "來源：\`data/bigquery/datasets.json\`（bq ls 索引）＋ \`data/bigquery/dataset-detail/*-describe.json\`（bq show 完整組態）。"
    echo "此表為上述檔案的確定性投影，可直接引用為證據。"
    echo ""
    echo "**公開／匿名授權**＝access[] 含 \`iamMember: allUsers\`（網際網路上任何人，無論有無 Google 帳號）或"
    echo "\`iamMember/specialGroup: allAuthenticatedUsers\`（任何 Google 帳號／服務帳戶）——這是 BigQuery"
    echo "資料外洩的最高風險點。\`CMEK\` 欄為「Google 管理」代表未使用客戶自管金鑰"
    echo "（defaultEncryptionConfiguration 欄缺席）。「預設資料表過期」未設定代表資料表預設永久保留（治理／成本訊號）。"
    echo ""
    if [ "$(jq -r 'length' "$BQ_LIST" 2>/dev/null || echo 0)" -eq 0 ]; then
      echo "**本專案沒有任何 BigQuery dataset**（bq ls 回空清單＝有效證據，不是資料缺口；"
      echo "BigQuery 系列 API 已啟用但未建立任何 dataset）。"
    elif [ -d "$BQ_DETAIL" ] && ls "$BQ_DETAIL"/*-describe.json > /dev/null 2>&1; then
      echo "| Dataset | 位置 | 公開／匿名授權 | CMEK | 預設資料表過期 | 存取項目數 |"
      echo "|---|---|---|---|---|---|"
      jq -rs '
        def pub: [.access[]? | select(.iamMember == "allUsers" or .iamMember == "allAuthenticatedUsers" or .specialGroup == "allAuthenticatedUsers")
                  | (.iamMember // .specialGroup)];
        .[] |
        (.datasetReference.datasetId // "⚠️ 欄位無法解析") as $id |
        (pub) as $p |
        "| \($id) | \(.location // "?") | " +
        (if ($p | length) > 0 then "**是（" + ($p | join(",")) + "）**" else "否" end) + " | " +
        (if .defaultEncryptionConfiguration.kmsKeyName then "有" else "Google 管理" end) + " | " +
        (if .defaultTableExpirationMs then (((.defaultTableExpirationMs | tonumber) / 86400000 | floor | tostring) + " 天") else "未設定" end) + " | " +
        ((.access // []) | length | tostring) + " |"
      ' "$BQ_DETAIL"/*-describe.json
    else
      echo "⚠️ **datasets.json 列出 dataset，但 dataset-detail/ 沒有對應 describe 檔**——bq show 可能失敗，"
      echo "請查 \`data/scan-errors.log\`（此為資料缺口，不可當成「沒有 dataset」）。"
    fi
  } > "$DIGEST/bigquery-datasets.md"
  echo "  bigquery-datasets.md  $(wc -c < "$DIGEST/bigquery-datasets.md") 位元組"
  MADE=$((MADE + 1))
  # 欄位解析斷言：有 dataset 時 datasetId 不可解析不出來（bq 換 schema 會第一時間炸出來）。
  # 0 dataset 時檔案為說明文字、不含此標記，斷言自然通過。
  if grep -q '欄位無法解析' "$DIGEST/bigquery-datasets.md"; then
    echo "    ❌ 斷言失敗：BigQuery dataset 的 datasetId 欄位解析不出來（bq 輸出 schema 與假設不同），請修正 digest.sh 投影" >&2
    FAIL=$((FAIL + 1))
  else
    echo "    ✅ BigQuery dataset 表產生成功（未出現「欄位無法解析」）"
  fi
else
  echo "  bigquery-datasets.md  略過（無 bigquery/datasets.json，bq ls 查詢失敗或 BigQuery API 未啟用）"
fi

# ── Cloud Storage 值區設定總表 ──────────────────────────────────────
# 一張表看完 PAP／UBLA／版本控制／生命週期／CMEK／保留政策／記錄，
# 讓 agent 一次 Read 就看完，不必逐欄拉原始 JSON。
# ⚠️ 「未設定」與「查詢失敗」必須分清楚：storage/buckets.json 不存在＝查詢失敗（資料缺口），
#    存在但為空陣列＝專案真的沒有值區（有效證據）。兩者結論相反。
#
# ⚠️⚠️ 欄位命名有兩種，**兩種都要接**（2026-07-21 實跑踩到，且是最危險的一種錯——結論相反）：
#      `gcloud storage buckets list` 回 **snake_case**：public_access_prevention /
#          uniform_bucket_level_access / default_storage_class / versioning_enabled
#      JSON API（與舊版 gsutil）回 **camelCase**：iamConfiguration.publicAccessPrevention /
#          iamConfiguration.uniformBucketLevelAccess.enabled / versioning.enabled
#      當初只寫了 camelCase，實跑時 PAP 明明是 enforced、UBLA 明明是 true，
#      digest 卻印成「未設定／未啟用」——agent 據此會下出完全相反的發現。
#      因此下方一律 `snake // camel // 未知`，且**加上「不得解析不出來」的斷言**：
#      只驗筆數不驗欄位解析，正是這次沒被擋下來的原因。
SRC="$DATA/storage/buckets.json"
if [ -f "$SRC" ]; then
  {
    echo "# Cloud Storage 值區設定總表"
    echo ""
    echo "來源：\`data/storage/buckets.json\`（gcloud storage buckets list 一次回全部組態）。"
    echo "此表為該檔的確定性投影，可直接引用為證據。"
    echo ""
    echo "「公開存取防護（PAP）」為 \`enforced\` 才是真的擋掉公開授權；\`inherited\` 代表沿用組織政策，"
    echo "沒有組織政策時等同未強制。「統一值區層級存取（UBLA）」未啟用時仍可用舊版 ACL 授權，"
    echo "是 GCS 上最常見的意外公開途徑。"
    echo ""
    if [ "$(jq -r 'length' "$SRC")" -eq 0 ]; then
      echo "**本專案沒有任何 Cloud Storage 值區**（gcloud 回空清單＝有效證據，不是資料缺口）。"
    else
      echo "| 值區 | 位置 | 儲存類別 | PAP | UBLA | 版本控制 | 生命週期 | Autoclass | CMEK | 保留政策 | 使用記錄 |"
      echo "|---|---|---|---|---|---|---|---|---|---|---|"
      jq -r '
        def pap: (.public_access_prevention // .iamConfiguration.publicAccessPrevention // "⚠️ 欄位無法解析");
        def ubla: (if (.uniform_bucket_level_access // .iamConfiguration.uniformBucketLevelAccess.enabled) == true
                   then "啟用"
                   elif (has("uniform_bucket_level_access") or (.iamConfiguration | type) == "object")
                   then "**未啟用**" else "⚠️ 欄位無法解析" end);
        def ver: (if (.versioning_enabled // .versioning.enabled) == true then "啟用" else "未啟用" end);
        def life: ((.lifecycle_config.rule // .lifecycle.rule // []) | if length > 0 then ((length|tostring) + " 條") else "未設定" end);
        def auto: (if (.autoclass.enabled // false) then ("啟用→" + (.autoclass.terminalStorageClass // "?")) else "未啟用" end);
        .[] |
        "| \(.name) | \(.location // "?") | \(.default_storage_class // .storageClass // "?") | " +
        "\(pap) | \(ubla) | \(ver) | \(life) | \(auto) | " +
        "\(if (.default_kms_key // .encryption.defaultKmsKeyName) then "有" else "Google 管理" end) | " +
        "\(if (.retention_policy // .retentionPolicy) then "有" else "未設定" end) | " +
        "\(if (.log_config // .logging) then "啟用" else "未啟用" end) |"' "$SRC"
    fi
  } > "$DIGEST/gcs-buckets.md"
  NB="$(jq -r 'length' "$SRC")"
  ND="$(grep -c '^| [^-|]' "$DIGEST/gcs-buckets.md" || true)"
  echo "  gcs-buckets.md  $(wc -c < "$SRC") → $(wc -c < "$DIGEST/gcs-buckets.md") 位元組"
  MADE=$((MADE + 1))
  # 表頭那列也會被算到，故資料列數＝ND-1（無值區時 ND=0）
  if [ "$NB" -eq 0 ] || [ "$NB" -eq "$((ND - 1))" ]; then
    echo "    ✅ 值區數一致（${NB}）"
  else
    echo "    ❌ 斷言失敗：值區數不符（原始 ${NB}、digest $((ND - 1))）" >&2
    FAIL=$((FAIL + 1))
  fi
  # 欄位解析斷言：只驗筆數擋不住「欄位名改了→值印成未設定」這種**結論相反**的錯，
  # 故明確禁止表中出現「欄位無法解析」（gcloud 換 schema 時會第一時間炸出來）。
  if grep -q '欄位無法解析' "$DIGEST/gcs-buckets.md"; then
    echo "    ❌ 斷言失敗：PAP／UBLA 欄位解析不出來（gcloud 輸出 schema 可能已變），請修正 digest.sh 的投影" >&2
    FAIL=$((FAIL + 1))
  else
    [ "$NB" -gt 0 ] && echo "    ✅ PAP／UBLA 欄位皆解析成功（未出現「欄位無法解析」）"
  fi
fi

# ── Filestore 執行個體設定總表 ─────────────────────────────────────────
# 來源：storage/filestore-instances.json（gcloud filestore instances list --format=json；list 已回完整資源）。
# 一張表看完：層級（tier＝可用性／效能層級）、狀態、綁定 VPC／保留網段／連線模式（網路歸屬）、
# 檔案共用容量、NFS 匯出存取控制（哪些 IP 能掛載、讀寫或唯讀、root squash＝安全）、CMEK。
# ⚠️ 空值語意：storage/filestore-instances.json **不存在**＝list 查詢失敗（API 未啟用／權限不足，資料缺口）；
#    **存在但為 []**＝專案真的沒有任何 Filestore 執行個體（有效證據）。兩者結論相反，不可混。
# ⚠️ 本專案 file.googleapis.com 未啟用（list 回 SERVICE_DISABLED＝資料缺口，檔案不存在→本段優雅略過），
#    此段欄位路徑**未經真實資料驗證**（同 Cloud Run／App Engine 情形），僅依官方 Filestore REST v1 Instance
#    schema 撰寫。防呆錨點是**執行個體名**（.name 解析不出來＝gcloud schema 變了→印「⚠️ 欄位無法解析」
#    讓斷言 FAIL），**絕不可默默印「未設定」**。tier／state／networks[] 官方定義恆存在，缺席時補 "?"／"—"。
FS_SRC="$DATA/storage/filestore-instances.json"
if [ -f "$FS_SRC" ]; then
  {
    echo "# Filestore 執行個體設定總表"
    echo ""
    echo "來源：\`data/storage/filestore-instances.json\`（gcloud filestore instances list --format=json，list 已回完整資源）。"
    echo "此表為該檔的確定性投影，可直接引用為證據。"
    echo ""
    echo "**Filestore 無公開 IP 的概念**：只能透過同 VPC／VPC Peering／Private Service Access 存取，"
    echo "可及性完全取決於綁定 VPC（\`networks[].network\`）內部路由與防火牆，以及 NFS 匯出選項"
    echo "（\`nfsExportOptions\`：哪些 IP 網段能掛載、讀寫或唯讀、是否 root squash）。「層級（tier）」"
    echo "決定可用性與效能：\`BASIC_HDD\`／\`BASIC_SSD\`＝單一區域無備援；\`ENTERPRISE\`／\`REGIONAL\`＝"
    echo "區域級高可用（跨可用區）。\`CMEK\` 欄為「Google 管理」代表未使用客戶自管金鑰（kmsKeyName 缺席）。"
    echo ""
    if [ "$(jq -r 'length' "$FS_SRC" 2>/dev/null || echo 0)" -eq 0 ]; then
      echo "**本專案沒有任何 Filestore 執行個體**（gcloud 回空清單＝有效證據，不是資料缺口）。"
    else
      echo "| 執行個體 | 位置 | 層級 | 狀態 | 綁定 VPC | 保留網段 | 連線模式 | 檔案共用（容量 GB） | NFS 匯出存取控制 | CMEK |"
      echo "|---|---|---|---|---|---|---|---|---|---|"
      jq -r '
        def nets: (.networks // []);
        def shares: (.fileShares // []);
        .[] |
        ((.name // "⚠️ 欄位無法解析") | split("/")) as $p |
        ($p | last) as $id |
        (if ($p | length) >= 4 then $p[3] else "?" end) as $loc |
        "| \($id) | \($loc) | \(.tier // "?") | \(.state // "?") | " +
        ((nets | map((.network // "?") | split("/") | last) | join(",")) | if . == "" then "—" else . end) + " | " +
        ((nets | map(.reservedIpRange // "?") | join(",")) | if . == "" then "—" else . end) + " | " +
        ((nets | map(.connectMode // "DIRECT_PEERING") | join(",")) | if . == "" then "—" else . end) + " | " +
        ((shares | map((.name // "?") + "（" + ((.capacityGb // "?") | tostring) + "）") | join(",")) | if . == "" then "—" else . end) + " | " +
        ((shares | map((.nfsExportOptions // []) | map(((.ipRanges // ["?"]) | join(";")) + ":" + (.accessMode // "?") + "/" + (.squashMode // "?")) | join(" ")) | map(select(. != "")) | join(" ")) | if . == "" then "**預設：全部用戶端可讀寫、NO_ROOT_SQUASH**" else . end) + " | " +
        (if .kmsKeyName then "有" else "Google 管理" end) + " |"
      ' "$FS_SRC"
    fi
  } > "$DIGEST/filestore-instances.md"
  echo "  filestore-instances.md  $(wc -c < "$FS_SRC") → $(wc -c < "$DIGEST/filestore-instances.md") 位元組"
  MADE=$((MADE + 1))
  # 欄位解析斷言：有執行個體時 .name 不可解析不出來（gcloud 換 schema 會第一時間炸出來）。
  # 0 執行個體時檔案為說明文字、不含此標記，斷言自然通過。
  if grep -q '欄位無法解析' "$DIGEST/filestore-instances.md"; then
    echo "    ❌ 斷言失敗：Filestore 執行個體名（.name）解析不出來（gcloud 輸出 schema 與假設不同），請修正 digest.sh 投影" >&2
    FAIL=$((FAIL + 1))
  else
    echo "    ✅ Filestore 執行個體表產生成功（未出現「欄位無法解析」）"
  fi
else
  echo "  filestore-instances.md  略過（無 storage/filestore-instances.json，Filestore API 未啟用或無執行個體）"
fi

# ── IAM 政策：把 bindings 攤成「角色 → 成員」並標出基本角色與外部成員 ──
# 必留證據：基本角色（owner/editor/viewer）的授予對象——這是 GCP 最常見的過度授權；
#           allUsers／allAuthenticatedUsers（公開授權）；跨網域成員。
SRC="$DATA/iam-policy.json"
if [ -f "$SRC" ]; then
  {
    echo "# 專案 IAM 政策總表"
    echo ""
    echo "來源：\`data/iam-policy.json\`（gcloud projects get-iam-policy）。確定性攤平，可直接引用為證據。"
    echo ""
    echo "## 角色與成員"
    echo ""
    echo "| 角色 | 類型 | 成員數 | 成員 |"
    echo "|---|---|---:|---|"
    jq -r '(.bindings // [])[] |
      "| `\(.role)` | " +
      (if (.role | test("^roles/(owner|editor|viewer)$")) then "**基本角色**" else "預定義／自訂" end) +
      " | \((.members // []) | length) | " +
      ((.members // []) | join("<br>")) + " |"' "$SRC"
    echo ""
    echo "## ⚠️ 公開或匿名授權（allUsers / allAuthenticatedUsers）"
    echo ""
    PUB="$(jq -r '[(.bindings // [])[] | select((.members // []) | any(. == "allUsers" or . == "allAuthenticatedUsers")) | .role] | join(", ")' "$SRC")"
    if [ -n "$PUB" ] && [ "$PUB" != "" ]; then
      echo "**存在公開授權**，角色：$PUB"
    else
      echo "無：專案 IAM 政策中沒有 allUsers／allAuthenticatedUsers 授權。"
    fi
    echo ""
    echo "## ⚠️ 基本角色（owner／editor）授予對象"
    echo ""
    BASIC="$(jq -r '[(.bindings // [])[] | select(.role | test("^roles/(owner|editor)$")) | .role + " → " + ((.members // []) | join(", "))] | join("\n")' "$SRC")"
    if [ -n "$BASIC" ]; then
      printf '%s\n' "$BASIC" | sed 's/^/- /'
      echo ""
      echo "基本角色涵蓋幾乎所有寫入權限，違反最小權限原則；服務帳戶掛 editor 尤其危險。"
    else
      echo "無：沒有任何成員被授予 owner／editor。"
    fi
  } > "$DIGEST/iam-policy.md"
  echo "  iam-policy.md  $(wc -c < "$DIGEST/iam-policy.md") 位元組"
  MADE=$((MADE + 1))
  for sec in "角色與成員" "公開或匿名授權" "基本角色"; do
    if grep -q "$sec" "$DIGEST/iam-policy.md"; then
      echo "    ✅ IAM 表：${sec}"
    else
      echo "    ❌ 斷言失敗：IAM 表缺少「${sec}」區塊" >&2
      FAIL=$((FAIL + 1))
    fi
  done
fi

# ── 成本訊號表：GCP 沒有成本明細 API，成本支柱靠這張表 ────────────────
# 內容＝預算設定狀態 ＋ Recommender 的閒置／規格建議（含官方估算的每月節省金額）。
# ⚠️ 這張表**不是**成本明細；「各服務花多少錢」在沒有 BigQuery 帳單匯出時是資料缺口，
#    必須照實寫進報告，不可用推算數字冒充實際帳單。
{
  echo "# 成本訊號表"
  echo ""
  echo "GCP **沒有**可直接查詢成本明細的 API——「各服務各月花多少錢」需要"
  echo "BigQuery 帳單匯出，本專案未接。因此："
  echo ""
  echo "- **實際成本明細＝資料缺口**，必須照實寫進報告的資料缺口段落，不可用推算值冒充帳單數字。"
  echo "- 成本支柱的量化依據＝下方 Recommender 建議（Google 官方以實際用量算出的節省估計）"
  echo "  ＋資源組態推算（閒置磁碟、未使用 IP、機型世代等，需自行以官方定價頁估算）。"
  echo ""
  echo "## 預算與帳單告警"
  echo ""
  if [ -f "$DATA/cost/budgets.json" ]; then
    if [ "$(jq -r 'length' "$DATA/cost/budgets.json" 2>/dev/null || echo 0)" -eq 0 ]; then
      echo "**未設定任何預算（budget）**——gcloud 回空清單，這是有效證據。"
      echo "代表成本超支時沒有任何自動告警，可直接據此下發現。"
    else
      echo "| 預算名稱 | 金額 | 幣別 | 門檻規則 |"
      echo "|---|---:|---|---|"
      jq -r '.[] | "| \(.displayName // .name) | \(.amount.specifiedAmount.units // (if .amount.lastPeriodAmount then "上期用量" else "?" end)) | \(.amount.specifiedAmount.currencyCode // "-") | " +
        (((.thresholdRules // []) | map(((.thresholdPercent // 0) * 100 | floor | tostring) + "%")) | join(", ")) + " |"' \
        "$DATA/cost/budgets.json"
    fi
  else
    echo "⚠️ **查詢失敗**（資料缺口，非「未設定」）：未取得帳單帳戶或缺 billing.budgets.list 權限，"
    echo "詳見 \`data/scan-errors.log\`。不可據此宣稱「沒有預算」——那是相反的結論。"
  fi
  echo ""
  echo "## Recommender 建議（Google 官方依實際用量產生）"
  echo ""
  REC_FILES="$(find "$DATA/cost/recommender" -name '*.json' 2>/dev/null | sort)"
  if [ -n "$REC_FILES" ]; then
    TOTAL_REC="$(printf '%s\n' "$REC_FILES" | xargs -I{} jq -r 'length' {} 2>/dev/null | awk '{s+=$1} END {print s+0}')"
    if [ "${TOTAL_REC:-0}" -eq 0 ]; then
      echo "查詢成功但**沒有任何建議**（所有 recommender 皆回空清單）。"
      echo "這是有效證據：Google 未偵測到閒置或明顯超規的資源；也可能是資源存在時間不足 (<30 天) 無從判斷。"
    else
      echo "| 位置 | 類型 | 建議 | 每月節省估計 | 狀態 |"
      echo "|---|---|---|---:|---|"
      printf '%s\n' "$REC_FILES" | while IFS= read -r f; do
        loc="$(basename "$f" .json)"
        jq -r --arg loc "$loc" '.[]? |
          "| \($loc) | \(.recommenderSubtype // "?") | \((.description // "?") | gsub("\\|"; "/")) | " +
          (.primaryImpact.costProjection.cost as $c |
           if ($c.units // $c.nanos) != null then
             ((((($c.units // 0) | tonumber) + (($c.nanos // 0) / 1000000000)) | fabs | . * 100 | round / 100 | tostring)
              + " " + ($c.currencyCode // ""))
           else "-" end) +
          " | \(.stateInfo.state // "?") |"' "$f" 2>/dev/null
      done
      echo ""
      echo "> 節省金額取自 \`primaryImpact.costProjection.cost\`（原始值為負數＝省下的錢，此處取絕對值）。"
      echo "> **金額由 \`units\` ＋ \`nanos\`/1e9 合併後四捨五入到小數兩位**——Money 型別把整數與小數"
      echo "> 分成兩個欄位，只讀 \`units\` 會把小數整段丟掉（如 -11.612903226 印成 11），"
      echo "> 金額不足 1 元時甚至整筆變成 0。"
      echo "> 期間為該 recommender 的預估週期（通常為月）。引用時對回 \`data/cost/recommender/\` 原始檔。"
    fi
  else
    echo "⚠️ **查詢失敗**（資料缺口）：Recommender API 未啟用或無 recommender.*.list 權限，"
    echo "詳見 \`data/scan-errors.log\`。"
  fi
} > "$DIGEST/cost-signals.md"
echo "  cost-signals.md  $(wc -c < "$DIGEST/cost-signals.md") 位元組"
MADE=$((MADE + 1))
for sec in "預算與帳單告警" "Recommender 建議" "資料缺口"; do
  if grep -q "$sec" "$DIGEST/cost-signals.md"; then
    echo "    ✅ 成本訊號表：${sec}"
  else
    echo "    ❌ 斷言失敗：成本訊號表缺少「${sec}」區塊" >&2
    FAIL=$((FAIL + 1))
  fi
done

# ── 掃描缺口表：把「空回應」與「失敗」分清楚 ────────────────────────
# 沒有這張表時，agent 看到空的 data/cost/budgets.json 分不清是「專案真的沒有預算」
# 還是「掃描默默失敗了」，於是會自己組指令回頭問 GCP——那類指令含 $(...) 展開，
# 必定觸發權限確認、破壞無人值守。給它一個權威答案，它就不需要自己去查。
ERRLOG_S="$DATA/scan-errors.log"
if [ -f "$ERRLOG_S" ]; then
  {
    echo "# 掃描缺口表"
    echo ""
    echo "來源：\`data/scan-errors.log\`。**這是關於「查不到的東西」的權威答案，不要自己回頭呼叫 gcloud 補查。**"
    echo ""
    echo "## 未設定／無此類資源（gcloud 回空結果）——這是有效證據，不是資料缺口"
    echo ""
    echo "呼叫成功但回空清單，代表該類資源／組態**確實不存在**。可以直接據此下發現"
    echo "（例：專案沒有任何預算告警、沒有任何 Cloud Armor 政策）。"
    echo ""
    if grep -q '^EMPTY:' "$ERRLOG_S" 2>/dev/null; then
      echo "| 項目 | 意義 |"
      echo "|---|---|"
      grep '^EMPTY:' "$ERRLOG_S" | sed 's/^EMPTY: //' | while IFS= read -r line; do
        echo "| \`${line%% ::*}\` | 未設定／無此類資源（gcloud 回空結果） |"
      done
    else
      echo "（無）"
    fi
    echo ""
    echo "## 查詢失敗——真正的資料缺口"
    echo ""
    echo "錯誤訊息含 \`has not been used\` / \`is disabled\`（API 未啟用）或 \`PERMISSION_DENIED\`（權限不足）"
    echo "者，代表**查不到**，寫入報告的「資料缺口」段落。**不可把資料缺口寫成「未設定」**——那是相反的結論。"
    echo ""
    if grep -q '^FAILED:' "$ERRLOG_S" 2>/dev/null; then
      echo "| 項目 | 判定 |"
      echo "|---|---|"
      grep '^FAILED:' "$ERRLOG_S" | sed 's/^FAILED: //' | while IFS= read -r line; do
        item="${line%% ::*}"
        if printf '%s' "$line" | grep -qiE 'has not been used|is disabled|SERVICE_DISABLED|API .* not enabled'; then
          echo "| \`$item\` | **資料缺口**：API 未啟用（該服務可能根本沒在用，但不可據此斷言） |"
        elif printf '%s' "$line" | grep -qiE 'PERMISSION_DENIED|does not have permission|Forbidden|403'; then
          echo "| \`$item\` | **資料缺口**：權限不足（唯讀身分缺少對應 viewer 角色） |"
        elif printf '%s' "$line" | grep -qiE 'NOT_FOUND|not found|was not found'; then
          echo "| \`$item\` | 未設定（該資源不存在）——有效證據 |"
        else
          echo "| \`$item\` | **資料缺口**（原因見 scan-errors.log） |"
        fi
      done
    else
      echo "（無）"
    fi
  } > "$DIGEST/scan-gaps.md"
  echo "  scan-gaps.md  $(wc -c < "$DIGEST/scan-gaps.md") 位元組（空回應 vs 資料缺口）"
  MADE=$((MADE + 1))
  if grep -q "未設定／無此類資源" "$DIGEST/scan-gaps.md" && grep -q "查詢失敗" "$DIGEST/scan-gaps.md"; then
    echo "    ✅ 缺口表兩個區塊都在"
  else
    echo "    ❌ 斷言失敗：缺口表缺少區塊" >&2
    FAIL=$((FAIL + 1))
  fi
fi

# ── 跨檔關聯：把要比對好幾個檔才看得出來的網路事實算成結論 ──────────
# （防火牆規則的實際暴露面／VM 對外路徑／Cloud SQL 的實際可及性）
# 這類機械性比對不該交給 LLM 判斷——曾因為漏做這一步，
# 把「資料庫落在全部通網際網路的子網」[高] 降級成 [中]，還給出該環境做不到的修復建議。
if python3 "$SKILL_DIR/scripts/network-facts.py"; then
  MADE=$((MADE + 1))
  NF="$DIGEST/network-facts.md"
  # 斷言：三個關聯區塊都要在（少任何一段代表關聯沒算出來，等於又把判斷丟回給 LLM）
  for sec in "防火牆規則的實際暴露面" "VM 的實際對外路徑" "Cloud SQL 的實際可及性" "無伺服器資源的網路路徑"; do
    if grep -q "$sec" "$NF"; then
      echo "    ✅ 網路事實：${sec}"
    else
      echo "    ❌ 斷言失敗：網路事實表缺少「${sec}」區塊" >&2
      FAIL=$((FAIL + 1))
    fi
  done
else
  echo "    ❌ network-facts.py 執行失敗" >&2
  FAIL=$((FAIL + 1))
fi

echo ""
if [ "$MADE" -eq 0 ]; then
  echo "=== 精簡失敗：沒有產出任何 digest ===" >&2
  echo "data/ 下找不到預期的來源檔，掃描可能不完整。" >&2
  exit 1
fi
if [ "$FAIL" -gt 0 ]; then
  echo "=== 精簡失敗：$FAIL 項欄位斷言未通過 ===" >&2
  echo "digest 遺失了發現所依賴的證據欄位，請修正 .claude/skills/report-gcp/scripts/digest.sh 的投影後重跑。" >&2
  exit 1
fi
echo "=== 精簡完成，所有證據欄位斷言通過 ==="
