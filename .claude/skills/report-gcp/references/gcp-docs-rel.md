# 可靠性（REL）官方文件連結

reliability-reviewer 專用。使用規則見 `gcp-docs-common.md`。

## 支柱總論

- [Reliability pillar](https://docs.cloud.google.com/architecture/framework/reliability)
- [Disaster recovery planning guide](https://docs.cloud.google.com/architecture/dr-scenarios-planning-guide)

## 資料庫韌性

- [Cloud SQL high availability](https://docs.cloud.google.com/sql/docs/mysql/high-availability)
- [About Cloud SQL backups](https://docs.cloud.google.com/sql/docs/mysql/backup-recovery/backups)
- [Point-in-time recovery](https://docs.cloud.google.com/sql/docs/mysql/backup-recovery/pitr)
- [Cloud SQL maintenance](https://docs.cloud.google.com/sql/docs/mysql/maintenance)
- [Cloud SQL read replicas](https://docs.cloud.google.com/sql/docs/postgres/replication/create-replica)
- [Memorystore for Redis RDB snapshots](https://docs.cloud.google.com/memorystore/docs/redis/rdb-snapshots)
- [Memorystore for Memcached overview（高可用：自動跨可用區分布節點）](https://docs.cloud.google.com/memorystore/docs/memcached/memcached-overview)
- [Memorystore for Memcached best practices（節點數與可用區分布＝容錯）](https://docs.cloud.google.com/memorystore/docs/memcached/best-practices)

## 運算韌性

- [About cluster configuration choices（區域型 vs 單一可用區）](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/types-of-clusters)
- [Set up an application-based health check and autohealing](https://docs.cloud.google.com/compute/docs/instance-groups/autohealing-instances-in-migs)
- [Create a MIG with VMs in multiple zones in a region](https://docs.cloud.google.com/compute/docs/instance-groups/distributing-instances-with-regional-instance-groups)
- [GKE cluster autoscaler](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/cluster-autoscaler)
- [GKE maintenance windows and exclusions](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/maintenance-windows-and-exclusions)
- [Group unmanaged VMs together](https://docs.cloud.google.com/compute/docs/instance-groups/creating-groups-of-unmanaged-instances)
- [About network isolation in GKE（私有叢集與 control plane 端點）](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/network-isolation)

## 無伺服器網路依賴

- [About instance autoscaling in Cloud Run（最小／最大執行個體）](https://docs.cloud.google.com/run/docs/about-instance-autoscaling)
- [Configure Serverless VPC Access（connector 是對外連線的相依點）](https://docs.cloud.google.com/vpc/docs/serverless-vpc-access)
- [Connect to a VPC network with Direct VPC egress](https://docs.cloud.google.com/run/docs/configuring/vpc-direct-vpc)

## 網路韌性

- [HA VPN topologies](https://docs.cloud.google.com/network-connectivity/docs/vpn/concepts/topologies)
- [Cloud NAT overview](https://docs.cloud.google.com/nat/docs/overview)
- [Cloud NAT ports and addresses](https://docs.cloud.google.com/nat/docs/ports-and-addresses)

## 儲存與備份

- [Object Versioning](https://docs.cloud.google.com/storage/docs/object-versioning)
- [Create schedules for disk snapshots](https://docs.cloud.google.com/compute/docs/disks/scheduled-snapshots)
- [Backup and DR Service — Product overview](https://docs.cloud.google.com/backup-disaster-recovery/docs/concepts/backup-dr)
- [Backup for GKE](https://docs.cloud.google.com/kubernetes-engine/docs/add-on/backup-for-gke/concepts/backup-for-gke)
- [Filestore service tiers（BASIC 單一區域 vs ENTERPRISE／REGIONAL 區域級高可用）](https://docs.cloud.google.com/filestore/docs/service-tiers)
- [Filestore backups](https://docs.cloud.google.com/filestore/docs/backups)
- [Configure Filestore instance replication（跨區域災難復原）](https://docs.cloud.google.com/filestore/docs/configure-instance-replication)
- [AlloyDB high availability overview（availabilityType、read pool 冗餘、區域級故障轉移）](https://docs.cloud.google.com/alloydb/docs/high-availability)
- [AlloyDB data backup and recovery overview（automated backup ＋ continuous backup／PITR）](https://docs.cloud.google.com/alloydb/docs/backup/overview)
- [AlloyDB cross-region replication overview（跨區域災難復原）](https://docs.cloud.google.com/alloydb/docs/cross-region-replication/about-cross-region-replication)

## 負載平衡與健康檢查

- [Health check concepts](https://docs.cloud.google.com/load-balancing/docs/health-check-concepts)
- [External Application Load Balancer overview](https://docs.cloud.google.com/load-balancing/docs/https)

## 監控與告警

- [Alerting overview](https://docs.cloud.google.com/monitoring/alerts)
- [Uptime checks](https://docs.cloud.google.com/monitoring/uptime-checks)
- [Notification channels](https://docs.cloud.google.com/monitoring/support/notification-options)
- [Configure log buckets](https://docs.cloud.google.com/logging/docs/buckets)

## SLO 與錯誤預算

- [Concepts in Service Monitoring（SLI／SLO／錯誤預算）](https://docs.cloud.google.com/stackdriver/docs/solutions/slo-monitoring)
