locals {
  memorystore_inspector_network_tag = "${var.resource_prefix}-memorystore-inspector"
  memorystore_inspector_zone = (
    var.memorystore_inspector_zone != "" ?
    var.memorystore_inspector_zone :
    "${var.region}-a"
  )
  ipv4_octet_weights = [16777216, 65536, 256, 1]
  cloud_run_subnet_start = sum([
    for index, octet in split(".", cidrhost(var.cloud_run_subnet_cidr, 0)) :
    tonumber(octet) * local.ipv4_octet_weights[index]
  ])
  cloud_run_subnet_end = sum([
    for index, octet in split(".", cidrhost(var.cloud_run_subnet_cidr, -1)) :
    tonumber(octet) * local.ipv4_octet_weights[index]
  ])
  memorystore_inspector_subnet_start = sum([
    for index, octet in split(".", cidrhost(var.memorystore_inspector_subnet_cidr, 0)) :
    tonumber(octet) * local.ipv4_octet_weights[index]
  ])
  memorystore_inspector_subnet_end = sum([
    for index, octet in split(".", cidrhost(var.memorystore_inspector_subnet_cidr, -1)) :
    tonumber(octet) * local.ipv4_octet_weights[index]
  ])
}

# Cloud Runの/26を消費せず、調査VMのライフサイクルを分離するための最小/29 subnet。
resource "google_compute_subnetwork" "memorystore_inspector" {
  name                     = "${var.resource_prefix}-memorystore-inspector"
  ip_cidr_range            = var.memorystore_inspector_subnet_cidr
  region                   = var.region
  network                  = google_compute_network.prod.id
  private_ip_google_access = false
  stack_type               = "IPV4_ONLY"

  lifecycle {
    precondition {
      condition = !(
        local.memorystore_inspector_subnet_start <= local.cloud_run_subnet_end &&
        local.cloud_run_subnet_start <= local.memorystore_inspector_subnet_end
      )
      error_message = "memorystore_inspector_subnet_cidr はcloud_run_subnet_cidrと重複できません。"
    }
  }
}

# 外部IPを持たないVMへ、IAP TCP forwarding経由のSSHだけを許可する。
resource "google_compute_firewall" "memorystore_inspector_allow_iap_ssh" {
  name          = "${var.resource_prefix}-allow-inspector-iap-ssh"
  network       = google_compute_network.prod.name
  direction     = "INGRESS"
  priority      = 900
  source_ranges = ["35.235.240.0/20"]
  target_tags   = [local.memorystore_inspector_network_tag]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# 調査VMから稼働中MemorystoreのTCP portだけを許可する。
resource "google_compute_firewall" "memorystore_inspector_allow_redis_egress" {
  name               = "${var.resource_prefix}-allow-inspector-redis-egress"
  network            = google_compute_network.prod.name
  direction          = "EGRESS"
  priority           = 900
  destination_ranges = ["${google_redis_instance.prod.host}/32"]
  target_tags        = [local.memorystore_inspector_network_tag]

  allow {
    protocol = "tcp"
    ports    = [tostring(google_redis_instance.prod.port)]
  }
}

# 調査VMからRedis以外への新規egressを拒否する。IAP SSHの戻り通信はstatefulに許可される。
resource "google_compute_firewall" "memorystore_inspector_deny_other_egress" {
  name               = "${var.resource_prefix}-deny-inspector-other-egress"
  network            = google_compute_network.prod.name
  direction          = "EGRESS"
  priority           = 1000
  destination_ranges = ["0.0.0.0/0"]
  target_tags        = [local.memorystore_inspector_network_tag]

  deny {
    protocol = "all"
  }
}

resource "google_compute_instance" "memorystore_inspector" {
  name         = "${var.resource_prefix}-memorystore-inspector"
  machine_type = "e2-micro"
  zone         = local.memorystore_inspector_zone
  tags         = [local.memorystore_inspector_network_tag]

  boot_disk {
    auto_delete = true

    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 10
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.memorystore_inspector.id
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
  }

  # Secretや外部packageをmetadataへ入れず、標準Pythonだけで読み取り操作を提供する。
  metadata_startup_script = templatefile(
    "${path.module}/files/memorystore-inspector-startup.sh.tftpl",
    {
      client_base64 = base64encode(file("${path.module}/files/memorystore-inspect.py"))
      redis_host    = google_redis_instance.prod.host
      redis_port    = tostring(google_redis_instance.prod.port)
    },
  )

  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = true
    enable_vtpm                 = true
  }

  labels = {
    purpose = "memorystore-inspection"
  }

  depends_on = [
    google_project_service.services["iap.googleapis.com"],
    google_compute_firewall.memorystore_inspector_allow_iap_ssh,
    google_compute_firewall.memorystore_inspector_allow_redis_egress,
    google_compute_firewall.memorystore_inspector_deny_other_egress,
  ]
}
