#!/usr/bin/env python3
"""跨檔關聯：把「要比對好幾個檔才看得出來」的 GCP 網路事實直接算成結論。

由 scripts/digest.sh 呼叫，只讀本機 data/，不呼叫 GCP。

為什麼要有這支：
  這種「機械性的跨檔比對」不該交給 LLM 判斷——它會忘、會隨機。實際發生過：
  證據全都在 data/ 裡，但需要跨三個檔交叉比對，LLM 沒做這一步，把一項 [高] 發現降級成 [中]，
  還給出該環境根本做不到的修復建議。算成事實表之後，agent 讀到的直接是結論，沒有機會漏。

GCP 特有、最容易被誤判的三件事（本檔的三個區塊）：
  1. **防火牆規則的實際暴露面**：GCP 防火牆是「標籤／服務帳戶導向」的。
     一條 `allow 0.0.0.0/0 → tcp:22` 的規則，可能一台機器都沒套用（沒有 VM 帶那個標籤），
     也可能套用到全網路（沒有 targetTags ＝ 套用到該網路所有 VM）。
     「規則存在」與「真的暴露」是兩回事，只看 firewall-rules.json 必然誤判。
  2. **VM 的實際對外路徑**：GCP 沒有「公有子網／私有子網」的概念。
     對外可及性取決於「VM 有沒有 external IP」，對外連出則取決於 Cloud NAT。
     套用「公有子網／私有子網」的心智模型會得到錯誤結論。
  3. **Cloud SQL 的實際可及性**：public IP × authorizedNetworks × SSL 模式三者要一起看。
     只有 public IP 但授權網路為空 ≠ 對外開放；public IP ＋ 0.0.0.0/0 授權 ＝ 全網際網路可連。

注意：本檔對 deny 規則的覆蓋判斷是**保守近似**（比對優先序與協定，不做精確的埠範圍交集）。
      標為「可能被 deny 覆蓋」者仍需人工確認，不可直接當成安全。
"""
import json
import os
import sys

# 輸出資料跟著 cwd 走（由 digest.sh 從專案根目錄呼叫），腳本本身住在 skill 目錄
DATA = os.path.join(os.getcwd(), "data")
DIGEST = os.path.join(DATA, "digest")


def load(*parts):
    try:
        with open(os.path.join(DATA, *parts)) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def last(path):
    """把 GCP 的完整資源 URL 取最後一段（self link → 名稱）。"""
    if not path:
        return None
    return str(path).rstrip("/").split("/")[-1]


def ports_of(allowed):
    """allow 條目 → 可讀的協定:埠字串。沒有 ports 欄位＝該協定全部埠。"""
    out = []
    for a in allowed or []:
        proto = a.get("IPProtocol", "?")
        p = a.get("ports") or []
        out.append(f"{proto}:{'all' if not p else ','.join(p)}")
    return out


def rule_applies(rule, vm):
    """防火牆規則是否套用到這台 VM（同網路 ＋ 標籤／服務帳戶比對）。

    沒有 targetTags 也沒有 targetServiceAccounts ＝ 套用到該網路的**所有** VM。
    這一條是 GCP 防火牆最常被忽略的語意。
    """
    vm_nets = {ni.get("network") for ni in vm.get("networkInterfaces") or []}
    if last(rule.get("network")) not in vm_nets:
        return False
    tags = set(rule.get("targetTags") or [])
    sas = set(rule.get("targetServiceAccounts") or [])
    if not tags and not sas:
        return True
    if tags & set(vm.get("tags") or []):
        return True
    vm_sas = {sa.get("email") for sa in vm.get("serviceAccounts") or []}
    return bool(sas & vm_sas)


def external_ips(vm):
    ips = []
    for ni in vm.get("networkInterfaces") or []:
        for ac in ni.get("accessConfigs") or []:
            if ac.get("natIP"):
                ips.append(ac["natIP"])
            else:
                # accessConfig 存在但沒有 natIP＝臨時外部 IP 尚未配發／已停止的機器
                ips.append("(有外部 IP 設定，目前未配發)")
    return ips


