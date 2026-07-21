#!/usr/bin/env node
/**
 * 確定性報告產生器：report-data.json + 模板 + 主題 → report/gcp-report.html
 * 不經過任何 LLM；同樣輸入必得同樣輸出。
 *
 * 用法：
 *   node .claude/skills/report-gcp/scripts/build-report.js
 *   node .claude/skills/report-gcp/scripts/build-report.js --data report/report-data.json \
 *     --template templates/report.html.template \
 *     --theme templates/themes/default.css \
 *     --out report/gcp-report.html
 *   node .claude/skills/report-gcp/scripts/build-report.js --standalone   # 包成完整 HTML 供本機直接開啟
 *   node .claude/skills/report-gcp/scripts/build-report.js --masked       # 對外分享版：做遮罩防呆檢查
 *
 * 預設為正式上線版，不遮罩、不檢查。--masked 供使用者要求對外分享版時使用：
 * 發現專案編號、服務帳戶金鑰或 API key 樣式即失敗退出。
 */
'use strict';

const fs = require('fs');
const path = require('path');

// 兩種根分離：模板/主題跟著 skill 目錄（本檔上一層），資料/輸出跟著執行時的 cwd（專案根目錄）
const SKILL_ROOT = path.resolve(__dirname, '..');
const WORK_ROOT = process.cwd();

// ---------- 參數 ----------
function parseArgs(argv) {
  const opts = {
    data: 'report/report-data.json',
    template: 'templates/report.html.template',
    theme: 'templates/themes/default.css',
    out: 'report/gcp-report.html',
    standalone: false,
    masked: false,
  };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--standalone') opts.standalone = true;
    else if (a === '--masked') opts.masked = true;
    else if (a.startsWith('--') && a.slice(2) in opts) {
      const v = argv[++i];
      if (v === undefined) fail(`${a} 缺少值`);
      opts[a.slice(2)] = v;
    }
    else fail(`未知參數：${a}`);
  }
  for (const k of ['template', 'theme']) {
    opts[k] = path.isAbsolute(opts[k]) ? opts[k] : path.join(SKILL_ROOT, opts[k]);
  }
  for (const k of ['data', 'out']) {
    opts[k] = path.isAbsolute(opts[k]) ? opts[k] : path.join(WORK_ROOT, opts[k]);
  }
  return opts;
}

function fail(msg) {
  console.error(`build-report 錯誤：${msg}`);
  process.exit(1);
}

