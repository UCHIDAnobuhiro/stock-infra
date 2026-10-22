# Cloud Run は Direct VPC egress（network / subnetwork 指定）を使う。
# Serverless VPC Access コネクタは固定費（常時稼働インスタンス）がかかるため使わない。
locals {
  cloud_run_network_tag  = "${var.resource_prefix}-redis-client"
  cloud_sql_network_tag  = "${var.resource_prefix}-sql-client"
  cloud_run_network_tags = var.use_cloud_sql_private_connector ? [local.cloud_run_network_tag, local.cloud_sql_network_tag] : [local.cloud_run_network_tag]
  migrate_network_tags   = [local.cloud_sql_network_tag]

  # IPv4 CIDRの両端を整数にして、/8等の広い既存subnetも含め重複を検出する。
  private_range_bounds = { for name, cidr in { sql = var.cloud_sql_psa_cidr, run = var.cloud_run_subnet_cidr, inspector = var.memorystore_inspector_subnet_cidr } : name => [for endpoint in [cidrhost(cidr, 0), cidrhost(cidr, -1)] : sum([for i, octet in split(".", endpoint) : tonumber(octet) * pow(256, 3 - i)])] }
  sql_range_nonoverlap = alltrue([for name in ["run", "inspector"] : local.private_range_bounds.sql[1] < local.private_range_bounds[name][0] || local.private_range_bounds.sql[0] > local.private_range_bounds[name][1]])
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
# 公式の最小要件である/26を確保し、APIと単一batch Job、private移行時のmigrate Jobで共有する。
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

# Direct VPC egressのnetwork tagを持つCloud Runだけに、新RedisのTCP portを許可する。
# firewall loggingはDirect VPC egressで未サポートのため有効化しない。
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
# PRIVATE_RANGES_ONLYによりVPCを通らないため、Cloud SQL connectorやVertex AIを妨げない。
resource "google_compute_firewall" "cloud_run_deny_other_egress" {
  name               = "${var.resource_prefix}-deny-cloud-run-other-egress"
  network            = google_compute_network.prod.name
  direction          = "EGRESS"
  priority           = 1000
  destination_ranges = ["0.0.0.0/0"]
  target_tags        = var.use_cloud_sql_private_connector ? [local.cloud_run_network_tag, local.cloud_sql_network_tag] : [local.cloud_run_network_tag]

  deny {
    protocol = "all"
  }
}

# PSAはVPC peering用予約範囲。実際のアドレス競合・既存service connectionはplan前に確認する。
resource "google_compute_global_address" "cloud_sql_private" {
  count         = var.enable_cloud_sql_private_ip ? 1 : 0
  name          = "${var.resource_prefix}-cloud-sql-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  address       = split("/", var.cloud_sql_psa_cidr)[0]
  prefix_length = tonumber(split("/", var.cloud_sql_psa_cidr)[1])
  network       = google_compute_network.prod.id
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = local.sql_range_nonoverlap
      error_message = "Cloud SQL PSA範囲がCloud Runまたはinspector subnetと重複しています。"
    }
  }
}

resource "google_service_networking_connection" "cloud_sql_private" {
  count                   = var.enable_cloud_sql_private_ip ? 1 : 0
  network                 = google_compute_network.prod.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.cloud_sql_private[0].name]
  deletion_policy         = "ABANDON"
  lifecycle {
    prevent_destroy = true
  }
  depends_on = [google_project_service.services["servicenetworking.googleapis.com"]]
}

# private connectorのTCP経路のみ。RedisのtagにはSQLを許可しない。
resource "google_compute_firewall" "cloud_run_allow_sql_egress" {
  count              = var.use_cloud_sql_private_connector ? 1 : 0
  name               = "${var.resource_prefix}-allow-cloud-run-sql-egress"
  network            = google_compute_network.prod.name
  direction          = "EGRESS"
  priority           = 900
  destination_ranges = ["${google_sql_database_instance.main.private_ip_address}/32"]
  target_tags        = [local.cloud_sql_network_tag]
  allow {
    protocol = "tcp"
    ports    = ["3307"]
  }
}