def firewall_exposure(out, fw, vms):
    out.append("\n## 1. 防火牆規則的實際暴露面\n")
    out.append("GCP 防火牆是**標籤／服務帳戶導向**：規則存在 ≠ 有機器套用。本表把")
    out.append("`network/firewall-rules.json` × `compute/instances.json` 交叉算出「真的有 VM 套用」的規則。\n")
    out.append("判定「暴露在網際網路」需同時成立：規則為 INGRESS allow、來源含 `0.0.0.0/0`、未停用、")
    out.append("**且套用的 VM 具有外部 IP**。VM 無外部 IP 時，該規則不構成直接的網際網路暴露")
    out.append("（但仍可能經由負載平衡器或 IAP 到達，見下方註記）。\n")

    open_rules = [
        r for r in fw
        if r.get("direction", "INGRESS") == "INGRESS"
        and not r.get("disabled")
        and r.get("allowed")
        and "0.0.0.0/0" in (r.get("sourceRanges") or [])
    ]
    deny_rules = [
        r for r in fw
        if r.get("direction", "INGRESS") == "INGRESS" and not r.get("disabled") and r.get("denied")
    ]

    if not open_rules:
        out.append("**無**：沒有任何來源為 `0.0.0.0/0` 的 INGRESS allow 規則（已排除停用的規則）。")
    else:
        out.append("| 規則 | 網路 | 優先序 | 開放 | 套用範圍 | 套用到的 VM（有外部 IP 者以 **粗體** 標示） | 記錄 |")
        out.append("|---|---|---:|---|---|---|---|")
        for r in sorted(open_rules, key=lambda x: x.get("priority", 1000)):
            applied = [v for v in vms if rule_applies(r, v)]
            cells = []
            for v in applied:
                eips = external_ips(v)
                cells.append(f"**{v['name']}**（{eips[0]}）" if eips else v["name"])
            if not applied:
                who = "（無任何 VM 套用）"
            else:
                who = "、".join(cells)
            tags = r.get("targetTags") or []
            sas = r.get("targetServiceAccounts") or []
            if not tags and not sas:
                scope = "**全網路所有 VM**"
            else:
                scope = "標籤 " + ",".join(tags) if tags else ""
                if sas:
                    scope += ("；" if scope else "") + "服務帳戶 " + ",".join(last(s) or s for s in sas)
            log = "開啟" if (r.get("logConfig") or {}).get("enable") else "未開啟"
            out.append(
                f"| `{r.get('name')}` | {last(r.get('network'))} | {r.get('priority', '?')} | "
                f"{' '.join(ports_of(r.get('allowed')))} | {scope} | {who} | {log} |"
            )

        # 真正暴露的 VM 清單（結論列，避免 agent 自己再推一次）
        exposed = []
        for r in open_rules:
            for v in vms:
                if rule_applies(r, v) and external_ips(v):
                    exposed.append((v["name"], external_ips(v)[0], r.get("name"),
                                    " ".join(ports_of(r.get("allowed")))))
        out.append("\n### 結論：實際暴露在網際網路的 VM 與埠\n")
        if exposed:
            out.append("| VM | 外部 IP | 經由規則 | 開放埠 |")
            out.append("|---|---|---|---|")
            for name, ip, rule, ports in sorted(set(exposed)):
                out.append(f"| **{name}** | {ip} | `{rule}` | {ports} |")
            out.append("")
            out.append("以上為**確定性交叉比對的結果**，不是推測。若某台 VM 開放 22／3389／資料庫埠給")
            out.append("`0.0.0.0/0`，即為高嚴重度發現，不得降級。")
        else:
            out.append("無：所有套用到開放規則的 VM 都沒有外部 IP（或沒有 VM 套用該規則）。")

        if deny_rules:
            out.append("\n> 註：本專案另有 " + str(len(deny_rules)) + " 條 INGRESS deny 規則"
                       "（`" + "`、`".join(str(r.get("name")) for r in deny_rules) + "`）。")
            out.append("> 優先序較高（數字較小）的 deny 規則可能覆蓋上述 allow；本表**不做精確的埠範圍交集**，")
            out.append("> 引用前請對回 `data/network/firewall-rules.json` 確認優先序與埠範圍。")

    out.append("\n> 註：VM 無外部 IP 不代表完全不可達——經由外部負載平衡器（`lb/forwarding-rules.json`）")
    out.append("> 的流量會以 Google 前端的來源位址到達後端，需搭配 `lb/backend-services.json` 一起判斷。")
    out.append("\n> 註：Filestore（受管 NFS）等透過 Private Service Access／VPC Peering 連接的儲存資源")
    out.append("> **沒有公開 IP 的概念**，不會出現在上面的網際網路暴露判定裡——其可及性完全取決於綁定 VPC")
    out.append("> 的**內部路由與防火牆**，以及 NFS 匯出選項（`nfsExportOptions`：哪些網段能掛載、讀寫或唯讀）。")
    out.append("> 因此 Filestore 不另立跨檔關聯段落（其 VPC 綁定是單檔即可得的事實，無需跨檔比對）；")
    out.append("> 若專案有 Filestore，綁定的 VPC／保留網段／連線模式／NFS 匯出控制見 `data/digest/filestore-instances.md`。")


