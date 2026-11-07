# アプリ側が TLS 非対応のため transit encryption は無効とし、AUTH を有効化して
# パスワードを Secret Manager 経由で配布する。通信経路は VPC 内に限定する。
# Cloud SQLと同じPrivate Service Accessの予約レンジからIPを割り当てる。
resource "google_redis_instance" "prod" {
  name           = "${var.resource_prefix}-redis"
  tier           = "BASIC"
  memory_size_gb = 1
  region         = var.region
  redis_version  = "REDIS_7_2"

  authorized_network      = google_service_networking_connection.private_service_access.network
  connect_mode            = "PRIVATE_SERVICE_ACCESS"
  auth_enabled            = true
  transit_encryption_mode = "DISABLED"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [
    google_project_service.services["redis.googleapis.com"],
    google_service_networking_connection.private_service_access,
  ]
}
