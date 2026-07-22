# 成本最佳化（COST）官方文件連結

cost-optimizer 專用。使用規則見 `gcp-docs-common.md`。

⚠️ **本檔只放技術文件連結（給發現附引用用），不再是查即時單價的地方**。
金額估算需要當下單價時，改用 `bash .claude/skills/report-gcp/scripts/pricing-lookup.sh`
直查 Cloud Billing Catalog API（回美金牌價，不做幣別轉換，同一次報告執行內快取、跨期不沿用）。
下面「定價頁」段落的連結僅供人工對照／報告引用，cost-optimizer 不再 WebFetch 它們取數字。

## 支柱總論

- [Cost optimization pillar](https://docs.cloud.google.com/architecture/framework/cost-optimization)

## 成本可見度與治理

- [Create, edit, or delete budgets and budget alerts](https://docs.cloud.google.com/billing/docs/how-to/budgets)
- [Export Cloud Billing data to BigQuery](https://docs.cloud.google.com/billing/docs/how-to/export-data-bigquery)
- [Cloud Billing reports](https://docs.cloud.google.com/billing/docs/how-to/reports)
- [Create and update labels for projects](https://docs.cloud.google.com/resource-manager/docs/creating-managing-labels)

## Recommender（閒置與規格建議）

- [Recommenders overview](https://docs.cloud.google.com/recommender/docs/recommenders)
- [Recommenders（含閒置資源建議）](https://docs.cloud.google.com/recommender/docs/recommenders)
- [Apply machine type recommendations](https://docs.cloud.google.com/compute/docs/instances/apply-machine-type-recommendations-for-instances)

## 折扣方案

- [Committed use discounts for Compute Engine](https://docs.cloud.google.com/compute/docs/instances/committed-use-discounts-overview)
- [Sustained use discounts](https://docs.cloud.google.com/compute/docs/sustained-use-discounts)
- [Spot VMs](https://docs.cloud.google.com/compute/docs/instances/spot)

## 資源層節省

- [Object Lifecycle Management](https://docs.cloud.google.com/storage/docs/lifecycle)
- [Storage classes](https://docs.cloud.google.com/storage/docs/storage-classes)
- [Autoclass](https://docs.cloud.google.com/storage/docs/autoclass)
- [Persistent disk snapshots](https://docs.cloud.google.com/compute/docs/disks/snapshots)
- [Reserve a static external IP address](https://docs.cloud.google.com/compute/docs/ip-addresses/reserve-static-external-ip-address)
- [Logging pricing and retention](https://docs.cloud.google.com/stackdriver/pricing)

## 定價頁（僅供人工對照／報告引用，即時單價改用 pricing-lookup.sh）

- [Compute Engine pricing](https://docs.cloud.google.com/compute/all-pricing)
- [Cloud Storage pricing](https://docs.cloud.google.com/storage/pricing)
- [Cloud SQL pricing](https://docs.cloud.google.com/sql/pricing)
- [Networking pricing](https://docs.cloud.google.com/vpc/network-pricing)