def vm_paths(out, vms, subnets, routers):
    out.append("\n## 2. VM 的實際對外路徑\n")
    out.append("GCP **沒有**「公有子網／私有子網」的概念（套用該心智模型會得到錯誤結論）：")
    out.append("對外**可及性**看 VM 有沒有外部 IP；對外**連出**看該子網有沒有被 Cloud NAT 覆蓋；")
    out.append("存取 Google API 則看子網的 Private Google Access。\n")

    # 子網 → 是否被某個 Cloud NAT 覆蓋
    nat_all_nets = set()          # 覆蓋整個網路所有子網範圍的 NAT
    nat_subnets = {}              # 子網名 → NAT 名
    for rt in routers or []:
        net = last(rt.get("network"))
        for nat in rt.get("nats") or []:
            mode = nat.get("sourceSubnetworkIpRangesToNat")
            if mode == "ALL_SUBNETWORKS_ALL_IP_RANGES":
                nat_all_nets.add(net)
            for sn in nat.get("subnetworks") or []:
                nat_subnets[last(sn.get("name"))] = nat.get("name")

    out.append("### 子網組態\n")
    out.append("| 子網 | 網路 | 區域 | CIDR | Private Google Access | 流量記錄 | Cloud NAT |")
    out.append("|---|---|---|---|---|---|---|")
    for s in sorted(subnets or [], key=lambda x: str(x.get("name"))):
        net = last(s.get("network"))
        name = s.get("name")
        if net in nat_all_nets:
            nat = "有（整個網路）"
        elif name in nat_subnets:
            nat = f"有（{nat_subnets[name]}）"
        else:
            nat = "**無**"
        out.append(
            f"| {name} | {net} | {last(s.get('region'))} | {s.get('ipCidrRange')} | "
            f"{'啟用' if s.get('privateIpGoogleAccess') else '**未啟用**'} | "
            f"{'啟用' if (s.get('logConfig') or {}).get('enable') else '未啟用'} | {nat} |"
        )

    out.append("\n### VM 對外可及性\n")
    if not vms:
        out.append("本專案沒有 Compute Engine VM（掃描回空清單＝有效證據）。")
        return
    out.append("| VM | 狀態 | 機型 | 子網 | 內部 IP | 外部 IP | 標籤 | 服務帳戶 scope |")
    out.append("|---|---|---|---|---|---|---|---|")
    for v in sorted(vms, key=lambda x: str(x.get("name"))):
        nis = v.get("networkInterfaces") or []
        sub = "、".join(filter(None, (ni.get("subnetwork") for ni in nis))) or "-"
        internal = "、".join(filter(None, (ni.get("networkIP") for ni in nis))) or "-"
        eips = external_ips(v)
        ext = f"**{eips[0]}**" if eips else "無"
        scopes = []
        for sa in v.get("serviceAccounts") or []:
            for sc in sa.get("scopes") or []:
                if sc.endswith("/cloud-platform"):
                    scopes.append("**cloud-platform（全域）**")
                else:
                    scopes.append(last(sc) or sc)
        out.append(
            f"| {v.get('name')} | {v.get('status')} | {v.get('machineType')} | {sub} | {internal} | "
            f"{ext} | {','.join(v.get('tags') or []) or '-'} | {'、'.join(sorted(set(scopes))) or '-'} |"
        )


