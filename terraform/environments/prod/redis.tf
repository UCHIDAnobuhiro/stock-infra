# default VPC上の既存Memorystore。専用VPCへの切り替え後もrollback期間中は維持し、
# 削除は疎通・監視・rollback期間を完了した後の別変更として人間が判断する。
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

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [
    google_project_service.services["compute.googleapis.com"],
    google_project_service.services["redis.googleapis.com"],
  ]
}

# prepareで旧Redisと並行作成し、cutoverまではCloud Runから参照しない。
# 新規リソースなのでauthorized_networkがapply時まで未知でも既存Redisの再作成にはならない。
resource "google_redis_instance" "dedicated" {
  count = local.dedicated_network_enabled ? 1 : 0

  name           = "${var.resource_prefix}-redis-v2"
  tier           = "BASIC"
  memory_size_gb = 1
  region         = var.region
  redis_version  = "REDIS_7_2"

  authorized_network      = google_compute_network.prod[0].id
  connect_mode            = "DIRECT_PEERING"
  auth_enabled            = true
  transit_encryption_mode = "DISABLED"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [
    google_project_service.services["compute.googleapis.com"],
    google_project_service.services["redis.googleapis.com"],
  ]
}
