# Cloud Run は Direct VPC egress（network / subnetwork 指定）を使う。
# Serverless VPC Access コネクタは固定費（常時稼働インスタンス）がかかるため使わない。
locals {
  cloud_run_network_tag  = "${var.resource_prefix}-redis-client"
  cloud_run_network_tags = [local.cloud_run_network_tag]
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
# 公式の最小要件である/26を確保し、APIと単一batch Jobで共有する。
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
  target_tags        = [local.cloud_run_network_tag]

  deny {
    protocol = "all"
  }
}