// ---------- HTML 工具 ----------
function esc(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// 有限的行內標記：先 escape，再把 **…** 轉粗體、`…` 轉 code。
// boldTag 對應模板既有樣式（.lede 用 strong、其餘用 b）。
function inline(s, boldTag, codeAttrs) {
  let h = esc(s);
  h = h.replace(/\*\*([^*]+)\*\*/g, `<${boldTag}>$1</${boldTag}>`);
  h = h.replace(/`([^`]+)`/g, `<code${codeAttrs || ''}>$1</code>`);
  return h;
}

// ---------- 迷你模板引擎 ----------
// 語法：{{path}}（escape）、{{&path}}（原樣）、
//       {{#each path}}…{{/each}}、{{#if path}}…{{/if}}、{{#unless path}}…{{/unless}}
// each 內可用 {{.}}、{{@index}}、{{@number}}、{{@first}}、{{@last}}
function parseTemplate(tpl) {
  const re = /\{\{\s*(#each|#if|#unless|\/each|\/if|\/unless|&)?\s*([^{}]*?)\s*\}\}/g;
  const root = { type: 'block', children: [] };
  const stack = [root];
  let last = 0, m;
  while ((m = re.exec(tpl)) !== null) {
    if (m.index > last) stack[stack.length - 1].children.push({ type: 'text', text: tpl.slice(last, m.index) });
    last = re.lastIndex;
    const [, op, expr] = m;
    if (op === '#each' || op === '#if' || op === '#unless') {
      const node = { type: op.slice(1), expr, children: [] };
      stack[stack.length - 1].children.push(node);
      stack.push(node);
    } else if (op && op.startsWith('/')) {
      const open = stack.pop();
      if (!open || open.type !== op.slice(1)) fail(`模板標籤不對稱：{{${op}}} 對到 ${open ? open.type : '（無）'}`);
    } else {
      stack[stack.length - 1].children.push({ type: 'var', expr, raw: op === '&' });
    }
  }
  if (stack.length !== 1) fail(`模板有未關閉的 {{#${stack[stack.length - 1].type}}}`);
  if (last < tpl.length) root.children.push({ type: 'text', text: tpl.slice(last) });
  return root;
}

function lookup(stack, expr) {
  if (expr === '.') return stack[stack.length - 1].value;
  for (let i = stack.length - 1; i >= 0; i--) {
    const frame = stack[i];
    if (expr.startsWith('@')) {
      if (frame.meta && expr in frame.meta) return frame.meta[expr];
      continue;
    }
    let cur = frame.value;
    let found = true;
    for (const key of expr.split('.')) {
      if (cur != null && typeof cur === 'object' && key in cur) cur = cur[key];
      else { found = false; break; }
    }
    if (found) return cur;
  }
  return undefined;
}

function truthy(v) {
  if (Array.isArray(v)) return v.length > 0;
  return Boolean(v);
}

function renderNode(node, stack) {
  switch (node.type) {
    case 'block':
      return node.children.map((c) => renderNode(c, stack)).join('');
    case 'text':
      return node.text;
    case 'var': {
      const v = lookup(stack, node.expr);
      if (v === undefined || v === null) fail(`模板變數無值：{{${node.expr}}}`);
      return node.raw ? String(v) : esc(v);
    }
    case 'if': {
      const v = lookup(stack, node.expr);
      return truthy(v) ? node.children.map((c) => renderNode(c, stack)).join('') : '';
    }
    case 'unless': {
      const v = lookup(stack, node.expr);
      return truthy(v) ? '' : node.children.map((c) => renderNode(c, stack)).join('');
    }
    case 'each': {
      const arr = lookup(stack, node.expr);
      if (arr === undefined) fail(`模板 each 無值：{{#each ${node.expr}}}`);
      if (!Array.isArray(arr)) fail(`模板 each 非陣列：{{#each ${node.expr}}}`);
      return arr
        .map((item, i) =>
          node.children
            .map((c) =>
              renderNode(c, stack.concat({
                value: item,
                meta: { '@index': i, '@number': i + 1, '@first': i === 0, '@last': i === arr.length - 1 },
              }))
            )
            .join('')
        )
        .join('');
    }
  }
}

// ---------- 資料驗證與衍生欄位 ----------
// Google Cloud Well-Architected Framework 五大支柱，順序固定（模板與圖表依此排版）
const PILLAR_DEFS = [
  { id: 'security', name: '安全性', en: 'Security', code: 'SEC' },
  { id: 'reliability', name: '可靠性', en: 'Reliability', code: 'REL' },
  { id: 'performance', name: '效能最佳化', en: 'Performance', code: 'PERF' },
  { id: 'cost', name: '成本最佳化', en: 'Cost', code: 'COST' },
  { id: 'operations', name: '卓越運維', en: 'Operational Excellence', code: 'OPS' },
];
const PILLAR_ID_LIST = PILLAR_DEFS.map((p) => p.id).join('/');
const FINDING_ID_RE = new RegExp(`^(${PILLAR_DEFS.map((p) => p.code).join('|')})-\\d+$`);
const SEV_CLASS = { 高: 'hi', 中: 'mid', 低: 'lo' };
const ROADMAP_CLS = ['now', 'mid', 'later'];

function money(n) {
  if (typeof n !== 'number' || !isFinite(n) || n < 0) fail(`金額必須是非負數字，收到：${JSON.stringify(n)}`);
  const s = Number.isInteger(n) ? String(n) : String(n);
  return '$' + s;
}

function prepare(data) {
  const errs = [];
  const need = (cond, msg) => { if (!cond) errs.push(msg); };

  // meta
  need(data.meta && typeof data.meta === 'object', 'meta 缺漏');
  const meta = data.meta || {};
  for (const k of ['title', 'account', 'scan_date', 'lede']) {
    need(typeof meta[k] === 'string' && meta[k].trim(), `meta.${k} 必填`);
  }
  need(Array.isArray(meta.regions) && meta.regions.length > 0, 'meta.regions 必須是非空陣列');
  if (errs.length) return errs;

  meta.eyebrow = meta.eyebrow || 'Google Cloud Well-Architected Framework · 基礎架構評估';
  meta.regions_display = meta.regions.join('、');
  meta.lede_html = inline(meta.lede, 'strong');

  // pillars：固定四支柱、固定順序
  need(Array.isArray(data.pillars) && data.pillars.length === PILLAR_DEFS.length,
    `pillars 必須恰好 ${PILLAR_DEFS.length} 個（${PILLAR_ID_LIST} 順序固定）`);
  if (errs.length) return errs;
  const totals = { high: 0, medium: 0, low: 0, all: 0 };
  const knownIds = new Set();
  data.pillars.forEach((p, i) => {
    const def = PILLAR_DEFS[i];
    need(p.id === def.id, `pillars[${i}].id 應為 ${def.id}（順序固定），收到 ${p.id}`);
    Object.assign(p, { name: def.name, en: def.en, code: def.code });
    need(Number.isInteger(p.score) && p.score >= 1 && p.score <= 5, `${def.id}.score 必須是 1–5 的整數`);
    for (const k of ['high', 'medium', 'low']) {
      need(Number.isInteger(p[k]) && p[k] >= 0, `${def.id}.${k} 必須是 ≥0 的整數`);
    }
    if (![p.high, p.medium, p.low].every((n) => Number.isInteger(n) && n >= 0)) return;
    p.total = p.high + p.medium + p.low;
    totals.high += p.high; totals.medium += p.medium; totals.low += p.low;
    p.pips = [1, 2, 3, 4, 5].map((n) => ({ on: n <= p.score }));
    need(Array.isArray(p.findings), `${def.id}.findings 必須是陣列（可為空）`);
    (p.findings || []).forEach((f, j) => {
      const at = `${def.id}.findings[${j}]`;
      need(typeof f.id === 'string' && new RegExp(`^${def.code}-\\d+$`).test(f.id), `${at}.id 應為 ${def.code}-<流水號>，收到 ${f.id}`);
      need(f.severity in SEV_CLASS, `${at}.severity 必須是 高/中/低`);
      need(typeof f.title === 'string' && f.title.trim(), `${at}.title 必填`);
      f.sev_class = SEV_CLASS[f.severity];
      f.has_body = Boolean(f.desc || f.rec);
      knownIds.add(f.id);
    });
    // 明細列出的各嚴重度筆數不可超過統計數（統計可含未列出的低風險項）
    for (const [sev, key] of [['高', 'high'], ['中', 'medium'], ['低', 'low']]) {
      const listed = (p.findings || []).filter((f) => f.severity === sev).length;
      need(listed <= p[key], `${def.id}：明細列出 ${sev} ${listed} 項，超過統計數 ${p[key]}`);
    }
  });
  totals.all = totals.high + totals.medium + totals.low;
  data.totals = totals;

  // priorities：1–5 項
  need(Array.isArray(data.priorities) && data.priorities.length >= 1 && data.priorities.length <= 5, 'priorities 必須是 1–5 項');
  (data.priorities || []).forEach((it, i) => {
    need(typeof it.title === 'string' && it.title.trim(), `priorities[${i}].title 必填`);
    need(typeof it.desc === 'string' && it.desc.trim(), `priorities[${i}].desc 必填`);
    need(Array.isArray(it.tags), `priorities[${i}].tags 必須是陣列`);
    (it.tags || []).forEach((t) => {
      const m = String(t).match(FINDING_ID_RE);
      if (m) need(knownIds.has(t), `priorities[${i}] 引用了明細中不存在的發現編號 ${t}`);
    });
  });

  // cost
  need(data.cost && typeof data.cost === 'object', 'cost 缺漏');
  const cost = data.cost || {};
  need(typeof cost.total_monthly === 'number' && cost.total_monthly >= 0, 'cost.total_monthly 必須是 ≥0 數字');
  for (const k of ['cap', 'sub']) need(typeof cost[k] === 'string' && cost[k].trim(), `cost.${k} 必填`);
  need(Array.isArray(cost.items) && cost.items.length > 0, 'cost.items 必須是非空陣列');
  if (errs.length) return errs;
  cost.total_display = money(cost.total_monthly);
  cost.cap_html = inline(cost.cap, 'b');
  const max = Math.max(...cost.items.map((it) => it.amount || 0));
  cost.items.forEach((it, i) => {
    need(typeof it.label === 'string' && it.label.trim(), `cost.items[${i}].label 必填`);
    need(typeof it.amount === 'number' && it.amount >= 0, `cost.items[${i}].amount 必須是 ≥0 數字`);
    it.amount_display = money(it.amount);
    it.pct = max > 0 ? Math.round((it.amount / max) * 100) : 0;
  });

  // roadmap：固定三欄（Quick Wins / 中期 / 長期）
  need(Array.isArray(data.roadmap) && data.roadmap.length === 3, 'roadmap 必須恰好 3 欄（Quick Wins／中期／長期）');
  (data.roadmap || []).forEach((col, i) => {
    need(typeof col.title === 'string' && col.title.trim(), `roadmap[${i}].title 必填`);
    need(typeof col.when === 'string' && col.when.trim(), `roadmap[${i}].when 必填`);
    need(Array.isArray(col.items) && col.items.length > 0, `roadmap[${i}].items 必須是非空陣列`);
    col.cls = ROADMAP_CLS[i];
    col.items_html = (col.items || []).map((s) => inline(s, 'b'));
  });

  // method
  need(data.method && typeof data.method === 'object', 'method 缺漏');
  const method = data.method || {};
  need(Array.isArray(method.items) && method.items.length > 0, 'method.items（掃描方法）必須是非空陣列');
  need(Array.isArray(method.gaps) && method.gaps.length > 0, 'method.gaps（資料缺口）必須是非空陣列');
  if (errs.length) return errs;
  method.items_html = method.items.map((s) => inline(s, 'b', ' class="mask"'));
  method.gaps_html = method.gaps.map((s) => inline(s, 'b', ' class="mask"'));

  return errs;
}

// ---------- 遮罩防呆 ----------
function maskGuard(html) {
  // GCP 版的敏感識別碼樣式（AWS 的 AKIA／帳號 ID 規則不適用，已換掉）
  const rules = [
    [/\b\d{12}\b/g, '疑似未遮罩的 GCP 專案編號（12 位數字）'],
    [/\bAIza[0-9A-Za-z_-]{35}\b/g, '疑似 Google API key'],
    [/-----BEGIN[A-Z ]*PRIVATE KEY-----/g, '疑似服務帳戶私鑰內容'],
    [/"private_key_id"/g, '疑似服務帳戶金鑰 JSON 片段'],
    [/\b[a-z0-9-]+@[a-z0-9-]+\.iam\.gserviceaccount\.com\b/g, '疑似未遮罩的服務帳戶電子郵件'],
    [/\bya29\.[0-9A-Za-z_-]+/g, '疑似 OAuth 存取權杖'],
  ];
  const hits = [];
  for (const [re, label] of rules) {
    let m;
    while ((m = re.exec(html)) !== null) {
      const ctx = html.slice(Math.max(0, m.index - 30), m.index + m[0].length + 30).replace(/\s+/g, ' ');
      hits.push(`${label}：…${ctx}…`);
    }
  }
  return hits;
}

// ---------- 主流程 ----------
function main() {
  // cwd 守衛：data/out 以 cwd 解析，從錯誤目錄呼叫會把輸出寫到意外位置（其餘三支腳本同款守衛）
  if (!fs.existsSync(path.join(WORK_ROOT, '.claude', 'skills', 'report-gcp'))) {
    fail('請從裝有本 skill 的專案根目錄執行（cwd 下找不到 .claude/skills/report-gcp）');
  }
  const opts = parseArgs(process.argv);
  for (const k of ['data', 'template', 'theme']) {
    if (!fs.existsSync(opts[k])) fail(`找不到 ${k} 檔案：${opts[k]}`);
  }

  let data;
  try {
    data = JSON.parse(fs.readFileSync(opts.data, 'utf8'));
  } catch (e) {
    fail(`report-data JSON 解析失敗：${e.message}`);
  }

  const errs = prepare(data);
  if (errs && errs.length) {
    console.error('report-data 驗證失敗：');
    for (const e of errs) console.error(`  - ${e}`);
    process.exit(1);
  }

  data.theme_css = fs.readFileSync(opts.theme, 'utf8').trimEnd();

  const tpl = fs.readFileSync(opts.template, 'utf8');
  let html = renderNode(parseTemplate(tpl), [{ value: data }]);

  if (opts.standalone) {
    const titleMatch = html.match(/<title>.*?<\/title>\n?/s);
    const title = titleMatch ? titleMatch[0].trim() : '';
    const body = titleMatch ? html.replace(titleMatch[0], '') : html;
    html = `<!doctype html>\n<html lang="zh-Hant">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1">\n${title}\n</head>\n<body>\n${body}\n</body>\n</html>\n`;
  }

  if (opts.masked) {
    const hits = maskGuard(html);
    if (hits.length) {
      console.error('遮罩防呆未通過（--masked），輸出已中止：');
      for (const h of hits) console.error(`  - ${h}`);
      console.error('請先在 report-data.json 中遮罩敏感識別碼再重新產生。');
      process.exit(1);
    }
  }

  fs.mkdirSync(path.dirname(opts.out), { recursive: true });
  fs.writeFileSync(opts.out, html);
  console.log(`已產生：${path.relative(WORK_ROOT, opts.out)}（${html.length.toLocaleString('en-US')} bytes${opts.standalone ? '，standalone' : '，Artifact 片段'}${opts.masked ? '，已通過遮罩檢查' : ''}）`);
}

main();