def sql_reachability(out, sqls):
    out.append("\n## 3. Cloud SQL 的實際可及性\n")
    if not sqls:
        out.append("本專案沒有 Cloud SQL 執行個體（掃描回空清單＝有效證據）。")
        return
    out.append("public IP × 授權網路 × SSL 模式**三者要一起看**：有 public IP 但授權網路為空 ≠ 對外開放；")
    out.append("public IP ＋ `0.0.0.0/0` 授權 ＝ 全網際網路可連，屬高嚴重度。\n")
    out.append("| 執行個體 | 版本 | 公開 IP | 授權網路 | SSL | 私有網路 | 高可用 | 自動備份 | PITR | 判定 |")
    out.append("|---|---|---|---|---|---|---|---|---|---|")
    for db in sqls:
        st = db.get("settings") or {}
        ipc = st.get("ipConfiguration") or {}
        pub_ips = [a.get("ipAddress") for a in db.get("ipAddresses") or [] if a.get("type") == "PRIMARY"]
        authnets = [a.get("value") for a in ipc.get("authorizedNetworks") or []]
        open_world = "0.0.0.0/0" in authnets
        ssl = ipc.get("sslMode") or ("REQUIRED" if ipc.get("requireSsl") else "未強制")
        priv = last(ipc.get("privateNetwork")) or "無"
        bkp = (st.get("backupConfiguration") or {})
        if pub_ips and open_world:
            verdict = "**[高] 公開 IP ＋ 授權 0.0.0.0/0 ＝ 全網際網路可連**"
        elif pub_ips and authnets:
            verdict = f"公開 IP，限 {len(authnets)} 個授權網段"
        elif pub_ips:
            verdict = "有公開 IP 但無授權網路（僅 Cloud SQL Proxy／IAM 可連）"
        else:
            verdict = "僅私有 IP"
        # PITR 兩個欄位是**引擎相依**的（Cloud SQL Admin API 官方定義）：
        #   binaryLogEnabled          → 官方註明 "(MySQL only)"，MySQL 的 PITR 靠二進位記錄
        #   pointInTimeRecoveryEnabled → PostgreSQL／SQL Server 用這個
        # 故以 or 涵蓋兩種引擎；只看其中一個會對另一種引擎報出相反的結論。
        out.append(
            f"| `{db.get('name')}` | {db.get('databaseVersion')} | "
            f"{('**' + pub_ips[0] + '**') if pub_ips else '無'} | "
            f"{('**' + ', '.join(authnets) + '**') if open_world else (', '.join(authnets) or '無')} | "
            f"{ssl} | {priv} | {st.get('availabilityType', '?')} | "
            f"{'啟用' if bkp.get('enabled') else '**未啟用**'} | "
            f"{'啟用' if bkp.get('pointInTimeRecoveryEnabled') or bkp.get('binaryLogEnabled') else '未啟用'} | "
            f"{verdict} |"
        )


