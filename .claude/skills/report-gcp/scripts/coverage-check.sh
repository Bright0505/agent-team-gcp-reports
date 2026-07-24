#!/usr/bin/env bash
# coverage-check.sh — 覆蓋率確定性比對
#
# 用 Cloud Asset Inventory（data/global/asset-inventory.json）當「這專案真的有哪些資源型別」的權威來源，
# diff 一張審查過的 assetType 分類表，產出 data/digest/coverage-gaps.md：
#   ① 已覆蓋      — scan.sh 有掃
#   ② 範圍外(k8s) — GKE 叢集內的 Kubernetes 物件，需 kubectl 憑證，屬 GCP 資源層以外
#   ③ 範圍外(meta)— 專案中繼資料／暫態查詢，非需稽核的資源
#   ④ 待分類缺口  — 有資源卻不在上述任何分類 → 需人工 triage 決定要不要掃
#
# 鐵則：**未知 assetType 一律落入 ④**（預設即缺口）。這才能在未來新增服務時自動浮現，
# 不靠人憑記憶擴充清單——這正是本機制的價值。新確認要掃的型別，補進 COVERED；
# 確認範圍外的，補進 OOS_META（k8s 由網域自動判定，不需逐條列）。
#
# 唯讀、純本機處理（jq），不碰 GCP 專案。用法：bash coverage-check.sh [DATA_DIR]
set -euo pipefail

DATA="${1:-data}"
INV="$DATA/global/asset-inventory.json"
OUT="$DATA/digest/coverage-gaps.md"
mkdir -p "$DATA/digest"

if [ ! -s "$INV" ]; then
  {
    echo "# 覆蓋率檢查"
    echo
    echo "**[資料缺口]** 找不到 \`$INV\`（Cloud Asset Inventory 未取得——cloudasset API 未啟用或無 roles/cloudasset.viewer）。"
    echo "無法做覆蓋率比對；本期覆蓋率無法量化。"
  } > "$OUT"
  echo "coverage-check：無 asset-inventory.json，已記為資料缺口 → $OUT"
  exit 0
fi

# ── 已覆蓋清單（scan.sh 目前會掃的 GCP 資源型別）────────────────────────────
# 改動 scan.sh 的覆蓋範圍時，這張表要同步更新（審查過才加）。
COVERED="$(cat <<'EOF'
compute.googleapis.com/Instance
compute.googleapis.com/Disk
compute.googleapis.com/Snapshot
compute.googleapis.com/Subnetwork
compute.googleapis.com/Network
compute.googleapis.com/Route
compute.googleapis.com/Router
compute.googleapis.com/Firewall
compute.googleapis.com/Address
compute.googleapis.com/ForwardingRule
compute.googleapis.com/BackendService
compute.googleapis.com/UrlMap
compute.googleapis.com/TargetHttpProxy
compute.googleapis.com/TargetHttpsProxy
compute.googleapis.com/HealthCheck
compute.googleapis.com/SslCertificate
compute.googleapis.com/SslPolicy
compute.googleapis.com/SecurityPolicy
compute.googleapis.com/InstanceGroup
compute.googleapis.com/InstanceGroupManager
compute.googleapis.com/InstanceTemplate
compute.googleapis.com/VpnTunnel
compute.googleapis.com/VpnGateway
compute.googleapis.com/Interconnect
compute.googleapis.com/Image
sqladmin.googleapis.com/Instance
sqladmin.googleapis.com/Backup
sqladmin.googleapis.com/BackupRun
redis.googleapis.com/Instance
redis.googleapis.com/Cluster
storage.googleapis.com/Bucket
dns.googleapis.com/ManagedZone
iam.googleapis.com/ServiceAccount
iam.googleapis.com/ServiceAccountKey
logging.googleapis.com/LogSink
logging.googleapis.com/LogBucket
logging.googleapis.com/LogMetric
container.googleapis.com/Cluster
container.googleapis.com/NodePool
serviceusage.googleapis.com/Service
cloudbilling.googleapis.com/ProjectBillingInfo
cloudresourcemanager.googleapis.com/Project
apikeys.googleapis.com/Key
pubsub.googleapis.com/Topic
pubsub.googleapis.com/Subscription
bigquery.googleapis.com/Dataset
spanner.googleapis.com/Instance
bigtableadmin.googleapis.com/Instance
alloydb.googleapis.com/Cluster
memcache.googleapis.com/Instance
firestore.googleapis.com/Database
run.googleapis.com/Service
cloudfunctions.googleapis.com/CloudFunction
appengine.googleapis.com/Service
file.googleapis.com/Instance
monitoring.googleapis.com/AlertPolicy
EOF
)"

# ── 範圍外：專案中繼資料／暫態查詢（非需稽核的資源實例）────────────────────
OOS_META="$(cat <<'EOF'
compute.googleapis.com/Project
compute.googleapis.com/InstanceSettings
logging.googleapis.com/RecentQuery
EOF
)"

# k8s 叢集內物件由網域判定（*.k8s.io 或 k8s.io/*）——不需逐條列。

