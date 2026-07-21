#!/usr/bin/env node
/**
 * 確定性架構圖產生器：data/ 掃描產物 → report/gcp-architecture.drawio
 * 不經過任何 LLM；同樣輸入必得同樣輸出。全程只讀本機檔案，不碰 GCP 專案。
 *
 * 用法（從專案根目錄）：
 *   node .claude/skills/gcp-diagram/scripts/build-diagram.js
 *   node .claude/skills/gcp-diagram/scripts/build-diagram.js --out report/gcp-architecture.drawio
 *
 * 頁面結構（資料驅動，不寫死環境名）：
 *   頁 1「全景架構」：全專案一張——雲外入口 ＋ 專案層服務欄 ＋ 各 VPC 網路的暴露通道拓撲
 *   頁 2「架構索引」：使用者 → 外部轉送規則 → 各 VPC 縮略框／Cloud Storage
 *   頁 3..N：每個「有工作負載」的 VPC 網路一頁（完整流量鏈 ＋ 子網表）
 *
 * ── GCP 特有的三件事，本檔的版型正是為了不誤判它們而設計（見 CLAUDE.md）──
 *   1. **沒有公有／私有子網**。GCP 的子網不分層，對外可及性看「VM 有沒有外部 IP」、
 *      對外連出看 Cloud NAT、存取 Google API 看 Private Google Access。
 *      因此本圖的兩條通道是「有外部 IP」vs「僅內部 IP」，**不是**公有／私有子網。
 *      子網方塊橫跨兩條通道之上，明確表示它不屬於任何一層。
 *   2. **防火牆是標籤導向**。一條 allow 0.0.0.0/0 的規則可能一台機器都沒套用，
 *      也可能套用到全網路（沒有 targetTags ＝ 套用到該網路所有 VM）。
 *      本檔把「規則 × VM 標籤／服務帳戶」交叉算出「真的有套用」的規則才畫紅框，
 *      判定邏輯與 report-gcp 的 network-facts.py 同一套（rule_applies）。
 *   3. **VPC 網路是全域的、子網是區域的**。所以層級是「VPC 框內含區域欄」，不是反過來的
 *      「區域框內含 VPC」——一個 VPC 本來就橫跨所有區域。自動模式（auto mode）VPC 會在
 *      每一個 GCP 區域自動建一個子網（實測 43 個），全部畫出來會淹掉整張圖——因此只畫
 *      「有資源參照」的區域，其餘計入 subnetAccounted 並在圖上標明數量
 *      （計數斷言仍然涵蓋全部子網）。
 *
 * 邊一律只畫「可證明的 join」，證明不了就不畫、不猜：
 *   轉送規則→目標代理→URL 對應→後端服務＝selfLink 逐段比對；
 *   後端服務→執行個體群組＝backends[].group 名稱比對；
 *   GKE→MIG＝cluster.instanceGroupUrls 比對（selfLink）；
 *   MIG→VM＝baseInstanceName 前綴（GCP 受管群組的命名規則，非 selfLink，故以虛線標示）；
 *   VM→Cloud SQL＝私有網路對等（privateNetwork == VM 網路）或 VM 外部 IP 落在 authorizedNetworks。
 * Cloud DNS → 負載平衡器**不畫**：scan.sh 只列出 managed-zones、沒有 record set，
 *   對應關係證明不了（寧可少畫一條邊，也不要畫一條猜的）。
 *
 * 版面調整改 LAYOUT / SUM / STYLES 常數；不要在產出的 .drawio 上手改（重跑會覆蓋）。
 */
'use strict';

const fs = require('fs');
const path = require('path');

const WORK_ROOT = process.cwd();
const DATA = (...p) => path.join(WORK_ROOT, 'data', ...p);

// ---------- 參數 ----------
function parseArgs(argv) {
  const opts = { out: 'report/gcp-architecture.drawio' };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--') && a.slice(2) in opts) {
      const v = argv[++i];
      if (v === undefined) fail(`${a} 缺少值`);
      opts[a.slice(2)] = v;
    } else fail(`未知參數：${a}`);
  }
  opts.out = path.isAbsolute(opts.out) ? opts.out : path.join(WORK_ROOT, opts.out);
  return opts;
}

function fail(msg) {
  console.error(`build-diagram 錯誤：${msg}`);
  process.exit(1);
}

// ---------- 讀檔 ----------
// 「空回應」與「查詢失敗」是相反的結論（見 CLAUDE.md）：
//   檔案存在但是 []  → 該類資源確實不存在，是有效證據，照實畫「未設定」
//   檔案不存在        → 掃描失敗（API 未啟用／權限不足）＝資料缺口，記進 GAPS 並在圖上標明
// 絕不可把資料缺口畫成「未設定」。
const GAPS = [];

function readJsonMaybe(p) {
  if (!fs.existsSync(p)) return null;
  const raw = fs.readFileSync(p, 'utf8').trim();
  if (raw === '') return null;
  try {
    return JSON.parse(raw);
  } catch (e) {
    fail(`${path.relative(WORK_ROOT, p)} 不是有效 JSON：${e.message}`);
  }
}

function readJsonRequired(p) {
  if (!fs.existsSync(p)) {
    fail(`缺少掃描產物 ${path.relative(WORK_ROOT, p)}——請先跑 /report-gcp（或至少其階段①掃描）`);
  }
  const j = readJsonMaybe(p);
  if (j === null) fail(`${path.relative(WORK_ROOT, p)} 是空檔（掃描可能中斷），請重跑掃描`);
  return j;
}

// 選配資料：不存在＝掃描失敗＝資料缺口（記錄下來，不當成「沒有這種資源」）
function readListOptional(rel, label) {
  const p = DATA(...rel.split('/'));
  const j = readJsonMaybe(p);
  if (j === null) {
    GAPS.push(`${label}（data/${rel} 不存在或為空＝查詢失敗，非「未設定」）`);
    return [];
  }
  return Array.isArray(j) ? j : [j];
}

// ---------- CIDR ----------
function cidrToRange(cidr) {
  const m = /^(\d+)\.(\d+)\.(\d+)\.(\d+)(?:\/(\d+))?$/.exec(String(cidr || '').trim());
  if (!m) return null;
  const ip = ((+m[1] << 24) | (+m[2] << 16) | (+m[3] << 8) | +m[4]) >>> 0;
  const bits = m[5] === undefined ? 32 : +m[5]; // 裸 IP＝/32（authorizedNetworks 常見寫法）
  const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
  return { base: (ip & mask) >>> 0, mask, bits };
}

function cidrContains(outer, inner) {
  const o = cidrToRange(outer);
  const i = cidrToRange(inner);
  if (!o || !i) return false;
  return o.bits <= i.bits && ((i.base & o.mask) >>> 0) === o.base;
}