def serverless_paths(out, runs, connectors, ae_services, ae_versions):
    """第四段：無伺服器資源（Cloud Run／App Engine）的網路路徑。

    GCP 的無伺服器資源沒有「公有／私有子網」，網路歸屬看兩件事：
      Ingress  — 誰能呼叫它（對外開放 vs 僅內部）
      VPC egress — 它連出去走哪個 VPC。兩種走法：
        Serverless VPC Access **connector**（要反查 vpc-connectors.json 拿 connector 綁的網路）
        **Direct VPC egress**（Cloud Run）／**Flexible 環境 network**（App Engine）
    這正是使用者截圖抓到的誤判來源：只看 list 層級會把有 VPC 出口的服務誤標成「不屬於任何 VPC」。
    App Engine 的 Ingress 在 **service** 層（networkSettings.ingressTrafficAllowed），VPC 出口在
    **version** 層（vpcAccessConnector／network），兩者分屬不同資源，需一起看。
    """
    out.append("\n## 4. 無伺服器資源的網路路徑\n")
    out.append("Cloud Run／Cloud Functions／App Engine **沒有公有／私有子網**，其網路歸屬看 **Ingress**")
    out.append("（誰能呼叫它）與 **VPC egress**（它連出去走哪個 VPC）。VPC 出口走 Serverless VPC Access")
    out.append("**connector**（要反查 connector 綁定的網路）、Cloud Run 的 **Direct VPC egress**，或")
    out.append("App Engine Flexible 環境的 **network** 直接綁定。只看清單層級會漏掉這層，把有 VPC 出口的")
    out.append("服務誤標成「不屬於任何 VPC」。\n")

    # connector 名 → 綁定的 network（Cloud Run 與 App Engine 共用此反查）
    conn_net = {}
    for c in connectors or []:
        conn_net[last(c.get("name"))] = last(c.get("network"))

    # ── Cloud Run ──
    out.append("### Cloud Run\n")
    if runs is None:
        out.append("本專案沒有 Cloud Run 服務或 Cloud Run API 未啟用（`digest/run-services.json` 不存在）。")
    elif not runs:
        out.append("本專案沒有 Cloud Run 服務（掃描回空清單＝有效證據）。")
    else:
        out.append("| 服務 | Ingress 設定 | VPC 路由方式 | 路由進的 VPC | egress 模式 |")
        out.append("|---|---|---|---|---|")
        for r in runs:
            name = r.get("name")
            ingress = r.get("ingress") or "?"
            va = r.get("vpcAccess") or {}
            connector = va.get("connector")
            nis = va.get("networkInterfaces") or []
            if connector:
                via = "connector"
                cn = last(connector)
                vpc = conn_net.get(cn) or f"（connector {cn}，未反查到綁定網路）"
            elif nis:
                via = "Direct VPC egress"
                vpc = "、".join(filter(None, (last(ni.get("network")) for ni in nis))) or "（未指定 network）"
            else:
                via = "無"
                vpc = "—"
            if ingress == "INGRESS_TRAFFIC_ALL":
                ing = f"**{ingress}（對外開放）**"
            elif ingress in ("INGRESS_TRAFFIC_INTERNAL_ONLY", "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"):
                ing = f"{ingress}（僅內部）"
            else:
                ing = ingress
            egress = va.get("egress") or ("PRIVATE_RANGES_ONLY（預設）" if via != "無" else "—")
            out.append(f"| `{name}` | {ing} | {via} | {vpc} | {egress} |")
        out.append("")
        out.append("> Ingress＝`INGRESS_TRAFFIC_ALL` 者可從網際網路直接呼叫（除非另有 Cloud Armor／IAP 把關），")
        out.append("> 屬對外暴露面。egress＝`ALL_TRAFFIC` 代表所有出站流量（含公有網際網路）都導進 VPC；")
        out.append("> `PRIVATE_RANGES_ONLY`（預設）只有私有網段走 VPC。")
        out.append("> ⚠️ Cloud Run 的 `ingress`／`vpcAccess` 欄位路徑尚未經真實資料驗證（本專案 API 未啟用），")
        out.append("> 引用前對回 `data/digest/run-services.json` 與原始 describe 檔確認。")

    # ── App Engine ──
    out.append("\n### App Engine\n")
    if ae_services is None and ae_versions is None:
        out.append("本專案未建立 App Engine 應用（`gcloud app describe` 回「does not contain an App Engine "
                   "application」＝未設定／有效證據，非資料缺口；`digest/appengine-*.json` 不存在）。")
    else:
        out.append("**服務層 Ingress 控制**（`networkSettings.ingressTrafficAllowed`，決定誰能呼叫服務）：\n")
        if not ae_services:
            out.append("（App Engine 應用存在但沒有任何服務，或服務層 describe 未取得）\n")
        else:
            out.append("| 服務 | Ingress 允許來源 |")
            out.append("|---|---|")
            for s in ae_services:
                ing = s.get("ingress") or "?"
                if "INTERNAL_ONLY" in ing:
                    label = f"{ing}（僅 VPC 內部）"
                elif "INTERNAL_AND_LB" in ing:
                    label = f"{ing}（VPC 內部＋負載平衡器）"
                elif "ALL" in ing:
                    label = f"**{ing}（公開＋私有皆可呼叫，對外開放）**"
                else:
                    label = ing
                out.append(f"| `{s.get('name')}` | {label} |")

        out.append("\n**版本層 VPC 出口與環境**（`vpcAccessConnector`／`network`／`env`）：\n")
        if not ae_versions:
            out.append("（沒有任何版本，或版本層 describe 未取得）")
        else:
            out.append("| 服務 | 版本 | 環境 | 狀態 | VPC 出口方式 | 出口 VPC | egress 設定 |")
            out.append("|---|---|---|---|---|---|---|")
            for v in ae_versions:
                connector = v.get("vpcConnector")
                net = v.get("network")
                if connector:
                    via = "Serverless VPC Access connector"
                    cn = last(connector)
                    vpc = conn_net.get(cn) or f"（connector {cn}，未反查到綁定網路）"
                elif net:
                    via = "Flexible 環境 network"
                    vpc = net + (f"/{v['subnetwork']}" if v.get("subnetwork") else "")
                else:
                    via = "無"
                    vpc = "—"
                egress = v.get("vpcEgressSetting") or ("—" if via == "無" else "（預設）")
                out.append(
                    f"| `{v.get('service')}` | {v.get('version')} | {v.get('env') or '?'} | "
                    f"{v.get('servingStatus') or '?'} | {via} | {vpc} | {egress} |"
                )
        out.append("")
        out.append("> App Engine Standard 環境的對外連出走 **Serverless VPC Access connector**")
        out.append("> （`vpcAccessConnector`）；Flexible 環境可直接綁 `network`／`subnetworkName`（性質接近 VM）。")
        out.append("> Ingress＝`INGRESS_TRAFFIC_ALLOWED_ALL`（或 networkSettings 缺席的預設值）者可從網際網路")
        out.append("> 直接呼叫，屬對外暴露面，須併同 VM／Cloud SQL／Cloud Run 一起評估。")
        out.append("> ⚠️ App Engine 的 service／version 網路欄位路徑尚未經真實資料驗證（本專案未建立 App Engine 應用），")
        out.append("> 引用前對回 `data/digest/appengine-services.json`／`appengine-versions.json` 與原始 describe 檔確認。")


