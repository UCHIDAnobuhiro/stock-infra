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
  initial_api_image     = "asia-northeast1-docker.pkg.dev/example-project-123/stock-registry/backend:0123456789abcdef0123456789abcdef01234567"
  initial_batch_image   = "asia-northeast1-docker.pkg.dev/example-project-123/stock-registry/batch:0123456789abcdef0123456789abcdef01234567"
  initial_migrate_image = "asia-northeast1-docker.pkg.dev/example-project-123/stock-registry/migrate:0123456789abcdef0123456789abcdef01234567"
  cors_allowed_origins  = ["https://www.example.com"]
  cookie_domain         = "example.com"
}

run "legacy_default_keeps_socket_and_public_ip" {
  command = plan
  assert {
    condition     = google_sql_database_instance.main.settings[0].ip_configuration[0].ipv4_enabled && google_sql_database_instance.main.settings[0].ip_configuration[0].private_network == null && !contains(keys(local.common_env), "DB_CONNECTION_MODE") && length(google_compute_global_address.cloud_sql_private) == 0 && length(google_compute_firewall.cloud_run_allow_sql_egress) == 0
    error_message = "既定設定は現行の公開IP/Unix socket経路を維持してください。"
  }
}

run "private_ip_added_before_runtime_switch" {
  command = plan
  variables { enable_cloud_sql_private_ip = true }
  assert {
    condition     = google_sql_database_instance.main.settings[0].ip_configuration[0].ipv4_enabled && length(google_service_networking_connection.cloud_sql_private) == 1 && !contains(keys(local.common_env), "DB_CONNECTION_MODE")
    error_message = "private IP追加段階で公開IPとsocket経路を維持してください。"
  }
}

run "private_runtime_has_sql_only_firewall_and_migrate_vpc" {
  command = plan
  variables {
    enable_cloud_sql_private_ip     = true
    use_cloud_sql_private_connector = true
  }
  assert {
    condition     = local.common_env.DB_CONNECTION_MODE == "private" && google_sql_database_instance.main.settings[0].ip_configuration[0].ipv4_enabled && length(google_compute_firewall.cloud_run_allow_sql_egress) == 1 && length(google_compute_firewall.cloud_run_allow_sql_egress[0].allow) == 1 && one([for rule in google_compute_firewall.cloud_run_allow_sql_egress[0].allow : rule.protocol]) == "tcp" && toset(one([for rule in google_compute_firewall.cloud_run_allow_sql_egress[0].allow : rule.ports])) == toset(["3307"]) && toset(google_compute_firewall.cloud_run_allow_sql_egress[0].target_tags) == toset([local.cloud_sql_network_tag]) && contains(google_compute_firewall.cloud_run_deny_other_egress.target_tags, local.cloud_sql_network_tag) && length(local.migrate_network_tags) == 1 && local.migrate_network_tags[0] == local.cloud_sql_network_tag && length(google_cloud_run_v2_job.migrate[0].template[0].template[0].vpc_access) == 1 && !contains(local.migrate_network_tags, local.cloud_run_network_tag) && local.api_env.DB_CONNECTION_MODE == "private" && local.batch_env.DB_CONNECTION_MODE == "private" && local.migrate_env.DB_CONNECTION_MODE == "private"
    error_message = "private接続はTCP3307のSQL専用tagを使い、migrateにもVPCを設定してください。"
  }
}

run "private_only_disables_public" {
  command = plan
  variables {
    enable_cloud_sql_private_ip     = true
    use_cloud_sql_private_connector = true
    disable_cloud_sql_public_ip     = true
  }
  assert {
    condition     = !google_sql_database_instance.main.settings[0].ip_configuration[0].ipv4_enabled
    error_message = "最終段階で公開IPを無効にしてください。"
  }
}

run "reject_public_disable_without_private" {
  command = plan
  variables { disable_cloud_sql_public_ip = true }
  expect_failures = [var.disable_cloud_sql_public_ip]
}

run "reject_private_mode_without_private_ip" {
  command = plan
  variables { use_cloud_sql_private_connector = true }
  expect_failures = [var.use_cloud_sql_private_connector]
}

run "reject_overlapping_psa" {
  command = plan
  variables {
    enable_cloud_sql_private_ip = true
    cloud_sql_psa_cidr          = "10.10.0.0/16"
  }
  expect_failures = [google_compute_global_address.cloud_sql_private]
}

run "reject_public_disable_without_runtime_switch" {
  command = plan
  variables {
    enable_cloud_sql_private_ip = true
    disable_cloud_sql_public_ip = true
  }
  expect_failures = [var.disable_cloud_sql_public_ip]
}
