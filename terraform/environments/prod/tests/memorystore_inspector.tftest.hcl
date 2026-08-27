mock_provider "google" {}

mock_provider "random" {}

variables {
  project_id        = "example-project-123"
  region            = "asia-northeast1"
  resource_prefix   = "stock"
  github_repository = "example/backend"

  manual_secret_versions = {
    TWELVE_DATA_API_KEY  = "1"
    GOOGLE_CLIENT_ID     = "1"
    GOOGLE_CLIENT_SECRET = "1"
    GITHUB_CLIENT_ID     = "1"
    GITHUB_CLIENT_SECRET = "1"
  }

  initial_api_image     = "asia-northeast1-docker.pkg.dev/example-project-123/stock-registry/backend:${join("", ["0123456789abcdef", "0123456789abcdef", "01234567"])}"
  initial_batch_image   = "asia-northeast1-docker.pkg.dev/example-project-123/stock-registry/batch:${join("", ["0123456789abcdef", "0123456789abcdef", "01234567"])}"
  initial_migrate_image = "asia-northeast1-docker.pkg.dev/example-project-123/stock-registry/migrate:${join("", ["0123456789abcdef", "0123456789abcdef", "01234567"])}"

  cors_allowed_origins          = ["https://www.example.com"]
  cookie_domain                 = "example.com"
  enable_cloud_run              = false
  enable_api_domain             = false
  enable_oauth                  = false
  restrict_api_to_load_balancer = false
}

run "creates_private_minimum_inspector_vm" {
  command = plan

  assert {
    condition = (
      google_compute_subnetwork.memorystore_inspector.ip_cidr_range == "10.10.1.0/29" &&
      !google_compute_subnetwork.memorystore_inspector.private_ip_google_access
    )
    error_message = "調査VMは本番専用VPC内の専用/29 subnetへ配置してください。"
  }

  assert {
    condition = (
      google_compute_instance.memorystore_inspector.machine_type == "e2-micro" &&
      google_compute_instance.memorystore_inspector.zone == "asia-northeast1-a" &&
      length(google_compute_instance.memorystore_inspector.network_interface[0].access_config) == 0 &&
      length(google_compute_instance.memorystore_inspector.service_account) == 0
    )
    error_message = "調査VMはe2-micro、外部IPなし、サービスアカウントなしで専用subnetへ配置してください。"
  }

  assert {
    condition = (
      contains(local.services, "iap.googleapis.com") &&
      google_compute_instance.memorystore_inspector.metadata["enable-oslogin"] == "TRUE" &&
      google_compute_instance.memorystore_inspector.metadata["block-project-ssh-keys"] == "TRUE" &&
      google_compute_instance.memorystore_inspector.shielded_instance_config[0].enable_secure_boot
    )
    error_message = "IAP APIを管理し、調査VMはOS LoginとShielded VMを有効化してください。"
  }
}

run "restricts_inspector_network_access" {
  command = plan

  assert {
    condition = (
      google_compute_firewall.memorystore_inspector_allow_iap_ssh.direction == "INGRESS" &&
      toset(google_compute_firewall.memorystore_inspector_allow_iap_ssh.source_ranges) == toset(["35.235.240.0/20"]) &&
      toset(one(google_compute_firewall.memorystore_inspector_allow_iap_ssh.allow).ports) == toset(["22"])
    )
    error_message = "調査VMへのSSHはIAP TCP forwardingだけから許可してください。"
  }

  assert {
    condition = (
      google_compute_firewall.memorystore_inspector_allow_redis_egress.direction == "EGRESS" &&
      google_compute_firewall.memorystore_inspector_allow_redis_egress.priority < google_compute_firewall.memorystore_inspector_deny_other_egress.priority &&
      toset(google_compute_firewall.memorystore_inspector_deny_other_egress.destination_ranges) == toset(["0.0.0.0/0"])
    )
    error_message = "調査VMのegressはMemorystoreだけを許可し、その他を拒否してください。"
  }
}

run "accepts_zone_override_in_region" {
  command = plan

  variables {
    memorystore_inspector_zone = "asia-northeast1-b"
  }

  assert {
    condition     = google_compute_instance.memorystore_inspector.zone == "asia-northeast1-b"
    error_message = "region内の調査VM zone overrideを反映してください。"
  }
}

run "rejects_inspector_subnet_overlap" {
  command = plan

  variables {
    memorystore_inspector_subnet_cidr = "10.10.0.0/29"
  }

  expect_failures = [google_compute_subnetwork.memorystore_inspector]
}

run "rejects_non_minimum_inspector_subnet" {
  command = plan

  variables {
    memorystore_inspector_subnet_cidr = "10.10.1.0/28"
  }

  expect_failures = [var.memorystore_inspector_subnet_cidr]
}

run "rejects_inspector_zone_outside_region" {
  command = plan

  variables {
    memorystore_inspector_zone = "us-central1-a"
  }

  expect_failures = [var.memorystore_inspector_zone]
}