// ---------- 共用小工具 ----------
const byName = (a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
// GCP 的資源欄位多半是完整 selfLink URL，取最後一段就是名稱
const last = (u) => (u == null || u === '' ? null : String(u).replace(/\/+$/, '').split('/').pop());
// selfLink 中的區域：.../regions/asia-east1/...
const regionOf = (u) => (/\/regions\/([^/]+)/.exec(String(u || '')) || [])[1] || null;
const zoneToRegion = (z) => (z ? String(z).replace(/-[a-z]$/, '') : null);
const uniq = (arr) => [...new Set(arr)];

// ---------- 防火牆：規則是否套用到這台 VM ----------
// 與 report-gcp 的 network-facts.py 同一套判定（刻意重做一次，讓本檔可獨立執行）：
// 同網路 ＋（無 targetTags 且無 targetServiceAccounts ＝ 套用到該網路所有 VM）
// 這是 GCP 防火牆最常被忽略的語意，也是「規則存在 ≠ 真的暴露」的關鍵。
function ruleApplies(rule, vm) {
  if (last(rule.network) !== vm.network) return false;
  const tags = new Set(rule.targetTags || []);
  const sas = new Set(rule.targetServiceAccounts || []);
  if (!tags.size && !sas.size) return true;
  if ((vm.tags || []).some((t) => tags.has(t))) return true;
  return (vm.serviceAccounts || []).some((e) => sas.has(e));
}

function portsOf(allowed) {
  return (allowed || []).map((a) => {
    const p = a.ports || [];
    return `${a.IPProtocol || '?'}:${p.length ? p.join(',') : 'all'}`;
  });
}

// ---------- 載入資料模型 ----------
function loadModel() {
  const meta = readJsonRequired(DATA('scan-meta.json'));
  const project = meta.project || fail('scan-meta.json 缺 project');

  const networksRaw = readJsonRequired(DATA('network', 'networks.json'));
  const subnetsRaw = readJsonRequired(DATA('network', 'subnets.json'));
  const fw = readJsonRequired(DATA('network', 'firewall-rules.json'));

  const routers = readListOptional('network/routers.json', 'Cloud Router／Cloud NAT');
  const addresses = readListOptional('network/addresses.json', '保留 IP 位址');
  const migsRaw = readListOptional('compute/instance-groups.json', '受管執行個體群組');
  const gkesRaw = readListOptional('compute/gke-clusters.json', 'GKE 叢集');
  const runsRaw = readListOptional('compute/run-services.json', 'Cloud Run 服務');
  const fnsRaw = readListOptional('compute/functions.json', 'Cloud Functions');
  const frsRaw = readListOptional('lb/forwarding-rules.json', '轉送規則（負載平衡前端）');
  const bssRaw = readListOptional('lb/backend-services.json', '後端服務');
  const urlMaps = readListOptional('lb/url-maps.json', 'URL 對應');
  const httpsProxies = readListOptional('lb/target-https-proxies.json', 'HTTPS 目標代理');
  const httpProxies = readListOptional('lb/target-http-proxies.json', 'HTTP 目標代理');
  const sqlsRaw = readListOptional('db/sql-instances.json', 'Cloud SQL 執行個體');
  const bucketsRaw = readListOptional('storage/buckets.json', 'Cloud Storage 值區');
  const dnsZones = readListOptional('ops/dns-zones.json', 'Cloud DNS 區域');
  const sinks = readListOptional('ops/logging-sinks.json', 'Cloud Logging 匯出 sink');
  const alerts = readListOptional('ops/monitoring-policies.json', 'Cloud Monitoring 告警政策');
  const uptime = readListOptional('ops/uptime-checks.json', 'Uptime check');
  const armor = readListOptional('lb/security-policies.json', 'Cloud Armor 安全政策');
  const orgPolicies = readListOptional('global/org-policies.json', '組織政策（專案層）');
  const serviceAccounts = readListOptional('global/iam-service-accounts.json', '服務帳戶');

  // ---- VM：優先讀原始檔（保有 subnetwork 的完整 URL，能取出區域）----
  // 自動模式 VPC 的子網全部叫 "default"，只看名稱會撞在一起，必須加上區域才唯一。
  const vmRaw = readJsonMaybe(DATA('compute', 'instances.json'));
  let vms;
  if (vmRaw) {
    vms = vmRaw.map((v) => {
      const ni = (v.networkInterfaces || [])[0] || {};
      const zone = last(v.zone);
      return {
        name: v.name,
        zone,
        region: zoneToRegion(zone),
        machineType: last(v.machineType),
        status: v.status,
        tags: (v.tags || {}).items || [],
        serviceAccounts: (v.serviceAccounts || []).map((s) => s.email).filter(Boolean),
        network: last(ni.network),
        subnet: last(ni.subnetwork),
        // 子網區域優先取 subnetwork URL，取不到才用可用區推導（子網一定與 VM 同區域）
        subnetRegion: regionOf(ni.subnetwork) || zoneToRegion(zone),
        internalIP: ni.networkIP || null,
        externalIPs: (ni.accessConfigs || []).map((ac) => ac.natIP || '(已設定，尚未配發)'),
      };
    });
  } else {
    // 退回 digest 投影：subnetwork 已被截成名稱，區域只能靠可用區推導（結果相同）
    const dg = readJsonMaybe(DATA('digest', 'compute-instances.json'));
    if (dg === null) fail('缺少 data/compute/instances.json 與 data/digest/compute-instances.json——請先跑掃描');
    vms = dg.map((v) => {
      const ni = (v.networkInterfaces || [])[0] || {};
      return {
        name: v.name,
        zone: v.zone,
        region: zoneToRegion(v.zone),
        machineType: v.machineType,
        status: v.status,
        tags: v.tags || [],
        serviceAccounts: (v.serviceAccounts || []).map((s) => s.email).filter(Boolean),
        network: ni.network || null,
        subnet: ni.subnetwork || null,
        subnetRegion: zoneToRegion(v.zone),
        internalIP: ni.networkIP || null,
        externalIPs: (ni.accessConfigs || []).map((ac) => ac.natIP || '(已設定，尚未配發)'),
      };
    });
  }
  vms.sort(byName);

  // ---- 防火牆：只留「有效的 INGRESS allow」，並算出每台 VM 實際套用到的規則 ----
  const ingressAllow = fw.filter(
    (r) => (r.direction || 'INGRESS') === 'INGRESS' && !r.disabled && (r.allowed || []).length
  );
  const denyRules = fw.filter((r) => (r.direction || 'INGRESS') === 'INGRESS' && !r.disabled && (r.denied || []).length);
  for (const vm of vms) {
    const applied = ingressAllow.filter((r) => ruleApplies(r, vm));
    vm.fwRules = applied.map((r) => ({
      name: r.name,
      priority: r.priority,
      ports: portsOf(r.allowed),
      world: (r.sourceRanges || []).includes('0.0.0.0/0'),
    }));
    // 「真的暴露」＝ 有外部 IP ＋ 套用到來源 0.0.0.0/0 的 allow 規則。兩者缺一不可。
    vm.worldPorts = uniq(vm.fwRules.filter((r) => r.world).flatMap((r) => r.ports)).sort();
    vm.exposed = vm.externalIPs.length > 0 && vm.worldPorts.length > 0;
  }

  // ---- Cloud NAT 覆蓋：子網有沒有對外連出的路徑 ----
  const natAllNets = new Set(); // 覆蓋整個網路的 NAT
  const natBySubnet = new Map(); // region/子網名 → NAT 名（同名子網跨區域，必須加區域才唯一）
  for (const rt of routers) {
    const net = last(rt.network);
    const rtRegion = last(rt.region);
    for (const nat of rt.nats || []) {
      if (nat.sourceSubnetworkIpRangesToNat === 'ALL_SUBNETWORKS_ALL_IP_RANGES') natAllNets.add(net);
      for (const sn of nat.subnetworks || []) {
        natBySubnet.set(`${regionOf(sn.name) || rtRegion}/${last(sn.name)}`, nat.name);
      }
    }
  }

  const subnets = subnetsRaw
    .map((s) => {
      const region = last(s.region);
      const net = last(s.network);
      const key = `${region}/${s.name}`;
      let nat = null;
      if (natAllNets.has(net)) nat = '整個網路';
      else if (natBySubnet.has(key)) nat = natBySubnet.get(key);
      return {
        key,
        name: s.name,
        network: net,
        region,
        cidr: s.ipCidrRange,
        purpose: s.purpose || 'PRIVATE',
        privateGoogleAccess: !!s.privateIpGoogleAccess,
        flowLogs: !!(s.logConfig || {}).enable,
        nat,
      };
    })
    .sort((a, b) => (a.key < b.key ? -1 : 1));

  // ---- 受管執行個體群組（MIG）與 GKE ----
  // MIG → VM 是**命名規則**的 join（baseInstanceName 前綴），不是 selfLink，故圖上以虛線標示。
  const migs = migsRaw
    .map((g) => {
      const zone = last(g.zone) || last(g.region);
      const members = vms.filter((v) => g.baseInstanceName && v.name.startsWith(`${g.baseInstanceName}-`));
      return {
        name: g.name,
        zone,
        region: last(g.region) || zoneToRegion(zone),
        base: g.baseInstanceName,
        size: Number(g.size || 0),
        targetSize: Number(g.targetSize || 0),
        autoscaled: String(g.autoscaled) === 'true' || g.autoscaled === true,
        members,
        network: (members[0] || {}).network || null,
      };
    })
    .sort(byName);
  const migByName = new Map(migs.map((m) => [m.name, m]));

  // GKE → MIG 是 selfLink join（cluster.instanceGroupUrls），可證明
  const gkes = gkesRaw
    .map((c) => {
      const igNames = (c.instanceGroupUrls || []).map(last);
      const clusterMigs = igNames.map((n) => migByName.get(n)).filter(Boolean);
      return {
        name: c.name,
        location: c.location,
        mode: (c.autopilot || {}).enabled ? 'Autopilot' : 'Standard',
        network: last(c.network) || c.network,
        subnet: last(c.subnetwork) || c.subnetwork,
        nodeCount: c.currentNodeCount || 0,
        version: c.currentMasterVersion,
        privateNodes: !!(c.privateClusterConfig || {}).enablePrivateNodes,
        privateEndpoint: !!(c.privateClusterConfig || {}).enablePrivateEndpoint,
        authorizedNetworks: ((c.masterAuthorizedNetworksConfig || {}).cidrBlocks || []).map((b) => b.cidrBlock),
        migs: clusterMigs,
        members: uniq(clusterMigs.flatMap((m) => m.members)),
      };
    })
    .sort(byName);
  const migInGke = new Set(gkes.flatMap((g) => g.migs.map((m) => m.name)));

  // ── 未受管執行個體群組 ────────────────────────────────────────────
  // 負載平衡器的後端很常是**未受管**群組（GKE 自建的 k8s-ig--*、人工建立的群組），
  // 它們不在 `instance-groups managed list` 裡。少了它們，「後端服務 → 群組」這段鏈會斷掉，
  // 而且是靜默斷掉（邊找不到目標就跳過）——正式環境對外 LB 的後端因此整個看不見。
  // instance-groups-all.json 由 scan.sh 的 `compute instance-groups list` 產生；
  // 舊的掃描資料沒有這個檔，此時退回「只有受管群組」，未解析的群組改畫佔位節點（見 UNRESOLVED_GROUPS）。
  const allGroupsRaw = readJsonMaybe(DATA('compute', 'instance-groups-all.json'));
  if (allGroupsRaw === null) {
    GAPS.push('未受管執行個體群組（data/compute/instance-groups-all.json 不存在＝此份掃描資料早於該項目，請重跑掃描）');
  }
  const unmanaged = (allGroupsRaw || [])
    .filter((g) => !migByName.has(g.name))
    .map((g) => {
      const zone = last(g.zone) || last(g.region);
      return {
        name: g.name,
        zone,
        region: last(g.region) || zoneToRegion(zone),
        unmanaged: true,
        size: Number(g.size || 0),
        targetSize: Number(g.size || 0),
        autoscaled: false,
        // 未受管群組沒有 baseInstanceName，成員要靠 listInstances 才知道（本流程未掃），
        // 因此成員一律留空——**不要用名稱前綴猜**，那會編造出不存在的關聯。
        members: [],
        network: last(g.network),
      };
    })
    .sort(byName);
  for (const g of unmanaged) migByName.set(g.name, g);

  // MIG 的網路歸屬原本靠成員 VM 推導，但**節點數為 0 的 MIG 沒有成員**，會推不出網路而掉出所有
  // VPC 之外（計數斷言首次實跑就抓到：6 個 MIG 只畫出 3 個）。GKE 擁有的 MIG 改用叢集的網路補上。
  for (const g of gkes) {
    for (const m of g.migs) if (!m.network) m.network = g.network;
  }

  // ---- 負載平衡鏈：轉送規則 → 目標代理 → URL 對應 → 後端服務 → 執行個體群組 ----
  const bss = bssRaw
    .map((b) => ({
      name: b.name,
      region: last(b.region) || 'global',
      scheme: b.loadBalancingScheme || '?',
      protocol: b.protocol,
      port: b.port || null,
      cdn: b.enableCDN === true,
      securityPolicy: last(b.securityPolicy),
      iap: !!(b.iap || {}).enabled,
      logging: !!(b.logConfig || {}).enable,
      healthChecks: uniq((b.healthChecks || []).map(last)),
      groups: uniq((b.backends || []).map((k) => last(k.group)).filter(Boolean)),
    }))
    .sort(byName);
  const bsByName = new Map(bss.map((b) => [b.name, b]));

  const proxies = [...httpsProxies, ...httpProxies].map((p) => ({
    name: p.name,
    kind: (p.sslCertificates || []).length ? 'HTTPS' : 'HTTP',
    urlMap: last(p.urlMap),
    certs: (p.sslCertificates || []).map(last),
    sslPolicy: last(p.sslPolicy),
  }));
  const proxyByName = new Map(proxies.map((p) => [p.name, p]));

  const urlMapByName = new Map(
    urlMaps.map((u) => [
      u.name,
      {
        name: u.name,
        // pathMatchers 的 defaultService 與 pathRules[].service 都算「這張 URL 對應會導到的後端」
        services: uniq(
          [
            last(u.defaultService),
            ...(u.pathMatchers || []).flatMap((pm) => [
              last(pm.defaultService),
              ...(pm.pathRules || []).map((r) => last(r.service)),
            ]),
          ].filter(Boolean)
        ),
        hosts: uniq((u.hostRules || []).flatMap((h) => h.hosts || [])),
      },
    ])
  );

  const frs = frsRaw
    .map((f) => {
      const scheme = f.loadBalancingScheme || null;
      const proxyName = last(f.target);
      const proxy = proxyName ? proxyByName.get(proxyName) || null : null;
      const um = proxy && proxy.urlMap ? urlMapByName.get(proxy.urlMap) || null : null;
      // 後端服務：內部 LB 直接掛 backendService；外部 HTTP(S) LB 要走 proxy → urlMap
      const bsNames = f.backendService ? [last(f.backendService)] : um ? um.services : [];
      return {
        name: f.name,
        region: last(f.region) || 'global',
        scheme,
        // scheme 為 null＝Private Service Connect 端點（如 Memorystore 的 sca-auto-fr-*），
        // 它不是負載平衡器，照實標示，不要混進 LB 帶裡誤導讀者
        isPsc: !scheme && !!f.target && !f.backendService,
        external: /^EXTERNAL/.test(scheme || ''),
        ip: f.IPAddress,
        protocol: f.IPProtocol,
        ports: (f.ports || []).length ? f.ports : f.portRange ? [f.portRange] : [],
        network: last(f.network),
        subnet: last(f.subnetwork),
        subnetRegion: regionOf(f.subnetwork) || last(f.region),
        proxy,
        urlMap: um,
        bsNames,
        backendServices: bsNames.map((n) => bsByName.get(n)).filter(Boolean),
      };
    })
    .sort(byName);

  // ── 後端服務指向、但掃描資料裡查不到的群組 → 畫成佔位節點，不要靜默跳過 ──
  // 「證明不了就不畫」講的是**關聯**；這裡群組被 backend-service 明白指名，存在本身是有證據的，
  // 只是它的組態沒掃到。靜默跳過會讓流量鏈憑空斷在後端服務，讀圖的人只會以為「後面沒東西了」，
  // 那比畫一個誠實標示「未掃描到」的節點更容易誤導。
  const referencedGroups = uniq(bss.flatMap((b) => b.groups));
  const unresolvedGroups = referencedGroups
    .filter((n) => !migByName.has(n))
    .map((n) => {
      // 網路歸屬取自「指向這個群組的後端服務」所屬的轉送規則——轉送規則自己就帶 network，可證明
      const fr = frs.find((f) => f.backendServices.some((b) => b.groups.includes(n)));
      return {
        name: n,
        unresolved: true,
        zone: null,
        region: null,
        size: 0,
        targetSize: 0,
        autoscaled: false,
        members: [],
        network: fr ? fr.network : null,
      };
    })
    .sort(byName);
  // 圖上「執行個體群組」一律指這三種的聯集；migs 單獨保留給 GKE 的 selfLink join 用
  const groups = [...migs, ...unmanaged, ...unresolvedGroups];
  for (const g of unresolvedGroups) migByName.set(g.name, g);

  // ---- Cloud SQL ----
  const sqls = sqlsRaw
    .map((db) => {
      const st = db.settings || {};
      const ipc = st.ipConfiguration || {};
      const bkp = st.backupConfiguration || {};
      const publicIP = (db.ipAddresses || []).find((a) => a.type === 'PRIMARY');
      const privateIP = (db.ipAddresses || []).find((a) => a.type === 'PRIVATE');
      const authNets = (ipc.authorizedNetworks || []).map((a) => a.value).filter(Boolean);
      const sslMode = ipc.sslMode || (ipc.requireSsl ? 'REQUIRED' : '未強制');
      return {
        name: db.name,
        region: db.region,
        version: db.databaseVersion,
        availability: st.availabilityType || '?',
        isReplica: db.instanceType === 'READ_REPLICA_INSTANCE',
        master: db.masterInstanceName ? String(db.masterInstanceName).split(':').pop() : null,
        publicIP: publicIP ? publicIP.ipAddress : null,
        privateIP: privateIP ? privateIP.ipAddress : null,
        privateNetwork: last(ipc.privateNetwork),
        authNets,
        openToWorld: authNets.includes('0.0.0.0/0'),
        sslMode,
        // ALLOW_UNENCRYPTED_AND_ENCRYPTED ＝ 明文連線是被允許的，等同未強制加密
        sslEnforced: /^(REQUIRED|ENCRYPTED_ONLY|TRUSTED_CLIENT_CERTIFICATE_REQUIRED)$/.test(sslMode),
        backup: !!bkp.enabled,
        // 網路歸屬：私有 IP 走 PSA 對等，掛在 privateNetwork 上；只有公開 IP 者不屬於任何 VPC
        network: last(ipc.privateNetwork),
      };
    })
    .sort(byName);

  const buckets = bucketsRaw
    .map((b) => ({
      name: b.name,
      location: b.location || '?',
      // gcloud storage 回 snake_case、JSON API 回 camelCase，兩種都要接（digest.sh 有同樣的教訓註解）
      pap: b.public_access_prevention || (b.iamConfiguration || {}).publicAccessPrevention || '?',
      ubla:
        (b.uniform_bucket_level_access !== undefined
          ? b.uniform_bucket_level_access
          : ((b.iamConfiguration || {}).uniformBucketLevelAccess || {}).enabled) === true,
    }))
    .sort(byName);

  // ---- VPC 網路：把上面所有東西掛到各自的網路上 ----
  const networks = networksRaw
    .map((n) => {
      const nv = {
        name: n.name,
        auto: n.autoCreateSubnetworks === true,
        mode: n.x_gcloud_subnet_mode || (n.autoCreateSubnetworks ? 'AUTO' : 'CUSTOM'),
        routing: (n.routingConfig || {}).routingMode || '?',
      };
      nv.subnets = subnets.filter((s) => s.network === n.name);
      nv.vms = vms.filter((v) => v.network === n.name);
      // migs＝只有受管群組（GKE 的 selfLink join 與 MIG→VM 前綴推導都只對它成立）
      // groups＝圖上要畫的全部群組（受管＋未受管＋後端服務指名但未掃到的佔位）
      nv.migs = migs.filter((m) => m.network === n.name);
      nv.groups = groups.filter((m) => m.network === n.name);
      nv.gkes = gkes.filter((g) => g.network === n.name);
      nv.frs = frs.filter((f) => f.network === n.name);
      nv.sqls = sqls.filter((d) => d.network === n.name);
      nv.routers = routers.filter((r) => last(r.network) === n.name);
      nv.regions = uniq(nv.subnets.map((s) => s.region)).sort();
      // 「有資源參照」的區域：自動模式 VPC 有 40+ 個自動子網，只畫這些區域，其餘摺疊
      nv.activeRegions = uniq(
        [
          ...nv.vms.map((v) => v.subnetRegion),
          ...nv.frs.map((f) => f.subnetRegion || f.region),
          ...nv.migs.map((m) => m.region),
          ...nv.gkes.map((g) => g.location),
          ...nv.sqls.map((d) => d.region),
          ...nv.routers.map((r) => last(r.region)),
        ].filter(Boolean)
      ).sort();
      // 自訂模式（子網是人為建立的）一律全畫；自動模式只畫有資源的區域
      nv.shownRegions = nv.auto ? nv.regions.filter((r) => nv.activeRegions.includes(r)) : nv.regions;
      if (nv.auto && nv.shownRegions.length === 0 && nv.regions.length) nv.shownRegions = [nv.regions[0]];
      nv.shownSubnets = nv.subnets.filter((s) => nv.shownRegions.includes(s.region));
      nv.hiddenSubnets = nv.subnets.filter((s) => !nv.shownRegions.includes(s.region));
      nv.hasWorkload = nv.vms.length + nv.frs.length + nv.groups.length + nv.gkes.length + nv.sqls.length > 0;
      return nv;
    })
    .sort(byName);

  // 沒有掛到任何網路的 Cloud SQL（只有公開 IP，不在 VPC 內）——照實另外畫，不要塞進某個 VPC
  const orphanSqls = sqls.filter((d) => !d.network || !networks.some((n) => n.name === d.network));

  // ---- VM → Cloud SQL 的可證明連線 ----
  // 兩種都是可證明的：私有 IP 走 PSA 對等（privateNetwork == VM 的網路）；
  // 公開 IP 則要 VM 的外部 IP 真的落在 authorizedNetworks 之中。
  const vmToSql = [];
  for (const db of sqls) {
    for (const vm of vms) {
      if (db.privateIP && db.privateNetwork && db.privateNetwork === vm.network) {
        vmToSql.push({ vm, db, via: `私有 IP ${db.privateIP}` });
      } else if (db.publicIP && vm.externalIPs.some((ip) => db.authNets.some((n) => cidrContains(n, ip)))) {
        vmToSql.push({ vm, db, via: '公開 IP（授權網路）' });
      }
    }
  }

  const governance = {
    sinks: sinks.length,
    alerts: alerts.length,
    uptime: uptime.length,
    armor: armor.length,
    orgPolicies: orgPolicies.length,
    serviceAccounts: serviceAccounts.length,
    dnsZones: dnsZones.map((z) => ({ name: z.name, dnsName: z.dnsName, visibility: z.visibility || 'public' })),
  };

  return {
    project,
    projectNumber: meta.project_number || '?',
    period: meta.period || '?',
    scannedAt: meta.scanned_at || '?',
    networks,
    subnets,
    vms,
    migs,
    groups,
    migInGke,
    gkes,
    frs,
    bss,
    sqls,
    orphanSqls,
    buckets,
    addresses,
    runs: runsRaw,
    functions: fnsRaw,
    governance,
    denyRules,
    vmToSql,
  };
}

// ---------- draw.io XML ----------
function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// 樣式表
// 圖示走 draw.io 的 GCP 圖庫 `mxgraph.gcp2.*`（298 個 shape，是目前唯一涵蓋 DNS／LB／NAT／Router
// 等網路元件的完整 GCP 圖庫；`mxgraph.gcp3.*` 只有約 30 個主打產品，缺網路元件，故不採用）。
//
// ⚠️ **shape 名必須逐字對得上 stencil，且是「小寫＋底線」**：draw.io 把 stencil 裡的
//    `<shape name="Container Engine">` 正規化成 `container_engine`。名字打錯不會報錯——
//    draw.io 靜默退成一個帶標籤的方框，看起來只是「圖示醜了點」，很容易矇混過去。
//    名單的權威來源是 stencil 本身，不是產品名的直覺拼法（實際踩過的三個：
//    GKE 不是 `google_kubernetes_engine` 而是 `container_engine`（GKE 的舊稱 Container Engine）；
//    受管執行個體群組沒有專屬圖示，用 `servers_stacked`；
//    Private Service Connect 沒有專屬圖示，用 `service_discovery`）。
//    要新增圖示時，先對 stencil 查名字再寫進來：
//      gh api repos/jgraph/drawio/contents/src/main/webapp/stencils/gcp2.xml \
//         -H "Accept: application/vnd.github.raw" | grep -o '<shape name="[^"]*"'
//
// 即使某個名字在你的 draw.io 版本失效，**標籤本身已載明全部資訊**，圖不會失去意義。
const GCP = {
  blue: '#4285F4',
  red: '#EA4335',
  yellow: '#FBBC04',
  green: '#34A853',
  grey: '#5F6368',
  ink: '#202124',
  faint: '#9AA0A6',
};

const GROUP_BASE =
  'rounded=0;whiteSpace=wrap;html=1;fontSize=13;fontStyle=1;verticalAlign=top;align=left;' +
  'spacingLeft=12;spacingTop=4;container=1;collapsible=0;recursiveResize=0;pointerEvents=0;fillColor=none;';

// 樣式字串比照 draw.io 官方 GCP 圖庫（Sidebar-GCP2.js）的寫法：
// sketch=0;html=1;aspect=fixed;strokeColor=none;shadow=0;fillColor=…;labelPosition=center;
// verticalLabelPosition=bottom;verticalAlign=top;shape=mxgraph.gcp2.<name>
// 漏掉 fillColor 會變成白圖形（等於隱形），漏掉 aspect=fixed 圖形會被拉變形。
const gcpIcon = (name, fill) =>
  `sketch=0;html=1;outlineConnect=0;whiteSpace=wrap;fontSize=10;fontColor=${GCP.ink};align=center;` +
  `labelPosition=center;verticalLabelPosition=bottom;verticalAlign=top;aspect=fixed;shadow=0;` +
  `strokeColor=none;fillColor=${fill};shape=mxgraph.gcp2.${name};`;

const STYLES = {
  cloud: `${GROUP_BASE}strokeColor=${GCP.blue};fontColor=${GCP.blue};strokeWidth=2;dashed=0;`,
  vpc: `${GROUP_BASE}strokeColor=${GCP.green};fontColor=${GCP.green};dashed=0;`,
  regionBox:
    'rounded=0;whiteSpace=wrap;html=1;fontSize=11;verticalAlign=top;align=center;spacingTop=2;' +
    `fillColor=none;strokeColor=${GCP.grey};dashed=1;dashPattern=3 3;fontColor=${GCP.grey};container=1;` +
    'collapsible=0;recursiveResize=0;pointerEvents=0;',
  // 兩條通道：GCP 沒有公有／私有子網，這裡分的是「資源有沒有外部 IP」
  chExternal:
    'rounded=0;whiteSpace=wrap;html=1;fontSize=12;fontStyle=1;verticalAlign=top;align=center;spacingTop=4;' +
    `fillColor=#FCE8E6;strokeColor=${GCP.red};fontColor=#B31412;container=0;`,
  chInternal:
    'rounded=0;whiteSpace=wrap;html=1;fontSize=12;fontStyle=1;verticalAlign=top;align=center;spacingTop=4;' +
    `fillColor=#E8F0FE;strokeColor=${GCP.blue};fontColor=#174EA6;container=0;`,
  subnetBlock:
    'rounded=0;whiteSpace=wrap;html=1;fontSize=12;fontStyle=1;verticalAlign=top;align=left;spacingLeft=10;spacingTop=4;' +
    `fillColor=#F1F3F4;strokeColor=${GCP.grey};fontColor=${GCP.ink};container=0;`,
  subTile:
    'rounded=0;whiteSpace=wrap;html=1;fontSize=9;verticalAlign=middle;align=center;' +
    `fillColor=#FFFFFF;strokeColor=${GCP.faint};fontColor=${GCP.ink};container=0;`,
  subTileWarn:
    'rounded=0;whiteSpace=wrap;html=1;fontSize=9;verticalAlign=middle;align=center;' +
    `fillColor=#FFFFFF;strokeColor=${GCP.yellow};strokeWidth=2;fontColor=${GCP.ink};container=0;`,
  subTileMuted:
    'rounded=0;whiteSpace=wrap;html=1;fontSize=9;verticalAlign=middle;align=center;dashed=1;' +
    `fillColor=#F8F9FA;strokeColor=${GCP.faint};fontColor=${GCP.faint};container=0;`,
  rowFrame: (color, fill) =>
    'rounded=0;whiteSpace=wrap;html=1;fontSize=11;verticalAlign=top;align=left;spacingLeft=8;spacingTop=2;' +
    `fillColor=${fill};strokeColor=${color};fontColor=${color};container=0;`,
  rowFrameWarn:
    'rounded=0;whiteSpace=wrap;html=1;fontSize=11;fontStyle=1;verticalAlign=top;align=left;spacingLeft=8;spacingTop=2;' +
    `fillColor=#FEF7E0;strokeColor=${GCP.yellow};strokeWidth=2;fontColor=#B06000;container=0;`,
  // 防火牆框：框的是「實際套用到這批 VM 的 VPC 防火牆規則」。GCP 的防火牆不掛在資源上，
  // 而是掛在網路上、靠標籤／服務帳戶選中目標，所以框的範圍要用交叉比對算，不能照抄資源清單。
  fwFrame:
    'rounded=0;whiteSpace=wrap;html=1;fontSize=10;verticalAlign=top;align=center;spacingTop=2;' +
    `fillColor=none;strokeColor=${GCP.grey};dashed=1;dashPattern=4 3;fontColor=${GCP.grey};container=0;`,
  fwFrameOpen:
    'rounded=0;whiteSpace=wrap;html=1;fontSize=10;fontStyle=1;verticalAlign=top;align=center;spacingTop=2;' +
    `fillColor=none;strokeColor=${GCP.red};strokeWidth=2;fontColor=${GCP.red};container=0;`,
  vpcMini:
    'rounded=1;whiteSpace=wrap;html=1;fontSize=11;verticalAlign=middle;align=center;' +
    `fillColor=#E6F4EA;strokeColor=${GCP.green};fontColor=${GCP.ink};container=0;`,
  band: (color) =>
    'rounded=1;whiteSpace=wrap;html=1;fontSize=11;verticalAlign=top;align=left;spacingLeft=8;spacingTop=2;' +
    `fillColor=none;strokeColor=${color};dashed=1;dashPattern=4 3;fontColor=${color};container=1;` +
    'collapsible=0;recursiveResize=0;pointerEvents=0;',
  label: `text;html=1;strokeColor=none;fillColor=none;align=left;verticalAlign=middle;fontSize=11;fontColor=${GCP.grey};`,
  sideTitle: `text;html=1;strokeColor=none;fillColor=none;align=left;verticalAlign=middle;fontSize=12;fontStyle=1;fontColor=${GCP.ink};`,
  govOn:
    'rounded=0;whiteSpace=wrap;html=1;fontSize=11;verticalAlign=middle;align=left;spacingLeft=10;' +
    `fillColor=#FFFFFF;strokeColor=${GCP.grey};fontColor=${GCP.ink};container=0;`,
  govOff:
    'rounded=0;whiteSpace=wrap;html=1;fontSize=11;verticalAlign=middle;align=left;spacingLeft=10;dashed=1;' +
    `fillColor=#F1F3F4;strokeColor=${GCP.faint};fontColor=${GCP.faint};container=0;`,
  note:
    'rounded=0;whiteSpace=wrap;html=1;fontSize=10;verticalAlign=top;align=left;spacingLeft=8;spacingTop=6;' +
    `fillColor=#FEF7E0;strokeColor=${GCP.yellow};fontColor=#B06000;container=0;`,
  edge:
    'edgeStyle=orthogonalEdgeStyle;rounded=0;orthogonalLoop=1;jettySize=auto;html=1;fontSize=10;' +
    `strokeColor=${GCP.grey};fontColor=${GCP.ink};endArrow=block;endFill=1;`,
  // 命名規則推導出來的關聯（MIG → VM）用虛線，與 selfLink 可證明的實線區分
  edgeInferred: 'dashed=1;dashPattern=4 3;',

  users: gcpIcon('users', GCP.grey),
  dns: gcpIcon('cloud_dns', GCP.blue),
  lb: gcpIcon('cloud_load_balancing', GCP.blue),
  nat: gcpIcon('cloud_nat', GCP.blue),
  router: gcpIcon('cloud_router', GCP.blue),
  vm: gcpIcon('compute_engine', GCP.blue),
  // GKE 的 stencil 名是舊產品名 Container Engine，不是 google_kubernetes_engine
  gke: gcpIcon('container_engine', GCP.green),
  // 受管執行個體群組／Private Service Connect 在 gcp2 沒有專屬圖示，取語意最近的通用圖示
  mig: gcpIcon('servers_stacked', GCP.grey),
  psc: gcpIcon('service_discovery', GCP.grey),
  sql: gcpIcon('cloud_sql', GCP.blue),
  gcs: gcpIcon('cloud_storage', GCP.blue),
  run: gcpIcon('cloud_run', GCP.blue),
  fn: gcpIcon('cloud_functions', GCP.blue),
};

// gcp2 stencil 中確實存在的 shape 名（對 jgraph/drawio 的 stencils/gcp2.xml 逐字核對過）。
// 打錯名字 draw.io 只會靜默退成方框、不報錯，所以在這裡把「允許使用的名字」寫死成白名單，
// 讓錯字在產圖階段就爆掉，而不是等人開啟 .drawio 才用肉眼發現。
// 新增圖示時**先查 stencil 再把名字加進這裡**（查法見上方 gcpIcon 的註解）。
const GCP2_SHAPES = new Set([
  'users',
  'cloud_dns',
  'cloud_load_balancing',
  'cloud_nat',
  'cloud_router',
  'compute_engine',
  'container_engine',
  'servers_stacked',
  'service_discovery',
  'cloud_sql',
  'cloud_storage',
  'cloud_run',
  'cloud_functions',
]);
for (const [k, style] of Object.entries(STYLES)) {
  if (typeof style !== 'string') continue;
  const m = /shape=mxgraph\.gcp2\.([^;]+);/.exec(style);
  if (m && !GCP2_SHAPES.has(m[1])) {
    fail(`STYLES.${k} 用了不在 gcp2 stencil 白名單中的 shape「${m[1]}」——draw.io 會靜默退成方框。` +
      `請對 stencils/gcp2.xml 查出正確名稱（小寫＋底線）後更新 GCP2_SHAPES。`);
  }
}

const V_FLOW = 'exitX=0.5;exitY=1;exitDx=0;exitDy=0;entryX=0.5;entryY=0;entryDx=0;entryDy=0;';
const H_FLOW = 'exitX=1;exitY=0.5;exitDx=0;exitDy=0;entryX=0;entryY=0.5;entryDx=0;entryDy=0;';

// ---------- 頁面容器 ----------
class Page {
  constructor(id, name) {
    this.id = id;
    this.name = name;
    this.cells = [];
    this.ids = new Set();
    this.width = 1200;
    this.height = 900;
  }
  static key(id) {
    return String(id).replace(/[^A-Za-z0-9_.-]/g, '_');
  }
  has(id) {
    return this.ids.has(Page.key(id));
  }
  // 同一頁內的 id 必須唯一，否則 draw.io 會靜默吞掉後出現的那顆（畫少了卻不報錯）
  uid(id) {
    const s = Page.key(id);
    if (!this.ids.has(s)) {
      this.ids.add(s);
      return s;
    }
    let i = 2;
    while (this.ids.has(`${s}_${i}`)) i++;
    this.ids.add(`${s}_${i}`);
    return `${s}_${i}`;
  }
  vertex(id, parent, value, style, x, y, w, h) {
    const rid = this.uid(id);
    this.cells.push(
      `        <mxCell id="${esc(rid)}" value="${esc(value)}" style="${esc(style)}" vertex="1" parent="${esc(parent)}">\n` +
        `          <mxGeometry x="${Math.round(x)}" y="${Math.round(y)}" width="${Math.round(w)}" height="${Math.round(
          h
        )}" as="geometry" />\n` +
        `        </mxCell>`
    );
    return rid;
  }
  edge(id, source, target, value = '', styleExtra = '') {
    if (!source || !target) return;
    const rid = this.uid(id);
    this.cells.push(
      `        <mxCell id="${esc(rid)}" value="${esc(value)}" style="${esc(
        STYLES.edge + styleExtra
      )}" edge="1" parent="1" source="${esc(source)}" target="${esc(target)}">\n` +
        `          <mxGeometry relative="1" as="geometry" />\n        </mxCell>`
    );
  }
  toXml() {
    return (
      `  <diagram id="${esc(this.id)}" name="${esc(this.name)}">\n` +
      `    <mxGraphModel dx="800" dy="600" grid="0" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" ` +
      `fold="1" page="1" pageScale="1" pageWidth="${Math.ceil(this.width)}" pageHeight="${Math.ceil(
        this.height
      )}" math="0" shadow="0">\n` +
      `      <root>\n        <mxCell id="0" />\n        <mxCell id="1" parent="0" />\n` +
      this.cells.join('\n') +
      `\n      </root>\n    </mxGraphModel>\n  </diagram>`
    );
  }
}

// ---------- 版面常數 ----------
// 全景架構頁
const SUM = {
  icon: 78,
  tileW: 178, // 每個資源圖示的水平槽寬（含標籤留白）
  tileH: 140, // 每列圖示的垂直高度（圖示 ＋ 下方多行標籤）
  maxPerLine: 6, // 一列最多幾個圖示，超過就換行（VM 多的環境不換行會擠成一條線）
  colW: 580, // 單一通道寬
  colGap: 26,
  vpcPadX: 26,
  topRowH: 160, // VPC 框內頂列（Cloud Router／NAT）
  subTitleH: 52,
  subH: 74,
  subGap: 8,
  subPad: 12,
  regionGap: 14,
  chTitleH: 56,
  rowGap: 22,
  rowPadTop: 32,
  fwPad: 10,
  fwTitleH: 34,
  vpcGap: 40,
  sidebarW: 280,
  extW: 230,
  slotH: 150,
};

// 每 VPC 詳細頁
const LAYOUT = {
  icon: 78,
  tileW: 200,
  tileH: 148,
  maxPerLine: 6,
  bandGap: 58,
  bandPadTop: 34,
  subW: 260,
  subH: 104,
  subGap: 10,
  regionPad: 12,
  regionGap: 16,
  frameMargin: 30,
};

// 一列圖示要幾行、佔多高（圖示數量會變，高度必須是算出來的，不能寫死）
function gridSize(count, perLine, tileW, tileH) {
  const n = Math.max(1, count || 0);
  const cols = Math.min(n, perLine);
  const lines = Math.ceil(n / cols);
  return { cols, lines, w: cols * tileW, h: lines * tileH };
}

// ---------- 標籤組裝（把「證據」寫進標籤，圖示 shape 失效時仍看得懂）----------
function vmLabel(vm) {
  const ext = vm.externalIPs.length ? `<br><font color="${GCP.red}">外部 IP ${vm.externalIPs[0]}</font>` : '<br>僅內部 IP';
  const warn = vm.exposed ? `<br><font color="${GCP.red}">⚠ 對 0.0.0.0/0 開放 ${vm.worldPorts.join(' ')}</font>` : '';
  const stop = vm.status !== 'RUNNING' ? `<br><font color="${GCP.faint}">${vm.status}</font>` : '';
  return `${vm.name}<br>${vm.machineType}　${vm.zone}${ext}${warn}${stop}`;
}

function sqlLabel(db) {
  const parts = [db.name, `${db.version}　${db.availability}`];
  if (db.isReplica) parts.push(`唯讀複本（主：${db.master}）`);
  if (db.privateIP) parts.push(`私有 IP ${db.privateIP}`);
  if (db.publicIP) {
    parts.push(
      db.openToWorld
        ? `<font color="${GCP.red}">⚠ 公開 IP ${db.publicIP} ＋ 授權 0.0.0.0/0</font>`
        : `<font color="${GCP.red}">⚠ 公開 IP ${db.publicIP}（授權 ${db.authNets.length} 個網段）</font>`
    );
  }
  if (!db.sslEnforced) parts.push(`<font color="${GCP.yellow}">⚠ SSL ${db.sslMode}</font>`);
  if (!db.backup) parts.push(`<font color="${GCP.red}">⚠ 未啟用自動備份</font>`);
  return parts.join('<br>');
}

function subnetLabel(s) {
  const flags = [];
  flags.push(s.privateGoogleAccess ? 'PGA 開' : 'PGA 關');
  flags.push(s.flowLogs ? '流量記錄開' : '流量記錄關');
  flags.push(s.nat ? `NAT ${s.nat}` : 'NAT 無');
  const purpose = s.purpose && s.purpose !== 'PRIVATE' ? `<br>${s.purpose}` : '';
  return `${s.name}<br>${s.cidr}<br>${s.region}${purpose}<br><font color="${GCP.grey}">${flags.join('・')}</font>`;
}

// 子網要不要標黃：沒有 Private Google Access 又沒有 Cloud NAT，代表這個子網裡沒有外部 IP 的 VM
// 既連不出網際網路、也走不到 Google API——這是 GCP 上很常見、但只看單一檔案看不出來的組態問題。
// 執行個體群組的標籤。三種來源要分清楚，混在一起讀圖的人會以為都掃到了：
//   受管 MIG      → 有可用區與執行個體數
//   未受管群組    → 有可用區，但成員要另外查 listInstances（本流程未掃），故不顯示成員數
//   未掃描到      → 只被 backend-service 指名，組態完全沒有。**必須標示出來**，
//                   否則流量鏈看起來接上了、實際上後端是誰仍然未知，比斷掉更誤導。
function groupLabel(g) {
  if (g.unresolved) {
    return `${g.name}<br><font color="${GCP.yellow}">⚠ 未掃描到此群組</font>` +
      `<br><font color="${GCP.grey}">僅由後端服務指名<br>組態不明</font>`;
  }
  const kind = g.unmanaged ? '<br>未受管群組' : '';
  const size = g.unmanaged ? `<br>執行個體 ${g.size}` : `<br>執行個體 ${g.size}/${g.targetSize}`;
  return `${g.name}<br>${g.zone || '?'}${size}${kind}${g.autoscaled ? '<br>自動調度' : ''}`;
}

const subnetWarn = (s) => s.purpose === 'PRIVATE' && !s.privateGoogleAccess && !s.nat;

// ---------- 頁 1：全景架構 ----------
function buildSummary(model, sd) {
  const S = SUM;
  const pg = new Page('summary', '全景架構');

  // ── 雲外左欄：使用者 → Cloud DNS（不畫到 LB 的邊）→ 外部轉送規則 ──
  const extX = 40;
  let ey = 60;
  const usersId = pg.vertex('sum-users', '1', '網際網路使用者', STYLES.users, extX + (S.extW - S.icon) / 2, ey, S.icon, S.icon);
  ey += 160;

  const zones = model.governance.dnsZones;
  if (zones.length) {
    pg.vertex(
      'sum-dns',
      '1',
      `Cloud DNS（${zones.length}）<br>${zones.map((z) => `${z.name}：${z.dnsName}`).join('<br>')}` +
        `<br><font color="${GCP.faint}">未掃描 record set，對應到哪個<br>負載平衡器無法證明，故不畫線</font>`,
      STYLES.dns,
      extX + (S.extW - S.icon) / 2,
      ey,
      S.icon,
      S.icon
    );
    ey += 190;
  }

  // 外部轉送規則（＝真正的網際網路入口）
  const extFrs = model.frs.filter((f) => f.external);
  const frTop = ey;
  extFrs.forEach((f, i) => {
    const bs = f.backendServices[0];
    const armorTxt = bs
      ? bs.securityPolicy
        ? `<br>Cloud Armor：${bs.securityPolicy}`
        : `<br><font color="${GCP.red}">⚠ 未掛 Cloud Armor</font>`
      : '';
    pg.vertex(
      `sum-fr-${f.name}`,
      '1',
      `${f.name}<br>${f.ip}　${f.protocol}:${f.ports.join(',')}<br>${f.scheme}${armorTxt}`,
      STYLES.lb,
      extX + (S.extW - S.icon) / 2,
      frTop + i * S.slotH,
      S.icon,
      S.icon
    );
    pg.edge(`e-sum-users-${f.name}`, usersId, `sum-fr-${f.name}`, '', V_FLOW);
    sd.forwardingRule++;
  });
  const extBottom = frTop + Math.max(extFrs.length, 1) * S.slotH;

  // ── 先把各 VPC 的尺寸算出來，雲框才包得住 ──
  const vpcW = 2 * S.colW + S.colGap + 2 * S.vpcPadX;
  const vpcPlans = model.networks.map((v) => ({ v, plan: planVpc(model, v) }));
  const vpcsH = vpcPlans.reduce((n, x) => n + x.plan.frameH + S.vpcGap, 0);
  const orphanH = model.orphanSqls.length ? 40 + S.tileH : 0;

  // ── 專案層服務欄的尺寸 ──
  const g = model.governance;
  const govRows = [
    ['Cloud Logging 匯出 sink', g.sinks],
    ['Cloud Monitoring 告警政策', g.alerts],
    ['Uptime check', g.uptime],
    ['Cloud Armor 安全政策', g.armor],
    ['組織政策（專案層）', g.orgPolicies],
    ['IAM 服務帳戶', g.serviceAccounts],
  ];
  const serverless = [
    ...model.runs.map((s) => ({ name: s.name || (s.metadata || {}).name || '?', kind: 'Cloud Run' })),
    ...model.functions.map((s) => ({ name: last(s.name) || '?', kind: 'Cloud Functions' })),
  ];
  const sideH =
    46 +
    26 +
    govRows.length * 46 +
    40 +
    model.buckets.length * 130 +
    (serverless.length ? 40 + serverless.length * 130 : 0) +
    (GAPS.length ? 40 + GAPS.length * 26 : 0) +
    60;

  const cloudX = extX + S.extW + 90;
  const cloudY = 40;
  const sideX = 30;
  const vpcX = sideX + S.sidebarW + 40;
  const cloudW = vpcX + vpcW + 30;
  const cloudH = Math.max(sideH, vpcsH + orphanH + 60) + 40;
  const cloud = pg.vertex(
    'sum-cloud',
    '1',
    `Google Cloud 專案 ${model.project}（編號 ${model.projectNumber}）　期別 ${model.period}　掃描時間 ${model.scannedAt}`,
    STYLES.cloud,
    cloudX,
    cloudY,
    cloudW,
    cloudH
  );

  // ── 專案層服務欄 ──
  let sy = 46;
  pg.vertex('sum-side-title', cloud, '專案層服務與治理', STYLES.sideTitle, sideX, sy, S.sidebarW, 20);
  sy += 26;
  govRows.forEach(([name, count], i) => {
    // 空回應（0 個）＝真的沒設定，是有效證據；查詢失敗已在 GAPS 另外標示，兩者不可混為一談
    pg.vertex(
      `sum-gov-${i}`,
      cloud,
      `${name}<br>${count > 0 ? `${count} 個` : '未設定'}`,
      count > 0 ? STYLES.govOn : STYLES.govOff,
      sideX,
      sy,
      S.sidebarW,
      40
    );
    sy += 46;
  });

  sy += 14;
  pg.vertex('sum-side-gcs', cloud, `Cloud Storage（${model.buckets.length}，不屬於任何 VPC）`, STYLES.sideTitle, sideX, sy, S.sidebarW, 20);
  sy += 26;
  model.buckets.forEach((b, i) => {
    const paps = b.pap === 'enforced' ? 'PAP enforced' : `<font color="${GCP.yellow}">⚠ PAP ${b.pap}</font>`;
    const ublas = b.ubla ? 'UBLA 開' : `<font color="${GCP.yellow}">⚠ UBLA 關</font>`;
    pg.vertex(
      `sum-gcs-${b.name}`,
      cloud,
      `${b.name}<br>${b.location}<br>${paps}<br>${ublas}`,
      STYLES.gcs,
      sideX + 10,
      sy + i * 130,
      S.icon,
      S.icon
    );
    sd.bucket++;
  });
  sy += model.buckets.length * 130 + 14;

  if (serverless.length) {
    pg.vertex('sum-side-sl', cloud, '無伺服器服務（不屬於任何 VPC）', STYLES.sideTitle, sideX, sy, S.sidebarW, 20);
    sy += 26;
    serverless.forEach((s, i) => {
      pg.vertex(
        `sum-sl-${s.name}`,
        cloud,
        `${s.name}<br>${s.kind}`,
        s.kind === 'Cloud Run' ? STYLES.run : STYLES.fn,
        sideX + 10,
        sy + i * 130,
        S.icon,
        S.icon
      );
    });
    sy += serverless.length * 130 + 14;
  }

  // 資料缺口：只有「查詢失敗」才列在這裡；「回空清單」是有效證據，已畫成「未設定」
  if (GAPS.length) {
    pg.vertex(
      'sum-gaps',
      cloud,
      `⚠ 資料缺口（掃描查詢失敗，非「未設定」）<br>${GAPS.map((x) => `・${x}`).join('<br>')}`,
      STYLES.note,
      sideX,
      sy,
      S.sidebarW,
      Math.max(70, 24 + GAPS.length * 30)
    );
  }

  // ── 各 VPC 網路 ──
  let vy = 46;
  for (const { v, plan } of vpcPlans) {
    drawVpcBlock(pg, cloud, model, v, plan, vpcX, vy, vpcW, sd);
    vy += plan.frameH + S.vpcGap;
  }

  // ── 只有公開 IP、不屬於任何 VPC 的 Cloud SQL ──
  if (model.orphanSqls.length) {
    pg.vertex('sum-orphan-title', cloud, 'Cloud SQL（僅公開 IP，不在任何 VPC 網路內）', STYLES.sideTitle, vpcX, vy, vpcW, 20);
    model.orphanSqls.forEach((db, i) => {
      pg.vertex(`sum-sql-${db.name}`, cloud, sqlLabel(db), STYLES.sql, vpcX + 20 + i * S.tileW, vy + 34, S.icon, S.icon);
      sd.sql++;
    });
  }

  // ── 外部轉送規則 → 它的後端所在的資源列（可證明的 proxy→urlMap→backendService→group 鏈）──
  // 雲外入口欄的外部轉送規則 → 它的後端服務（經 proxy → urlMap 的 selfLink 鏈證明）
  for (const f of extFrs) {
    for (const bs of f.backendServices) {
      if (pg.has(`sum-bs-${bs.name}`)) {
        pg.edge(`e-sum-${f.name}-${bs.name}`, `sum-fr-${f.name}`, Page.key(`sum-bs-${bs.name}`),
                `${bs.protocol}${bs.port ? ':' + bs.port : ''}`, H_FLOW);
      }
    }
  }

  pg.width = cloudX + cloudW + 60;
  pg.height = Math.max(cloudY + cloudH, extBottom) + 60;
  return pg;
}

// 一個資源列（row）落在哪條通道：只要成員有任一個外部 IP，就是「有外部 IP」通道。
// 這是 GCP 的正確判準——不是子網，而是資源本身。
function planVpc(model, v) {
  const S = SUM;

  // 子網區塊（橫跨兩條通道之上：GCP 的子網不分公私，不該被放進任何一條通道）
  const subRows = Math.max(1, ...v.shownRegions.map((r) => v.shownSubnets.filter((s) => s.region === r).length));
  const subBlockH = S.subTitleH + subRows * (S.subH + S.subGap) + (v.hiddenSubnets.length ? 34 : 0) + 12;

  // 資源列，由上而下＝流量方向
  const rows = [];
  const addRow = (r) => {
    if (!r.items.length) return;
    const gs = gridSize(r.items.length, S.maxPerLine, S.tileW, S.tileH);
    r.grid = gs;
    r.h = S.rowPadTop + S.fwTitleH + gs.h + 12;
    rows.push(r);
  };

  // 外部轉送規則**不在這裡畫**：它已經在雲外入口欄畫過一次（那是它在圖上的位置——
  // 網際網路的入口）。同一頁再畫一次會變成同一顆資源出現兩次，讀圖的人會以為有兩組 LB。
  // 入口欄的節點直接連到下面的後端服務列，流量鏈一樣完整。

  // 1. 後端服務（Cloud Armor／CDN／健康檢查的證據都掛在這裡）
  const vpcBsNames = uniq(v.frs.flatMap((f) => f.bsNames));
  addRow({
    kind: 'bs',
    key: 'bs',
    title: '後端服務',
    channel: 'internal',
    items: model.bss.filter((b) => vpcBsNames.includes(b.name)),
  });

  // 2. 內部負載平衡與 Private Service Connect 端點
  addRow({
    kind: 'intlb',
    key: 'intlb',
    title: '內部負載平衡／Private Service Connect 端點',
    channel: 'internal',
    items: v.frs.filter((f) => !f.external),
  });

  // 3. GKE 叢集（節點 VM 收進叢集裡計數，不逐台畫——否則幾十顆節點會淹掉整張圖）
  addRow({
    kind: 'gke',
    key: 'gke',
    title: 'Google Kubernetes Engine 叢集',
    channel: v.gkes.some((x) => x.members.some((m) => m.externalIPs.length)) ? 'external' : 'internal',
    items: v.gkes,
  });

  // 4. 非 GKE 的執行個體群組
  const plainGroups = v.groups.filter((m) => !model.migInGke.has(m.name));
  addRow({
    kind: 'mig',
    key: 'mig',
    title: '受管執行個體群組（MIG）',
    channel: plainGroups.some((m) => m.members.some((x) => x.externalIPs.length)) ? 'external' : 'internal',
    items: plainGroups,
  });

  // 5. 獨立 VM（不屬於任何 MIG）——依「有沒有外部 IP」拆成兩列，各自進自己的通道
  const inMig = new Set(v.groups.flatMap((m) => m.members.map((x) => x.name)));
  const standalone = v.vms.filter((x) => !inMig.has(x.name));
  addRow({
    kind: 'vm',
    key: 'vm-ext',
    title: '獨立 VM（有外部 IP）',
    channel: 'external',
    items: standalone.filter((x) => x.externalIPs.length),
  });
  addRow({
    kind: 'vm',
    key: 'vm-int',
    title: '獨立 VM（僅內部 IP）',
    channel: 'internal',
    items: standalone.filter((x) => !x.externalIPs.length),
  });

  // 6. Cloud SQL（有公開 IP 者放外部通道——那正是要一眼看見的事，不因「DB 理應在內部」而美化）
  addRow({
    kind: 'sql',
    key: 'sql-ext',
    title: 'Cloud SQL（有公開 IP）',
    channel: 'external',
    items: v.sqls.filter((d) => d.publicIP),
  });
  addRow({
    kind: 'sql',
    key: 'sql-int',
    title: 'Cloud SQL（僅私有 IP）',
    channel: 'internal',
    items: v.sqls.filter((d) => !d.publicIP),
  });

  const channelH = S.chTitleH + rows.reduce((n, r) => n + r.h + S.rowGap, 0) + 10;
  const frameH = S.topRowH + subBlockH + channelH + 24;
  return { subRows, subBlockH, rows, channelH, frameH };
}

function drawVpcBlock(pg, parent, model, v, plan, x, y, w, sd) {
  const S = SUM;
  const modeWarn = v.auto ? `　<font color="${GCP.yellow}">⚠ 自動模式：每個 GCP 區域自動建一個子網</font>` : '';
  const frame = pg.vertex(
    `sum-vpc-${v.name}`,
    parent,
    `VPC 網路 ${v.name}（${v.mode} 模式，路由 ${v.routing}）　子網 ${v.subnets.length} 個／${v.regions.length} 個區域${modeWarn}`,
    STYLES.vpc,
    x,
    y,
    w,
    plan.frameH
  );

  const extX = S.vpcPadX;
  const intX = S.vpcPadX + S.colW + S.colGap;
  const colX = { external: extX, internal: intX };

  // ── 頂列：Cloud Router／Cloud NAT（GCP 的「對外連出」機制）──
  let tx = extX + 10;
  for (const rt of v.routers) {
    const nats = (rt.nats || []).map((n) => n.name);
    pg.vertex(
      `sum-router-${v.name}-${rt.name}`,
      frame,
      `${rt.name}<br>${last(rt.region)}<br>${nats.length ? `Cloud NAT：${nats.join('、')}` : '無 NAT（僅 BGP／VPN）'}`,
      nats.length ? STYLES.nat : STYLES.router,
      tx,
      36,
      S.icon,
      S.icon
    );
    tx += S.tileW;
  }
  if (!v.routers.length) {
    pg.vertex(
      `sum-nonat-${v.name}`,
      frame,
      '此網路沒有 Cloud Router／Cloud NAT：無外部 IP 的 VM 沒有對外連出的路徑（掃描回空＝有效證據）',
      STYLES.label,
      extX + 10,
      56,
      S.colW * 1.6,
      40
    );
  }

  // ── 子網區塊：橫跨兩條通道之上 ──
  // 這個版面選擇本身就是結論：GCP 的子網**不分**公有／私有，不屬於任何一條暴露通道。
  const subY = S.topRowH;
  const subW = 2 * S.colW + S.colGap;
  pg.vertex(
    `sum-subblock-${v.name}`,
    frame,
    '子網（區域資源）　GCP 沒有公有／私有子網之分：子網不分層，下方通道分的是「資源有沒有外部 IP」<br>' +
      `<font color="${GCP.grey}">PGA＝Private Google Access；「NAT 無」代表該子網內沒有外部 IP 的 VM 連不出網際網路</font>`,
    STYLES.subnetBlock,
    extX,
    subY,
    subW,
    plan.subBlockH
  );

  const nReg = Math.max(v.shownRegions.length, 1);
  const tileW = (subW - 2 * S.subPad - (nReg - 1) * S.regionGap) / nReg;
  v.shownRegions.forEach((region, ri) => {
    const list = v.shownSubnets.filter((s) => s.region === region).sort(byName);
    const baseX = extX + S.subPad + ri * (tileW + S.regionGap);
    list.forEach((s, i) => {
      pg.vertex(
        `sum-sub-${v.name}-${s.key}`,
        frame,
        subnetLabel(s),
        subnetWarn(s) ? STYLES.subTileWarn : STYLES.subTile,
        baseX,
        subY + S.subTitleH + i * (S.subH + S.subGap),
        tileW,
        S.subH
      );
      sd.subnet++;
    });
  });
  if (v.hiddenSubnets.length) {
    // 自動模式的其餘區域：不畫方塊但要照實記帳，計數斷言仍然涵蓋它們
    pg.vertex(
      `sum-subhidden-${v.name}`,
      frame,
      `另有 ${v.hiddenSubnets.length} 個自動建立的子網分布在 ${uniq(v.hiddenSubnets.map((s) => s.region)).length} 個沒有任何資源的區域，未逐一繪出（明細見 data/network/subnets.json）`,
      STYLES.subTileMuted,
      extX + S.subPad,
      subY + plan.subBlockH - 30,
      subW - 2 * S.subPad,
      24
    );
    sd.subnetAccounted += v.hiddenSubnets.length;
  }

  // ── 兩條暴露通道（背景，先畫；資源列疊在上面）──
  const chY = subY + plan.subBlockH + 6;
  pg.vertex(
    `sum-ch-ext-${v.name}`,
    frame,
    '有外部 IP：直接可及於網際網路<br><font color="#B31412">實際暴露 ＝ 有外部 IP ＋ 套用到來源 0.0.0.0/0 的 allow 規則</font>',
    STYLES.chExternal,
    extX,
    chY,
    S.colW,
    plan.channelH
  );
  pg.vertex(
    `sum-ch-int-${v.name}`,
    frame,
    '僅內部 IP：需經負載平衡器／Cloud NAT／IAP 才到得了<br><font color="#174EA6">對外連出取決於 Cloud NAT，不是子網屬性</font>',
    STYLES.chInternal,
    intX,
    chY,
    S.colW,
    plan.channelH
  );

  // ── 資源列 ──
  const rowColor = { extlb: GCP.blue, bs: GCP.blue, intlb: GCP.blue, gke: GCP.green, mig: GCP.grey, vm: GCP.grey, sql: GCP.yellow };
  const rowFill = { extlb: '#E8F0FE', bs: '#E8F0FE', intlb: '#E8F0FE', gke: '#E6F4EA', mig: '#F1F3F4', vm: '#F1F3F4', sql: '#FEF7E0' };

  let ry = chY + S.chTitleH;

  for (const row of plan.rows) {
    const rx = colX[row.channel];
    // 這一列的成員 VM（用來算「真的有哪些防火牆規則套用到它們」）
    const rowVms =
      row.kind === 'vm'
        ? row.items
        : row.kind === 'gke' || row.kind === 'mig'
          ? uniq(row.items.flatMap((i) => i.members))
          : [];
    const applied = uniq(rowVms.flatMap((x) => x.fwRules.map((r) => r.name))).sort();
    const worldRules = uniq(rowVms.flatMap((x) => x.fwRules.filter((r) => r.world).map((r) => r.name))).sort();
    const worldPorts = uniq(rowVms.flatMap((x) => x.worldPorts)).sort();

    const anyWarn =
      worldRules.length > 0 ||
      (row.kind === 'sql' && row.items.some((i) => i.publicIP)) ||
      (row.kind === 'bs' && row.items.some((b) => /^EXTERNAL/.test(b.scheme) && !b.securityPolicy));
    pg.vertex(
      `sum-row-${v.name}-${row.key}`,
      frame,
      row.title,
      anyWarn ? STYLES.rowFrameWarn : STYLES.rowFrame(rowColor[row.kind], rowFill[row.kind]),
      rx,
      ry,
      S.colW,
      row.h
    );

    // 防火牆框＝「實際套用到這些 VM 的 VPC 防火牆規則」（規則靠標籤／服務帳戶選中目標，
    // 故必須交叉比對才算得出來）。只在算得出成員 VM 時才畫——後端服務／轉送規則／Cloud SQL
    // 不受 VPC 防火牆規則管轄，硬畫一個框會是錯的結論。
    const fwX = rx + S.fwPad;
    const fwY = ry + S.rowPadTop;
    const fwW = S.colW - 2 * S.fwPad;
    const fwH = row.h - S.rowPadTop - 8;
    if (rowVms.length) {
      const label = applied.length
        ? worldRules.length
          ? `VPC 防火牆（實際套用）：${applied.join('、')}　⚠ 其中 ${worldRules.join('、')} 來源 0.0.0.0/0 → ${worldPorts.join(' ')}`
          : `VPC 防火牆（實際套用）：${applied.join('、')}`
        : 'VPC 防火牆：沒有任何 INGRESS allow 規則套用到這些 VM';
      pg.vertex(
        `sum-fw-${v.name}-${row.key}`,
        frame,
        label,
        worldRules.length ? STYLES.fwFrameOpen : STYLES.fwFrame,
        fwX,
        fwY,
        fwW,
        fwH
      );
    }

    // 圖示網格
    const gs = row.grid;
    const slotW = fwW / gs.cols;
    row.items.forEach((item, i) => {
      const col = i % gs.cols;
      const line = Math.floor(i / gs.cols);
      const ix = fwX + col * slotW + (slotW - S.icon) / 2;
      const iy = fwY + S.fwTitleH + line * S.tileH;
      drawSummaryItem(pg, frame, row, item, ix, iy, sd);
    });

    ry += row.h + S.rowGap;
  }

  // ── VM／MIG → Cloud SQL：可證明的連線 ──
  for (const { vm, db, via } of model.vmToSql) {
    if (vm.network !== v.name) continue;
    if (!pg.has(`sum-sql-${db.name}`)) continue;
    const owningMig = model.migs.find((m) => m.members.includes(vm));
    const cand = [`sum-vm-${vm.name}`];
    if (owningMig) {
      const gke = model.gkes.find((x) => x.migs.includes(owningMig));
      cand.push(gke ? `sum-gke-${gke.name}` : `sum-grp-${owningMig.name}`);
    }
    const srcId = cand.find((s) => pg.has(s));
    // 同一個來源 cell（如 GKE 叢集）可能對應多台 VM，只需一條邊
    if (srcId) pg.edge(`e-sum-sql-${srcId}-${db.name}`, Page.key(srcId), Page.key(`sum-sql-${db.name}`), via, H_FLOW);
  }
}

function drawSummaryItem(pg, frame, row, item, ix, iy, sd) {
  const S = SUM;
  if (row.kind === 'extlb' || row.kind === 'intlb') {
    const kind = item.isPsc ? 'Private Service Connect' : item.scheme || '?';
    const label =
      `${item.name}<br>${item.ip}${item.ports.length && item.ports[0] ? `　${item.protocol}:${item.ports.join(',')}` : ''}<br>${kind}` +
      (item.proxy ? `<br>代理 ${item.proxy.name}` : '') +
      (item.urlMap ? `<br>URL 對應 ${item.urlMap.name}` : '');
    pg.vertex(`sum-fr2-${item.name}`, frame, label, item.isPsc ? STYLES.psc : STYLES.lb, ix, iy, S.icon, S.icon);
    // 外部轉送規則已在雲外欄計過一次，這裡是同一顆資源的第二次呈現，不重複計數
    if (row.kind === 'intlb') sd.forwardingRule++;
    return;
  }
  if (row.kind === 'bs') {
    const armor = item.securityPolicy
      ? `<br>Armor ${item.securityPolicy}`
      : /^EXTERNAL/.test(item.scheme)
        ? `<br><font color="${GCP.red}">⚠ 未掛 Cloud Armor</font>`
        : '';
    pg.vertex(
      `sum-bs-${item.name}`,
      frame,
      `${item.name}<br>${item.scheme}　${item.protocol}${item.port ? `:${item.port}` : ''}` +
        `<br>健康檢查 ${item.healthChecks.length || '無'}${item.cdn ? '<br>Cloud CDN 開' : ''}${armor}`,
      STYLES.lb,
      ix,
      iy,
      S.icon,
      S.icon
    );
    sd.backendService++;
    return;
  }
  if (row.kind === 'gke') {
    const priv = item.privateNodes ? '私有節點' : `<font color="${GCP.yellow}">⚠ 節點非私有</font>`;
    const id = pg.vertex(
      `sum-gke-${item.name}`,
      frame,
      `${item.name}<br>${item.mode}　${item.location}<br>節點 ${item.nodeCount}（MIG ${item.migs.length}）<br>${item.version}<br>${priv}`,
      STYLES.gke,
      ix,
      iy,
      S.icon,
      S.icon
    );
    sd.gke++;
    // 叢集的節點 VM／MIG 收進叢集裡計數（不逐個畫），但計數斷言必須照實涵蓋
    sd.vmAccounted += item.members.length;
    sd.groupAccounted += item.migs.length;
    void id;
    return;
  }
  if (row.kind === 'mig') {
    pg.vertex(
      `sum-grp-${item.name}`,
      frame,
      groupLabel(item),
      STYLES.mig,
      ix,
      iy,
      S.icon,
      S.icon
    );
    if (!item.unresolved) sd.group++;
    sd.vmAccounted += item.members.length;
    return;
  }
  if (row.kind === 'vm') {
    pg.vertex(`sum-vm-${item.name}`, frame, vmLabel(item), STYLES.vm, ix, iy, S.icon, S.icon);
    sd.vm++;
    return;
  }
  // sql
  pg.vertex(`sum-sql-${item.name}`, frame, sqlLabel(item), STYLES.sql, ix, iy, S.icon, S.icon);
  sd.sql++;
}

// ---------- 頁 2：架構索引 ----------
function buildOverview(model, drawn) {
  const pg = new Page('overview', '架構索引');
  const icon = 78;
  const slotH = 150;
  const miniW = 380;
  const miniH = 130;
  const miniGap = 26;

  const extFrs = model.frs.filter((f) => f.external);
  const frColH = Math.max(extFrs.length * slotH, 200);
  const vpcsH = 50 + model.networks.length * (miniH + miniGap) + 10;
  const gcsH = model.buckets.length ? 160 : 0;

  const cloudX = 240;
  const cloudY = 40;
  const frColX = 50;
  const vpcColX = 330;
  const cloudW = vpcColX + miniW + 90;
  const cloudH = Math.max(frColH, vpcsH) + gcsH + 110;

  const cloud = pg.vertex(
    'ov-cloud',
    '1',
    `Google Cloud 專案 ${model.project}（編號 ${model.projectNumber}）　期別 ${model.period}`,
    STYLES.cloud,
    cloudX,
    cloudY,
    cloudW,
    cloudH
  );

  pg.vertex('ov-users', '1', '網際網路使用者', STYLES.users, 60, cloudY + frColH / 2, icon, icon);

  let frBottom = 60;
  extFrs.forEach((f, i) => {
    const bs = f.backendServices[0];
    pg.vertex(
      `ov-fr-${f.name}`,
      cloud,
      `${f.name}<br>${f.ip}　${f.protocol}:${f.ports.join(',')}` +
        (bs && !bs.securityPolicy ? `<br><font color="${GCP.red}">⚠ 未掛 Cloud Armor</font>` : ''),
      STYLES.lb,
      frColX,
      60 + i * slotH,
      icon,
      icon
    );
    pg.edge(`e-ov-users-${f.name}`, 'ov-users', `ov-fr-${f.name}`, '', H_FLOW);
    // 這裡不計數：索引頁畫的是「同一批轉送規則的縮略呈現」，逐 VPC 頁才是它們的正式落點。
    // 兩邊都計會重複（計數斷言首次實跑就抓到：11 條變成 13）。
  });
  if (!extFrs.length) {
    pg.vertex('ov-nofr', cloud, '沒有任何外部轉送規則<br>（掃描回空＝有效證據）', STYLES.govOff, frColX, 60, 210, 50);
  }
  frBottom += Math.max(extFrs.length, 1) * slotH;

  // VPC 縮略框
  let vy = 50;
  for (const v of model.networks) {
    const parts = [`子網×${v.subnets.length}`];
    if (v.vms.length) parts.push(`VM×${v.vms.length}`);
    if (v.gkes.length) parts.push(`GKE×${v.gkes.length}`);
    if (v.groups.length) parts.push(`執行個體群組×${v.groups.length}`);
    if (v.frs.length) parts.push(`轉送規則×${v.frs.length}`);
    if (v.sqls.length) parts.push(`Cloud SQL×${v.sqls.length}`);
    const exposedN = v.vms.filter((x) => x.exposed).length;
    const extN = v.vms.filter((x) => x.externalIPs.length).length;
    pg.vertex(
      `ov-vpc-${v.name}`,
      cloud,
      `<b>${v.name}</b>（${v.mode} 模式）<br>${v.regions.length} 個區域<br>${parts.join('　')}` +
        `<br>有外部 IP 的 VM：${extN}／${v.vms.length}` +
        (exposedN ? `　<font color="${GCP.red}">⚠ 實際暴露 ${exposedN}</font>` : '') +
        (v.hasWorkload ? '<br>→ 詳見同名分頁' : '<br>（無工作負載）'),
      STYLES.vpcMini,
      vpcColX,
      vy,
      miniW,
      miniH
    );
    // 無工作負載的 VPC 不另開分頁，其資源在此以計數涵蓋（計數斷言才守得住）
    if (!v.hasWorkload) {
      drawn.subnetAccounted += v.subnets.length;
      drawn.vmAccounted += v.vms.length;
      drawn.sqlAccounted += v.sqls.length;
      drawn.groupAccounted += v.groups.filter((g) => !g.unresolved).length;
      drawn.gkeAccounted += v.gkes.length;
      drawn.forwardingRuleAccounted += v.frs.length;
    }
    vy += miniH + miniGap;
  }

  // 外部轉送規則 → 它的後端所屬 VPC（可證明：轉送規則自己就帶 network）
  for (const f of extFrs) {
    if (f.network && model.networks.some((n) => n.name === f.network)) {
      pg.edge(`e-ov-${f.name}-${f.network}`, `ov-fr-${f.name}`, `ov-vpc-${f.network}`, '', H_FLOW);
    }
  }

  // 不屬於任何 VPC 的 Cloud SQL（只有公開 IP）也要照實計數
  drawn.sqlAccounted += model.orphanSqls.length;

  // Cloud Storage 橫列
  if (model.buckets.length) {
    const gy = Math.max(frBottom, vy) + 30;
    pg.vertex('ov-gcs-label', cloud, 'Cloud Storage（不屬於任何 VPC）', STYLES.label, vpcColX, gy - 24, 320, 20);
    model.buckets.forEach((b, i) => {
      pg.vertex(`ov-gcs-${b.name}`, cloud, `${b.name}<br>${b.location}`, STYLES.gcs, vpcColX + i * 160, gy, icon, icon);
      drawn.bucket++;
    });
  }

  pg.width = cloudX + cloudW + 60;
  pg.height = cloudY + cloudH + 60;
  return pg;
}

// ---------- 頁 3..N：每個有工作負載的 VPC 網路 ----------
function buildVpcPage(model, v, drawn) {
  const L = LAYOUT;
  const pg = new Page(`vpc-${v.name}`, v.name);

  const vpcBsNames = uniq(v.frs.flatMap((f) => f.bsNames));
  const vpcBss = model.bss.filter((b) => vpcBsNames.includes(b.name));

  // 帶（band）＝流量鏈的一段。全部先算好尺寸，框高才會剛好包住。
  const bands = [];
  const addBand = (b) => {
    if (!b.items.length) return;
    const gs = gridSize(b.items.length, L.maxPerLine, L.tileW, L.tileH);
    b.grid = gs;
    b.h = L.bandPadTop + gs.h + 10;
    bands.push(b);
  };

  addBand({ key: 'extfr', title: '外部轉送規則（網際網路入口）', color: GCP.blue, items: v.frs.filter((f) => f.external) });
  addBand({ key: 'proxy', title: '目標代理 ＋ URL 對應', color: GCP.blue, items: uniq(v.frs.map((f) => f.proxy).filter(Boolean)) });
  addBand({ key: 'bs', title: '後端服務', color: GCP.blue, items: vpcBss });
  addBand({ key: 'gke', title: 'GKE 叢集', color: GCP.green, items: v.gkes });
  addBand({ key: 'mig', title: '執行個體群組（受管 MIG／未受管／未掃描到）', color: GCP.grey, items: v.groups });
  addBand({ key: 'vm', title: 'Compute Engine VM（⚠＝有外部 IP 且被 0.0.0.0/0 的 allow 規則套用）', color: GCP.grey, items: v.vms });
  addBand({ key: 'sql', title: 'Cloud SQL', color: GCP.yellow, items: v.sqls });
  addBand({ key: 'intfr', title: '內部轉送規則／Private Service Connect 端點', color: GCP.blue, items: v.frs.filter((f) => !f.external) });

  // 子網表：GCP 的子網是區域資源，每區域一欄。**不分公私**——GCP 沒有那種區分
  const regions = v.shownRegions;
  const maxSub = Math.max(1, ...regions.map((r) => v.shownSubnets.filter((s) => s.region === r).length));
  const regionW = L.subW + 2 * L.regionPad;
  const gridW = Math.max(1, regions.length) * regionW + Math.max(0, regions.length - 1) * L.regionGap;
  const regionH = 34 + maxSub * (L.subH + L.subGap) + 6;

  const innerW = Math.max(gridW, ...bands.map((b) => b.grid.w + 40), 900);
  const frameW = innerW + 2 * L.frameMargin;
  const M = L.frameMargin;
  const routerH = v.routers.length ? 170 : 0;
  const frameH =
    60 + routerH + bands.reduce((n, b) => n + b.h + L.bandGap, 0) + 40 + regionH + (v.hiddenSubnets.length ? 40 : 0) + 40;

  const frame = pg.vertex(
    `f-${v.name}`,
    '1',
    `VPC 網路 ${v.name}（${v.mode} 模式，路由 ${v.routing}）｜專案 ${model.project}｜有子網的區域：${v.regions.join('、')}`,
    STYLES.vpc,
    40,
    40,
    frameW,
    frameH
  );

  let y = 50;

  // Cloud Router／NAT
  if (v.routers.length) {
    v.routers.forEach((rt, i) => {
      const nats = (rt.nats || []).map((n) => n.name);
      pg.vertex(
        `${v.name}-router-${rt.name}`,
        frame,
        `${rt.name}<br>${last(rt.region)}<br>${nats.length ? `Cloud NAT ${nats.join('、')}` : '無 NAT（僅 BGP／VPN）'}`,
        nats.length ? STYLES.nat : STYLES.router,
        M + i * L.tileW,
        y,
        L.icon,
        L.icon
      );
    });
    y += routerH;
  }

  const cellOf = new Map(); // 'kind:name' → cell id，供邊查找
  const put = (k, n, id) => cellOf.set(`${k}:${n}`, id);
  const get = (k, n) => cellOf.get(`${k}:${n}`);

  for (const band of bands) {
    const bandCell = pg.vertex(`${v.name}-band-${band.key}`, frame, band.title, STYLES.band(band.color), M, y, innerW, band.h);
    const gs = band.grid;
    const slotW = (innerW - 20) / gs.cols;
    band.items.forEach((item, i) => {
      const col = i % gs.cols;
      const line = Math.floor(i / gs.cols);
      const ix = 10 + col * slotW + (slotW - L.icon) / 2;
      const iy = L.bandPadTop + line * L.tileH;
      drawVpcPageItem(pg, bandCell, band, item, ix, iy, drawn, put);
    });
    y += band.h + L.bandGap;
  }

  // ── 可證明的邊 ──
  // 1. 轉送規則 → 目標代理 → 後端服務
  for (const f of v.frs) {
    if (f.proxy) {
      pg.edge(`e-${v.name}-fr-${f.name}`, get('fr', f.name), get('proxy', f.proxy.name), f.ports.join(','), V_FLOW);
      for (const bs of f.backendServices) {
        pg.edge(`e-${v.name}-px-${f.proxy.name}-${bs.name}`, get('proxy', f.proxy.name), get('bs', bs.name), '', V_FLOW);
      }
    } else {
      for (const bs of f.backendServices) {
        pg.edge(`e-${v.name}-fr-${f.name}-${bs.name}`, get('fr', f.name), get('bs', bs.name), f.ports.join(','), V_FLOW);
      }
    }
  }
  // 2. 後端服務 → 執行個體群組（backends[].group 名稱比對）
  for (const bs of vpcBss) {
    for (const grp of bs.groups) {
      pg.edge(
        `e-${v.name}-bs-${bs.name}-${grp}`,
        get('bs', bs.name),
        get('mig', grp),
        `${bs.protocol}${bs.port ? ':' + bs.port : ''}`,
        V_FLOW
      );
    }
  }
  // 3. GKE → MIG（selfLink，實線）
  for (const g of v.gkes) {
    for (const m of g.migs) pg.edge(`e-${v.name}-gke-${g.name}-${m.name}`, get('gke', g.name), get('mig', m.name), '', V_FLOW);
  }
  // 4. MIG → VM（baseInstanceName 前綴＝命名規則推導，非 selfLink，故虛線）
  for (const m of v.groups) {
    for (const vm of m.members) {
      pg.edge(`e-${v.name}-mig-${m.name}-${vm.name}`, get('mig', m.name), get('vm', vm.name), '', V_FLOW + STYLES.edgeInferred);
    }
  }
  // 5. VM → Cloud SQL
  for (const { vm, db, via } of model.vmToSql) {
    if (vm.network !== v.name) continue;
    pg.edge(`e-${v.name}-sql-${vm.name}-${db.name}`, get('vm', vm.name), get('sql', db.name), via, V_FLOW);
  }
  // 6. 唯讀複本 → 主執行個體
  for (const db of v.sqls) {
    if (db.isReplica && db.master) {
      pg.edge(`e-${v.name}-repl-${db.name}`, get('sql', db.master), get('sql', db.name), '複寫', H_FLOW);
    }
  }

  // ── 子網表 ──
  pg.vertex(
    `${v.name}-grid-label`,
    frame,
    '子網（區域資源；GCP 沒有公有／私有子網之分。⚠＝既無 Private Google Access 也無 Cloud NAT）',
    STYLES.label,
    M,
    y,
    innerW,
    20
  );
  y += 30;
  regions.forEach((region, ri) => {
    const rx = M + ri * (regionW + L.regionGap);
    const rCell = pg.vertex(`${v.name}-region-${region}`, frame, region, STYLES.regionBox, rx, y, regionW, regionH);
    v.shownSubnets
      .filter((s) => s.region === region)
      .sort(byName)
      .forEach((s, i) => {
        pg.vertex(
          `${v.name}-sub-${s.key}`,
          rCell,
          subnetLabel(s),
          subnetWarn(s) ? STYLES.subTileWarn : STYLES.subTile,
          L.regionPad,
          34 + i * (L.subH + L.subGap),
          L.subW,
          L.subH
        );
        drawn.subnet++;
      });
  });
  if (v.hiddenSubnets.length) {
    pg.vertex(
      `${v.name}-subhidden`,
      frame,
      `另有 ${v.hiddenSubnets.length} 個自動建立的子網分布在沒有任何資源的區域，未逐一繪出（明細見 data/network/subnets.json）`,
      STYLES.subTileMuted,
      M,
      y + regionH + 10,
      innerW,
      26
    );
    drawn.subnetAccounted += v.hiddenSubnets.length;
  }

  pg.width = 40 + frameW + 60;
  pg.height = 40 + frameH + 60;
  return pg;
}

function drawVpcPageItem(pg, bandCell, band, item, ix, iy, drawn, put) {
  const L = LAYOUT;
  switch (band.key) {
    case 'extfr':
    case 'intfr': {
      const id = pg.vertex(
        `fr-${item.name}`,
        bandCell,
        `${item.name}<br>${item.ip}${item.ports.length && item.ports[0] ? `　${item.protocol}:${item.ports.join(',')}` : ''}` +
          `<br>${item.isPsc ? 'Private Service Connect' : item.scheme}${item.subnet ? `<br>子網 ${item.subnet}` : ''}`,
        item.isPsc ? STYLES.psc : STYLES.lb,
        ix,
        iy,
        L.icon,
        L.icon
      );
      put('fr', item.name, id);
      drawn.forwardingRule++;
      return;
    }
    case 'proxy': {
      const id = pg.vertex(
        `proxy-${item.name}`,
        bandCell,
        `${item.name}<br>${item.kind}${item.certs.length ? `<br>憑證 ${item.certs.length}` : ''}` +
          `${item.urlMap ? `<br>URL 對應 ${item.urlMap}` : ''}` +
          `${item.kind === 'HTTPS' && !item.sslPolicy ? `<br><font color="${GCP.yellow}">⚠ 未指定 SSL 政策</font>` : ''}`,
        STYLES.lb,
        ix,
        iy,
        L.icon,
        L.icon
      );
      put('proxy', item.name, id);
      return;
    }
    case 'bs': {
      const armor = item.securityPolicy
        ? `<br>Armor ${item.securityPolicy}`
        : /^EXTERNAL/.test(item.scheme)
          ? `<br><font color="${GCP.red}">⚠ 未掛 Cloud Armor</font>`
          : '';
      const id = pg.vertex(
        `bs-${item.name}`,
        bandCell,
        `${item.name}<br>${item.scheme}　${item.protocol}${item.port ? `:${item.port}` : ''}` +
          `<br>健康檢查 ${item.healthChecks.join('、') || '無'}` +
          `${item.cdn ? '<br>Cloud CDN 開' : ''}${item.iap ? '<br>IAP 開' : ''}` +
          `${item.logging ? '' : `<br><font color="${GCP.yellow}">⚠ 存取記錄未開</font>`}${armor}`,
        STYLES.lb,
        ix,
        iy,
        L.icon,
        L.icon
      );
      put('bs', item.name, id);
      drawn.backendService++;
      return;
    }
    case 'gke': {
      const id = pg.vertex(
        `gke-${item.name}`,
        bandCell,
        `${item.name}<br>${item.mode}　${item.location}<br>節點 ${item.nodeCount}<br>${item.version}` +
          `${item.privateNodes ? '<br>私有節點' : `<br><font color="${GCP.yellow}">⚠ 節點非私有</font>`}` +
          `${item.privateEndpoint ? '<br>私有控制平面端點' : ''}` +
          `${
            item.authorizedNetworks.length
              ? `<br>主控授權網段 ${item.authorizedNetworks.length}`
              : `<br><font color="${GCP.yellow}">⚠ 無主控授權網段</font>`
          }`,
        STYLES.gke,
        ix,
        iy,
        L.icon,
        L.icon
      );
      put('gke', item.name, id);
      drawn.gke++;
      return;
    }
    case 'mig': {
      const id = pg.vertex(
        `mig-${item.name}`,
        bandCell,
        groupLabel(item),
        STYLES.mig,
        ix,
        iy,
        L.icon,
        L.icon
      );
      put('mig', item.name, id);
      if (!item.unresolved) drawn.group++;
      return;
    }
    case 'vm': {
      const id = pg.vertex(`vm-${item.name}`, bandCell, vmLabel(item), STYLES.vm, ix, iy, L.icon, L.icon);
      put('vm', item.name, id);
      drawn.vm++;
      return;
    }
    case 'sql': {
      const id = pg.vertex(`sql-${item.name}`, bandCell, sqlLabel(item), STYLES.sql, ix, iy, L.icon, L.icon);
      put('sql', item.name, id);
      drawn.sql++;
      return;
    }
    default:
      return;
  }
}

// ---------- 主流程 ----------
function main() {
  const opts = parseArgs(process.argv);
  const model = loadModel();

  // 兩套獨立計數器：全景架構頁把每樣東西各畫一次，與逐 VPC 頁不混用（混用會重複計數）
  const zero = () => ({
    subnet: 0,
    subnetAccounted: 0,
    vm: 0,
    vmAccounted: 0,
    sql: 0,
    sqlAccounted: 0,
    group: 0,
    groupAccounted: 0,
    gke: 0,
    gkeAccounted: 0,
    bucket: 0,
    bucketAccounted: 0,
    forwardingRule: 0,
    forwardingRuleAccounted: 0,
    backendService: 0,
    backendServiceAccounted: 0,
  });
  const sd = zero();
  const drawn = zero();

  const pages = [buildSummary(model, sd), buildOverview(model, drawn)];
  for (const v of model.networks) {
    if (v.hasWorkload) pages.push(buildVpcPage(model, v, drawn));
  }

  // ---- 自我檢查：畫出數量必須等於來源 JSON 數量 ----
  // 「摺疊」（自動模式的無資源區域子網、收進 MIG／GKE 的節點 VM、無工作負載的 VPC）
  // 一律計進 *Accounted，總和仍須等於來源——不容許靜默漏畫。
  const vpcBsNames = uniq(model.networks.flatMap((v) => v.frs.flatMap((f) => f.bsNames)));
  const src = {
    subnet: model.subnets.length,
    vm: model.vms.length,
    sql: model.sqls.length,
    group: model.groups.filter((g) => !g.unresolved).length,
    gke: model.gkes.length,
    bucket: model.buckets.length,
    forwardingRule: model.frs.length,
    backendService: model.bss.filter((b) => vpcBsNames.includes(b.name)).length,
  };

  const KEYS = ['subnet', 'vm', 'sql', 'group', 'gke', 'bucket', 'forwardingRule', 'backendService'];
  const problems = [];
  const check = (who, c) => {
    for (const k of KEYS) {
      const acc = c[`${k}Accounted`] || 0;
      if (c[k] + acc !== src[k]) problems.push(`${who} ${k}：畫出 ${c[k]}＋摺疊計數 ${acc} ≠ 來源 ${src[k]}`);
    }
  };
  check('全景架構頁', sd);
  check('索引頁＋各 VPC 頁', drawn);
  if (problems.length) fail(`計數斷言失敗：\n  - ${problems.join('\n  - ')}`);

  const xml =
    '<mxfile host="build-diagram.js" agent="build-diagram.js" version="1" type="device">\n' +
    pages.map((p) => p.toXml()).join('\n') +
    '\n</mxfile>\n';

  fs.mkdirSync(path.dirname(opts.out), { recursive: true });
  fs.writeFileSync(opts.out, xml, 'utf8');

  const rel = path.relative(WORK_ROOT, opts.out);
  const fmt = (c) =>
    `子網 ${c.subnet}＋${c.subnetAccounted}/${src.subnet}、VM ${c.vm}＋${c.vmAccounted}/${src.vm}、` +
    `執行個體群組 ${c.group}＋${c.groupAccounted}/${src.group}、GKE ${c.gke}＋${c.gkeAccounted}/${src.gke}、` +
    `Cloud SQL ${c.sql}＋${c.sqlAccounted}/${src.sql}、轉送規則 ${c.forwardingRule}＋${c.forwardingRuleAccounted}/${src.forwardingRule}、` +
    `後端服務 ${c.backendService}/${src.backendService}、值區 ${c.bucket}/${src.bucket}`;

  console.log(`已產生 ${rel}（${pages.length} 頁）`);
  console.log(`  分頁：${pages.map((p) => p.name).join('、')}`);
  console.log(`  全景架構頁（畫出＋摺疊/來源）：${fmt(sd)}`);
  console.log(`  索引頁＋各 VPC 頁（畫出＋摺疊/來源）：${fmt(drawn)}`);

  // 實際暴露面：這是本圖最該被覆核的一行，直接印出來，不要讓人自己去圖上數
  const withExt = model.vms.filter((v) => v.externalIPs.length);
  const exposed = model.vms.filter((v) => v.exposed);
  console.log(
    `  暴露面：有外部 IP 的 VM ${withExt.length}/${model.vms.length}，` +
      `其中「外部 IP ＋ 被 0.0.0.0/0 的 allow 規則套用」＝ ${exposed.length} 台` +
      (exposed.length ? `（${exposed.map((v) => v.name).join('、')}）` : '') +
      (withExt.length - exposed.length ? `；另 ${withExt.length - exposed.length} 台有外部 IP 但無 0.0.0.0/0 規則套用` : '')
  );
  const openSql = model.sqls.filter((d) => d.publicIP);
  if (openSql.length) {
    console.log(
      `  Cloud SQL 公開 IP：${openSql.length} 個` +
        `（${openSql.map((d) => `${d.name}${d.openToWorld ? ' ⚠授權 0.0.0.0/0' : ` 授權 ${d.authNets.length} 網段`}`).join('、')}）`
    );
  }
  if (GAPS.length) {
    console.log(`  ⚠ 資料缺口（查詢失敗，非「未設定」）：${GAPS.length} 項`);
    for (const g of GAPS) console.log(`      - ${g}`);
  }
  console.log('  請用 app.diagrams.net 或 VS Code Draw.io 擴充開啟目視確認（可對照 data/inventory.md）');
}

main();
