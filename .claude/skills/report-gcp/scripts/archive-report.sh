#!/usr/bin/env bash
# 把本期的報告與五支柱 findings 存檔到 archive/<期別>/
#
# 用法（從專案根目錄）：bash .claude/skills/report-gcp/scripts/archive-report.sh （由 /report-gcp 階段 ⑥ 呼叫）
#       bash .claude/skills/report-gcp/scripts/archive-report.sh 2026-06  （手動指定期別）
#
# 存檔放在頂層 archive/，**不要放在 report/ 底下**——
#   report/ 是每跑一次就被清空／覆蓋的目錄，把歷史存檔放進去等於「清報告時順手毀掉歷史」。
#
# 為什麼要有這支：
#   report/ 與 findings/ 都被 .gitignore 全部忽略，且每跑一次就整份覆蓋——上一期的報告會直接消失。
#   存檔之後才能做「跨期回歸檢查」：這一期消失或降級的發現，必須交代理由。
#
# archive/ 同樣含專案資訊，一併 gitignore，不進版控、不外傳。

set -u
WORK_ROOT="$PWD"
if [ ! -d "$WORK_ROOT/.claude/skills/report-gcp" ]; then
  echo "錯誤：請從裝有本 skill 的專案根目錄執行（cwd 下找不到 .claude/skills/report-gcp）" >&2
  exit 1
fi

PERIOD="${1:-}"
if [ -z "$PERIOD" ]; then
  PERIOD="$(jq -r '.period // empty' data/scan-meta.json 2>/dev/null || true)"
fi
if [ -z "$PERIOD" ]; then
  echo "錯誤：無法決定期別（data/scan-meta.json 缺 period），請手動指定：bash .claude/skills/report-gcp/scripts/archive-report.sh 2026-06" >&2
  exit 1
fi

DEST="archive/$PERIOD"

if [ ! -f "report/GCP架構報告.md" ]; then
  echo "錯誤：找不到 report/GCP架構報告.md，沒有東西可存檔" >&2
  exit 1
fi

mkdir -p "$DEST"
N=0
for f in "report/GCP架構報告.md" "report/report-data.json" "report/gcp-report.html"; do
  [ -f "$f" ] && { cp "$f" "$DEST/"; N=$((N + 1)); }
done
mkdir -p "$DEST/findings"
for f in findings/*.md; do
  [ -f "$f" ] && { cp "$f" "$DEST/findings/"; N=$((N + 1)); }
done

# 一併留下掃描中繼資料，日後才知道這份報告是掃了哪個專案／什麼時候
[ -f "data/scan-meta.json" ] && cp data/scan-meta.json "$DEST/"

echo "已存檔 $N 個檔案到 $DEST/"
ls "$DEST" | sed 's/^/  /'
