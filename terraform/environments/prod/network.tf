# Cloud Run は Direct VPC egress（network / subnetwork 指定）を使う。
# Serverless VPC Access コネクタは固定費（常時稼働インスタンス）がかかるため使わない。
locals {
  # VPC内の宛先（Cloud SQL / Memorystore）へのegressを制御するbackend workload用tag。
  # 宛先ごとのallowとそれ以外のdenyは、このtagを持つCloud Run Service / Jobだけに適用する。
  cloud_run_network_tag  = "${var.resource_prefix}-backend"
  cloud_run_network_tags = [local.cloud_run_network_tag]

  # Cloud SQL Language Connector / Auth Proxyは、IP種別によらずサーバー側の3307へ接続する。
  cloud_sql_connector_port = 3307
}

resource "google_compute_network" "prod" {
  name                            = "${var.resource_prefix}-prod"
  auto_create_subnetworks         = false
  delete_default_routes_on_create = true
  routing_mode                    = "REGIONAL"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.services["compute.googleapis.com"]]
}

# Cloud RunはRevision更新時に旧RevisionのIPを一時保持し、Jobも実行後にIPを保持する。
# 公式の最小要件である/26を確保し、APIとbatch・migrate Jobで共有する。
resource "google_compute_subnetwork" "cloud_run" {
  name                     = "${var.resource_prefix}-cloud-run"
  ip_cidr_range            = var.cloud_run_subnet_cidr
  region                   = var.region
  network                  = google_compute_network.prod.id
  private_ip_google_access = false
  stack_type               = "IPV4_ONLY"

  lifecycle {
    prevent_destroy = true
  }
}

# --- Private Service Access ---
# Cloud SQLとMemorystoreをpublic IPなしでVPCへ接続するため、Google管理サービス用の
# レンジを予約してservicenetworkingとpeeringする。両サービスでこの1レンジを共用する。
resource "google_compute_global_address" "private_service_access" {
  name          = "${var.resource_prefix}-private-service-access"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  address       = cidrhost(var.private_service_access_cidr, 0)
  prefix_length = tonumber(split("/", var.private_service_access_cidr)[1])
  network       = google_compute_network.prod.id

  lifecycle {
    prevent_destroy = true

    precondition {
      condition = !(
        local.private_service_access_start <= local.cloud_run_subnet_end &&
        local.cloud_run_subnet_start <= local.private_service_access_end
        ) && !(
        local.private_service_access_start <= local.memorystore_inspector_subnet_end &&
        local.memorystore_inspector_subnet_start <= local.private_service_access_end
      )
      error_message = "private_service_access_cidr はCloud Run subnet・調査VM subnetと重複できません。"
    }
  }

  depends_on = [google_project_service.services["compute.googleapis.com"]]
}

# Cloud SQLが残っている間はpeeringを削除できず、destroy時にapplyが失敗するためABANDONとする。
resource "google_service_networking_connection" "private_service_access" {
  network                 = google_compute_network.prod.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_service_access.name]
  deletion_policy         = "ABANDON"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.services["servicenetworking.googleapis.com"]]
}

# --- Cloud Run egress ---
# 宛先はPSAレンジ全体ではなく各インスタンスのprivate IP /32とportに限定する。
# firewall loggingはDirect VPC egressで未サポートのため有効化しない。
resource "google_compute_firewall" "cloud_run_allow_sql_egress" {
  name               = "${var.resource_prefix}-allow-cloud-run-sql-egress"
  network            = google_compute_network.prod.name
  direction          = "EGRESS"
  priority           = 900
  destination_ranges = ["${google_sql_database_instance.main.private_ip_address}/32"]
  target_tags        = [local.cloud_run_network_tag]

  allow {
    protocol = "tcp"
    ports    = [tostring(local.cloud_sql_connector_port)]
  }
}

resource "google_compute_firewall" "cloud_run_allow_redis_egress" {
  name               = "${var.resource_prefix}-allow-cloud-run-redis-egress"
  network            = google_compute_network.prod.name
  direction          = "EGRESS"
  priority           = 900
  destination_ranges = ["${google_redis_instance.prod.host}/32"]
  target_tags        = [local.cloud_run_network_tag]

  allow {
    protocol = "tcp"
    ports    = [tostring(google_redis_instance.prod.port)]
  }
}

# VPCへルーティングされる他の宛先は暗黙allowに任せず拒否する。public APIへの通信は
# PRIVATE_RANGES_ONLYによりVPCを通らないため、Cloud SQL ConnectorのAdmin API呼び出しや
# Vertex AIを妨げない。
resource "google_compute_firewall" "cloud_run_deny_other_egress" {
  name               = "${var.resource_prefix}-deny-cloud-run-other-egress"
  network            = google_compute_network.prod.name
  direction          = "EGRESS"
  priority           = 1000
  destination_ranges = ["0.0.0.0/0"]
  target_tags        = [local.cloud_run_network_tag]

  deny {
    protocol = "all"
  }
}
