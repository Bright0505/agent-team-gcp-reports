#!/usr/bin/env bash
# coverage-check.sh — 覆蓋率確定性比對（純諮詢，不阻斷流程）
#
# 用 Cloud Asset Inventory（data/global/asset-inventory.json）當「這專案真的有哪些資源型別」的權威來源，
# diff scan-manifest.json 宣告的覆蓋清單，產出 data/digest/coverage-gaps.md：
#   ① 已覆蓋      — scan.sh 有掃（依 manifest 的 assetTypes 判定）
#   ② 範圍外(k8s) — GKE 叢集內的 Kubernetes 物件，需 kubectl 憑證，屬 GCP 資源層以外
#   ③ 範圍外(meta)— 專案中繼資料／暫態查詢，非需稽核的資源
#   ④ 待分類缺口  — 有資源卻不在上述任何分類 → 需人工 triage 決定要不要掃
#
# 鐵則：**未知 assetType 一律落入 ④**（預設即缺口）。這才能在未來新增服務時自動浮現，
# 不靠人憑記憶擴充清單——這正是本機制的價值。
#
# 覆蓋來源＝**單一真相**：`references/scan-manifest.json` 的 assetTypes 聯集（不再手維護第二張表）。
# 要把某缺口變成「已掃」：在 scan-manifest.json 加一筆（標準服務給 args；例外用 handledIn 並在 scan.sh 寫碼）。
# 本檔為**純諮詢**：只報告缺口、不 exit 1、不阻斷 digest（覆蓋回歸靠人每期看本報告，非自動當機）。
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

# ── 已覆蓋清單：由 scan-manifest.json 的 assetTypes 聯集推導（單一真相來源）─────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$SCRIPT_DIR/../references/scan-manifest.json"
if [ ! -s "$MANIFEST" ]; then
  echo "錯誤：找不到 scan-manifest.json（$MANIFEST）——無法推導覆蓋清單" >&2
  exit 1
fi
COVERED="$(jq -r '[.entries[].assetTypes[]?] | unique | .[]' "$MANIFEST")"

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

{
  echo "# 覆蓋率檢查（Cloud Asset Inventory diff scan-manifest.json）"
  echo
  echo "> 由 \`coverage-check.sh\` 確定性產生：以 CAI 列出的專案實際資源型別，對照 \`scan-manifest.json\` 宣告的覆蓋。"
  echo "> **未知型別一律歸「④ 待分類缺口」**——未來新增服務會自動在此浮現。純諮詢：不阻斷流程，靠人每期檢視。"
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
  if [ "$c_gap" -gt 0 ]; then
    echo "## ④ 待分類缺口 — 有資源卻不在覆蓋清單，需人工判斷要不要掃"
    echo
    echo "> 要掃：在 \`scan-manifest.json\` 加一筆（標準服務給 args；行為不標準者用 handledIn 並在 scan.sh 寫碼）。故意不掃：略過即可。"
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
  echo "## ① 已覆蓋（scan-manifest.json 宣告）"
  echo
  echo "| assetType | 資源數 |"
  echo "|---|---:|"
  printf '%s\n' "${covered_lines[@]}"
} > "$OUT"

echo "coverage-check：合計 ${tot} 型（已覆蓋 ${c_cov}／k8s ${c_k8s}／meta ${c_meta}／待分類缺口 ${c_gap}）→ $OUT"
