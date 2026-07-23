# 安全性（SEC）官方文件連結

security-auditor 專用。使用規則見 `gcp-docs-common.md`。

## 支柱總論

- [Security, privacy, and compliance pillar](https://docs.cloud.google.com/architecture/framework/security)
- [Enterprise foundations blueprint](https://docs.cloud.google.com/architecture/security-foundations)

## 身分與存取（IAM）

- [Use IAM securely](https://docs.cloud.google.com/iam/docs/using-iam-securely)
- [Best practices for service accounts](https://docs.cloud.google.com/iam/docs/best-practices-service-accounts)
- [Best practices for managing service account keys](https://docs.cloud.google.com/iam/docs/best-practices-for-managing-service-account-keys)
- [Workload Identity Federation](https://docs.cloud.google.com/iam/docs/workload-identity-federation)
- [Service accounts for Compute Engine](https://docs.cloud.google.com/compute/docs/access/service-accounts)
- [Role recommendations](https://docs.cloud.google.com/policy-intelligence/docs/role-recommendations-overview)

## 治理與組織政策

- [Organization policy constraints](https://docs.cloud.google.com/resource-manager/docs/organization-policy/overview)
- [Restrict external IP access](https://docs.cloud.google.com/compute/docs/ip-addresses/reserve-static-external-ip-address)
- [Security Command Center overview](https://docs.cloud.google.com/security-command-center/docs/security-command-center-overview)

## 網路防護

- [VPC firewall rules](https://docs.cloud.google.com/firewall/docs/firewalls)
- [Using IAP for TCP forwarding](https://docs.cloud.google.com/iap/docs/using-tcp-forwarding)
- [VPC Flow Logs](https://docs.cloud.google.com/vpc/docs/flow-logs)
- [Cloud Armor security policy overview](https://docs.cloud.google.com/armor/docs/security-policy-overview)
- [Private Google Access](https://docs.cloud.google.com/vpc/docs/private-google-access)
- [VPC Service Controls overview](https://docs.cloud.google.com/vpc-service-controls/docs/overview)
- [Memorystore for Memcached networking（authorizedNetwork VPC 綁定／private services access，無公開 IP、無 IAM 驗證）](https://docs.cloud.google.com/memorystore/docs/memcached/networking)

## 無伺服器網路安全性（Cloud Run）

- [Restrict network endpoint ingress for Cloud Run services](https://docs.cloud.google.com/run/docs/securing/ingress)
- [Private networking and Cloud Run](https://docs.cloud.google.com/run/docs/securing/private-networking)
- [Connect to a VPC network with Direct VPC egress](https://docs.cloud.google.com/run/docs/configuring/vpc-direct-vpc)
- [Configure Serverless VPC Access](https://docs.cloud.google.com/vpc/docs/serverless-vpc-access)

## App Engine 網路安全性（Ingress 控制與 VPC 連線）

- [Ingress settings（App Engine standard，服務層 ingress 控制）](https://docs.cloud.google.com/appengine/docs/standard/ingress-settings)
- [Ingress settings（App Engine flexible）](https://docs.cloud.google.com/appengine/docs/flexible/ingress-settings)
- [Connecting to a VPC network（App Engine standard，Serverless VPC Access connector）](https://docs.cloud.google.com/appengine/docs/standard/connecting-vpc)
- [REST Resource: apps.services（networkSettings.ingressTrafficAllowed 欄位定義）](https://docs.cloud.google.com/appengine/docs/admin-api/reference/rest/v1/apps.services)

## GKE 網路隔離與私有叢集

- [About network isolation in GKE](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/network-isolation)
- [Customize your network isolation in GKE](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/latest/network-isolation)
- [Best practices for GKE networking](https://docs.cloud.google.com/kubernetes-engine/docs/best-practices/networking)

## 資料保護

- [Uniform bucket-level access](https://docs.cloud.google.com/storage/docs/uniform-bucket-level-access)
- [Public access prevention](https://docs.cloud.google.com/storage/docs/public-access-prevention)
- [Customer-managed encryption keys (CMEK)](https://docs.cloud.google.com/kms/docs/cmek)
- [Key rotation](https://docs.cloud.google.com/kms/docs/key-rotation)
- [Configure SSL/TLS for Cloud SQL](https://docs.cloud.google.com/sql/docs/mysql/configure-ssl-instance)
- [Configure private IP for Cloud SQL](https://docs.cloud.google.com/sql/docs/mysql/configure-private-ip)
- [Authorize with authorized networks](https://docs.cloud.google.com/sql/docs/mysql/authorize-networks)
- [SSL policies for load balancers](https://docs.cloud.google.com/load-balancing/docs/ssl-policies-concepts)
- [Filestore access control（NFS 匯出選項：ipRanges／accessMode／squashMode，控制誰能掛載）](https://docs.cloud.google.com/filestore/docs/access-control)
- [Filestore networking（VPC 綁定／Private Service Access，無公開 IP）](https://docs.cloud.google.com/filestore/docs/networking)
- [Customer-managed encryption keys for Filestore（CMEK）](https://docs.cloud.google.com/filestore/docs/cmek)

## BigQuery 資料存取控制

- [Control access to BigQuery resources with IAM](https://docs.cloud.google.com/bigquery/docs/control-access-to-resources-iam)
- [Customer-managed Cloud KMS keys for BigQuery](https://docs.cloud.google.com/bigquery/docs/customer-managed-encryption)
- [BigQuery locations（資料所在地／資料主權）](https://docs.cloud.google.com/bigquery/docs/locations)

## AlloyDB 網路安全性與加密

- [Connect using public IP（公開 IP 連線；生產環境不建議開放）](https://docs.cloud.google.com/alloydb/docs/connect-public-ip)
- [Connect to a cluster from outside its VPC（授權外部網段 authorized external networks）](https://docs.cloud.google.com/alloydb/docs/connect-external)
- [Private IP overview（Private Services Access／PSC 私有連線）](https://docs.cloud.google.com/alloydb/docs/private-ip)
- [About CMEK for AlloyDB（客戶自管加密金鑰）](https://docs.cloud.google.com/alloydb/docs/cmek)

## Pub/Sub 存取控制與資料保護

- [Access control with IAM for Pub/Sub（誰能 publish／subscribe；避免 allUsers／allAuthenticatedUsers）](https://docs.cloud.google.com/pubsub/docs/access-control)
- [Authentication for push subscriptions（push endpoint 的 OIDC token 驗證）](https://docs.cloud.google.com/pubsub/docs/authenticate-push-subscriptions)
- [Configure message storage policies（訊息落地地區限制／資料主權）](https://docs.cloud.google.com/pubsub/docs/resource-location-restriction)
- [Configure message encryption with CMEK for Pub/Sub（客戶自管加密金鑰）](https://docs.cloud.google.com/pubsub/docs/encryption)

## Dataflow worker 網路安全性與加密

- [Specify a network and subnetwork（worker VM 的 network／subnetwork VPC 歸屬）](https://docs.cloud.google.com/dataflow/docs/guides/specifying-networks)
- [Configure internet access and firewall rules（關閉 worker 公開 IP：--no-use-public-ips／Private Google Access）](https://docs.cloud.google.com/dataflow/docs/guides/routes-firewall)
- [Access control with IAM for Dataflow（誰能提交／管理 job）](https://docs.cloud.google.com/dataflow/docs/concepts/access-control)
- [Use customer-managed encryption keys for Dataflow（CMEK）](https://docs.cloud.google.com/dataflow/docs/guides/customer-managed-encryption-keys)

## 稽核

- [Cloud Audit Logs overview](https://docs.cloud.google.com/logging/docs/audit)
- [Configure Data Access audit logs](https://docs.cloud.google.com/logging/docs/audit/configure-data-access)
