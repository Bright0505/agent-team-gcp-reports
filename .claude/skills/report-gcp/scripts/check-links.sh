#!/usr/bin/env bash
# Google Cloud 官方文件連結有效性檢查（確定性，不經過 LLM）
# 只對 Google 文件站發 HTTP GET，不碰 GCP 專案、不需要憑證。
#
# 用法：bash .claude/skills/report-gcp/scripts/check-links.sh [檔案或目錄...]
#       bash .claude/skills/report-gcp/scripts/check-links.sh --probe <url>   # 除錯：印出判別訊號
#   預設檢查 skill 內整個 references/ 目錄（依支柱拆分的 gcp-docs-*.md）；
#   也可指定 findings/*.md report/*.md 檢查報告內的連結。
#   退出碼：有「確認失效」的連結 exit 1；只有「無法連線（網路問題）」exit 0 但列警告。
#
# 判別方式（實測 cloud.google.com 的行為後訂定，勿憑印象改）：
#   1. HTTP 狀態碼 >= 400            → 失效。cloud.google.com 對不存在的文件頁**會**正確回 404
#      （這點與 docs.aws.amazon.com 不同，AWS 站的 404 仍回 200）。
#   2. <title> 含 404 / Page Not Found → 失效（保險層：狀態碼被 CDN 改寫時仍抓得到）。
#   3. 本體 < MIN_BYTES               → 失效（只回到殼、沒有內容）。
#   4. 內容中找不到文章主體標記（devsite-article / devsite-book-nav）→ 標為「可疑」而非失效：
#      Google 對某些路徑會回一個 JS 導向殼（狀態碼 200、無 title），真假頁都長一樣，
#      無法只靠 HTTP 層分辨。**可疑項不讓檢查失敗，但會列出來要求人工確認**——
#      寧可要求人看一眼，也不要謊報「全數有效」。
#   curl 失敗/空回應 ≠ 失效——那是網路問題，重試一次後仍失敗則標「無法連線」，
#   與「確認失效」分開計（暫時性網路抖動不該讓確定性檢查閘出假警報）。
#
# 連結以 xargs -P8 平行檢查（序列跑最壞會被單一慢站放大到分鐘級）。

set -u
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

MIN_BYTES=3000     # 小於此值視為只回到殼
BIG_PAGE=1000000   # 大於此值即使無文章主體標記也視為有效（行銷／定價頁；實測 1.5–5.6MB）

probe() {  # $1=url → 印 "status<TAB>bytes<TAB>title<TAB>has_article"
  local url="$1" tmp code n title art
  tmp="$(mktemp)"
  code="$(curl -sSL -o "$tmp" -w '%{http_code}' --max-time 25 \
          -A 'Mozilla/5.0 gcp-report-link-check' "$url" 2>/dev/null || echo 000)"
  n="$(wc -c < "$tmp" | tr -d ' ')"
  title="$(grep -oiE '<title>[^<]*</title>' "$tmp" | head -1 \
           | sed -E 's|</?[Tt][Ii][Tt][Ll][Ee]>||g' | tr -d '\n')"
  if grep -qE 'devsite-article|devsite-book-nav|devsite-main-content' "$tmp"; then
    art=yes
  else
    art=no
  fi
  rm -f "$tmp"
  printf '%s\t%s\t%s\t%s\n' "$code" "$n" "$title" "$art"
}

# ── 除錯模式：印出單一 URL 的判別訊號 ───────────────────────────────
if [ "${1:-}" = "--probe" ]; then
  IFS=$'\t' read -r code n title art <<< "$(probe "$2")"
  printf 'url=%s\n  status=%s bytes=%s article_markers=%s\n  title=%s\n' "$2" "$code" "$n" "$art" "$title"
  exit 0
fi

