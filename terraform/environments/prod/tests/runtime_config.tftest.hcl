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

  cors_allowed_origins = ["https://www.example.com"]
  cookie_domain        = "example.com"
}

run "direct_cloud_run_trusts_only_last_forwarded_ip" {
  command = plan

  assert {
    condition = (
      local.api_env.TRUSTED_PROXY_HOPS == "1" &&
      google_cloud_run_v2_service.api[0].ingress == "INGRESS_TRAFFIC_ALL"
    )
    error_message = "Cloud Runへ直接到達できる間はXFFの右から2番目を信頼しないでください。"
  }
}

run "domain_transition_keeps_direct_access_safe" {
  command = plan

  variables {
    enable_api_domain = true
    api_domain        = "api.example.com"
  }

  assert {
    condition     = local.api_env.TRUSTED_PROXY_HOPS == "1"
    error_message = "独自ドメインを作成しただけでは信頼するXFFの位置を変更しないでください。"
  }
}

run "restricted_load_balancer_uses_client_ip_not_lb_ip" {
  command = plan

  variables {
    enable_api_domain             = true
    api_domain                    = "api.example.com"
    restrict_api_to_load_balancer = true
  }

  assert {
    condition = (
      local.api_env.TRUSTED_PROXY_HOPS == "2" &&
      google_cloud_run_v2_service.api[0].ingress == "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
    )
    error_message = "LB限定時はXFF末尾のLB IPではなく右から2番目のクライアントIPを使用してください。"
  }
}

run "database_budget_includes_batch_lock_connection" {
  command = plan

  assert {
    condition = (
      local.batch_lock_connections == 1 &&
      local.batch_env.DB_MAX_OPEN_CONNS == "1" &&
      local.batch_env.DB_MAX_IDLE_CONNS == "1" &&
      local.planned_database_connections == 19 &&
      local.database_connection_limit - local.planned_database_connections >= local.database_connection_reserve
    )
    error_message = "batchの処理用1接続とlock専用1接続を含めて、運用用の接続予算を確保してください。"
  }
}

run "reject_database_budget_overflow" {
  command = plan

  variables {
    api_max_instance_count = 4
  }

  expect_failures = [google_sql_database_instance.main]
}
