# Memorystore for Redis の最小構成。
# アプリ側が TLS 非対応のため transit encryption は無効とし、AUTH を有効化して
# パスワードを Secret Manager 経由で配布する。通信経路は VPC 内に限定する。
resource "google_redis_instance" "main" {
  name           = "${var.resource_prefix}-redis"
  tier           = "BASIC"
  memory_size_gb = 1
  region         = var.region
  redis_version  = "REDIS_7_2"

  authorized_network      = local.default_network_id
  connect_mode            = "DIRECT_PEERING"
  auth_enabled            = true
  transit_encryption_mode = "DISABLED"

  depends_on = [
    google_project_service.services["compute.googleapis.com"],
    google_project_service.services["redis.googleapis.com"],
  ]
}