def main():
    if not os.path.exists(os.path.join(DATA, "scan-meta.json")):
        print("錯誤：找不到 data/scan-meta.json，請先執行 bash .claude/skills/report-gcp/scripts/scan.sh",
              file=sys.stderr)
        return 1

    fw = load("network", "firewall-rules.json") or []
    subnets = load("network", "subnets.json") or []
    routers = load("network", "routers.json") or []
    sqls = load("db", "sql-instances.json") or []
    # VM 優先讀 digest 投影（已保留 tags／accessConfigs／serviceAccounts），沒有才退回原始檔
    vms = load("digest", "compute-instances.json")
    if vms is None:
        raw = load("compute", "instances.json") or []
        vms = [{
            "name": v.get("name"),
            "status": v.get("status"),
            "machineType": last(v.get("machineType")),
            "tags": (v.get("tags") or {}).get("items") or [],
            "serviceAccounts": v.get("serviceAccounts") or [],
            "networkInterfaces": [{
                "network": last(ni.get("network")),
                "subnetwork": last(ni.get("subnetwork")),
                "networkIP": ni.get("networkIP"),
                "accessConfigs": ni.get("accessConfigs") or [],
            } for ni in v.get("networkInterfaces") or []],
        } for v in raw]

    out = [
        "# 網路事實表（跨檔關聯，確定性計算）",
        "",
        "由 `.claude/skills/report-gcp/scripts/network-facts.py` 從 `firewall-rules` / `instances` /",
        "`subnets` / `routers` / `sql-instances` 交叉比對算出，**不是 LLM 的判斷**。",
        "這些關聯要同時看三個以上的檔才看得出來，容易被漏掉，故先算成結論。",
        "",
        "引用時對回 `data/` 下的原始檔（本表只是它們的確定性推導）。",
    ]

    # 無伺服器資源：runs 為 None 代表 digest/run-services.json 不存在（API 未啟用），
    # serverless_paths 會優雅印出說明；connectors 用於反查 connector → 綁定的 VPC。
    # App Engine：ae_services／ae_versions 為 None 代表 digest/appengine-*.json 不存在
    #（未建立 App Engine 應用），同樣優雅印出說明。ingress 在 service 層、VPC 出口在 version 層，故兩份都讀。
    runs = load("digest", "run-services.json")
    connectors = load("network", "vpc-connectors.json") or []
    ae_services = load("digest", "appengine-services.json")
    ae_versions = load("digest", "appengine-versions.json")

    firewall_exposure(out, fw, vms)
    vm_paths(out, vms, subnets, routers)
    sql_reachability(out, sqls)
    serverless_paths(out, runs, connectors, ae_services, ae_versions)

    os.makedirs(DIGEST, exist_ok=True)
    path = os.path.join(DIGEST, "network-facts.md")
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")
    print(f"  network-facts.md  {os.path.getsize(path)} 位元組"
          f"（跨檔關聯：防火牆暴露面／VM 對外路徑／Cloud SQL 可及性）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