# ── 單一 URL 檢查模式（由 xargs 平行呼叫自身）────────────────────────
if [ "${1:-}" = "--check-one" ]; then
  url="$2"
  # 暫時性狀態（429 節流、5xx）與真失效（404/410）必須分開：8 路平行打同一個網域時
  # 偶發 429／503 很正常，把它算成「確認失效」會在無人值守流程裡放假警報
  # （2026-07-21 實跑就出現過一次：同一批連結重跑即全數有效）。
  transient() { [ "$1" = "429" ] || [ "$1" = "408" ] || { [ "$1" -ge 500 ] 2>/dev/null; }; }
  IFS=$'\t' read -r code n title art <<< "$(probe "$url")"
  if [ "$code" = "000" ] || [ "${n:-0}" -eq 0 ] || transient "$code"; then
    sleep 3
    IFS=$'\t' read -r code n title art <<< "$(probe "$url")"   # 重試一次：區分網路抖動／節流與真失效
  fi
  if [ "$code" = "000" ] || [ "${n:-0}" -eq 0 ]; then
    printf 'UNREACHABLE\t%s\t連線失敗（重試一次後仍無回應，網路問題非失效）\n' "$url"
  elif transient "$code"; then
    printf 'UNREACHABLE\t%s\tHTTP %s（節流或伺服器暫時性錯誤，非失效；稍後重跑確認）\n' "$url" "$code"
  elif [ "$code" -ge 400 ] 2>/dev/null; then
    printf 'DEAD\t%s\tHTTP %s\n' "$url" "$code"
  # 標題比對刻意收緊：只認站方 404 頁的固定樣式（開頭的 404，或 "Page Not Found"）。
  # 不可寬鬆比對「404」三字——講解 HTTP 404 的正常文件頁標題也會含它，會誤殺。
  elif printf %s "$title" | grep -qiE '^404([^0-9]|$)|Page Not Found'; then
    printf 'DEAD\t%s\t標題：%s\n' "$url" "$title"
  elif [ "$n" -lt "$MIN_BYTES" ]; then
    printf 'DEAD\t%s\t本體僅 %s 位元組（只回到殼）\n' "$url" "$n"
  elif [ "$art" = "no" ] && [ "$n" -ge "$BIG_PAGE" ]; then
    # 行銷／定價／計算機頁不是 devsite 文件頁，沒有 article 標記但本體很大（實測 1.5–5.6MB）。
    # 這類頁面是有效目標，不該被標成可疑；只有「中等大小又沒有主體標記」才可疑。
    printf 'OK\t%s\t\n' "$url"
  elif [ "$art" = "no" ]; then
    printf 'SUSPECT\t%s\tHTTP 200 但找不到文章主體標記（%s 位元組）——請人工開啟確認\n' "$url" "$n"
  else
    printf 'OK\t%s\t\n' "$url"
  fi
  exit 0
fi

# ── 主模式 ──────────────────────────────────────────────────────────
FILES=("$@")
[ ${#FILES[@]} -eq 0 ] && FILES=("$SKILL_DIR/references")

# 主機清單要含 docs.cloud.google.com——Google 文件會在兩個網域間搬遷，
# 漏掉它等於那些連結完全不受檢查（2026-07-21 就有一條 docs.cloud… 連結靜默逃過檢查）。
URLS="$(grep -rhoE 'https://(docs\.)?(cloud|developers|support|www)\.google\.com/[^ )">]*' "${FILES[@]}" 2>/dev/null \
        | sed 's/[.,)]*$//' | sort -u)"

if [ -z "$URLS" ]; then
  echo "找不到任何 Google Cloud 連結：${FILES[*]}" >&2
  exit 1
fi

TOTAL="$(printf '%s\n' "$URLS" | wc -l | tr -d ' ')"
echo "檢查 $TOTAL 個連結（來源：${FILES[*]}；8 路平行）"
echo ""

RESULTS="$(printf '%s\n' "$URLS" | xargs -P 8 -I {} bash "$0" --check-one "{}")"

DEAD_N=0; UNREACH_N=0; SUSPECT_N=0
while IFS=$'\t' read -r status url detail; do
  case "$status" in
    OK)          echo "  ok       $url" ;;
    DEAD)        echo "  失效     $url"; echo "           （${detail}）"; DEAD_N=$((DEAD_N + 1)) ;;
    SUSPECT)     echo "  ⚠️ 可疑   $url"; echo "           （${detail}）"; SUSPECT_N=$((SUSPECT_N + 1)) ;;
    UNREACHABLE) echo "  ⚠️ 連不上 $url"; echo "           （${detail}）"; UNREACH_N=$((UNREACH_N + 1)) ;;
  esac
done <<< "$RESULTS"

echo ""
[ "$SUSPECT_N" -gt 0 ] && echo "（$SUSPECT_N 個可疑：HTTP 200 但無文章主體標記，請人工開啟確認後再交付）"
if [ "$DEAD_N" -gt 0 ]; then
  echo "=== 有 $DEAD_N / $TOTAL 個連結確認失效，請更新 references/ 下對應支柱的目錄檔 ==="
  [ "$UNREACH_N" -gt 0 ] && echo "（另有 $UNREACH_N 個連不上——網路問題，稍後重跑確認）"
  exit 1
fi
if [ "$UNREACH_N" -gt 0 ]; then
  echo "=== 無確認失效；$UNREACH_N / $TOTAL 個連不上（網路問題，稍後重跑確認），其餘正常 ==="
  exit 0
fi
echo "=== $TOTAL 個連結全數有效 ==="