# 取得專案實際存在的 assetType（含數量），降冪。用 while-read（相容 bash 3.2，無 mapfile）。
covered_lines=(); k8s_lines=(); meta_lines=(); gap_lines=()
tot=0; c_cov=0; c_k8s=0; c_meta=0; c_gap=0

while IFS= read -r row; do
  [ -z "$row" ] && continue
  cnt="${row%% *}"; at="${row#* }"
  tot=$((tot+1))
  if grep -qxF "$at" <<<"$COVERED"; then
    covered_lines+=("| \`$at\` | $cnt |"); c_cov=$((c_cov+1))
  elif [[ "$at" == *k8s.io/* ]]; then
    k8s_lines+=("| \`$at\` | $cnt |"); c_k8s=$((c_k8s+1))
  elif grep -qxF "$at" <<<"$OOS_META"; then
    meta_lines+=("| \`$at\` | $cnt |"); c_meta=$((c_meta+1))
  else
    gap_lines+=("| \`$at\` | $cnt |"); c_gap=$((c_gap+1))
  fi
done < <(jq -r '.[].assetType' "$INV" | sort | uniq -c | sort -rn | sed 's/^ *//')

# ── 必掃執法：讀版控的 required-coverage.json，違規者硬失敗 ──────────────────
# 違規 = 某必掃 assetType「存在於專案 ∧ 不在 COVERED」。它只讀字串、不跑任何 gcloud，安全。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REQ_FILE="$SCRIPT_DIR/../references/required-coverage.json"
PRESENT_ALL="$(jq -r '.[].assetType' "$INV" | sort -u)"
violations=()
if [ -s "$REQ_FILE" ]; then
  while IFS= read -r req; do
    [ -z "$req" ] && continue
    if grep -qxF "$req" <<<"$PRESENT_ALL" && ! grep -qxF "$req" <<<"$COVERED"; then
      violations+=("$req")
    fi
  done < <(jq -r '.required[]? // empty' "$REQ_FILE")
fi

{
  echo "# 覆蓋率檢查（Cloud Asset Inventory diff scan.sh）"
  echo
  echo "> 由 \`coverage-check.sh\` 確定性產生：以 CAI 列出的專案實際資源型別，對照 scan.sh 已知覆蓋清單。"
  echo "> **未知型別一律歸「④ 待分類缺口」**——未來新增服務會自動在此浮現。"
  echo
  echo "## 摘要"
  echo
  echo "| 分類 | 相異 assetType 數 |"
  echo "|---|---:|"
  echo "| ① 已覆蓋 | $c_cov |"
  echo "| ② 範圍外（GKE 叢集內 k8s 物件） | $c_k8s |"
  echo "| ③ 範圍外（專案中繼資料／暫態） | $c_meta |"
  echo "| **④ 待分類缺口（需 triage）** | **$c_gap** |"
  echo "| 合計 | $tot |"
  echo
  if [ "${#violations[@]}" -gt 0 ]; then
    echo "## 🔴 必掃違規（required-coverage.json）— 存在於專案卻未被 scan.sh 掃到"
    echo
    echo "> 這些型別被列為必掃，卻在專案中存在且未覆蓋。**已使 coverage-check 硬失敗（exit 1），digest 中止。**"
    echo "> 修法：把對應的 \`run\` 收集加進 \`scan.sh\`（並更新 coverage-check.sh 的 COVERED 表），或若確認不需掃，從 required-coverage.json 移除。"
    echo
    echo "| 必掃 assetType |"
    echo "|---|"
    for v in "${violations[@]}"; do echo "| \`$v\` |"; done
    echo
  fi
  if [ "$c_gap" -gt 0 ]; then
    echo "## ④ 待分類缺口 — 有資源卻不在覆蓋清單，需人工判斷要不要掃"
    echo
    echo "| assetType | 資源數 |"
    echo "|---|---:|"
    printf '%s\n' "${gap_lines[@]}"
    echo
  else
    echo "## ④ 待分類缺口"
    echo
    echo "（無）✅ 專案內所有 GCP 資源型別都已分類。"
    echo
  fi
  echo "## ② 範圍外：GKE 叢集內 Kubernetes 物件（需 kubectl 憑證，屬 GCP 資源層以外）"
  echo
  echo "| assetType | 資源數 |"
  echo "|---|---:|"
  printf '%s\n' "${k8s_lines[@]}"
  echo
  echo "## ③ 範圍外：專案中繼資料／暫態查詢"
  echo
  echo "| assetType | 資源數 |"
  echo "|---|---:|"
  printf '%s\n' "${meta_lines[@]}"
  echo
  echo "## ① 已覆蓋（scan.sh 有掃）"
  echo
  echo "| assetType | 資源數 |"
  echo "|---|---:|"
  printf '%s\n' "${covered_lines[@]}"
} > "$OUT"

echo "coverage-check：合計 ${tot} 型（已覆蓋 ${c_cov}／k8s ${c_k8s}／meta ${c_meta}／待分類缺口 ${c_gap}）→ $OUT"

if [ "${#violations[@]}" -gt 0 ]; then
  echo "🔴 必掃違規 ${#violations[@]} 項（見 coverage-gaps.md 頂端）：${violations[*]}" >&2
  exit 1
fi
