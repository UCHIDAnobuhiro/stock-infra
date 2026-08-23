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

  cors_allowed_origins = ["https://www.example.com"]
  cookie_domain        = "example.com"
  enable_cloud_run     = false
}

run "legacy_keeps_default_vpc" {
  command = plan

  assert {
    condition     = length(google_compute_network.prod) == 0
    error_message = "legacyでは専用VPCを作成しないでください。"
  }

  assert {
    condition     = length(google_redis_instance.dedicated) == 0
    error_message = "legacyでは専用Redisを作成しないでください。"
  }

  assert {
    condition = (
      local.cloud_run_network_name == "default" &&
      local.redis_secret_env.REDIS_HOST == "REDIS_HOST"
    )
    error_message = "legacyではCloud Runのdefault VPCと旧Redis Secret参照を維持してください。"
  }
}

run "prepare_adds_parallel_resources_without_cutover" {
  command = plan

  variables {
    redis_network_migration_phase = "prepare"
  }

  assert {
    condition = (
      length(google_compute_network.prod) == 1 &&
      length(google_compute_subnetwork.cloud_run) == 1 &&
      length(google_redis_instance.dedicated) == 1
    )
    error_message = "prepareでは専用VPC、subnet、Redisを並行作成してください。"
  }

  assert {
    condition = (
      local.cloud_run_network_name == "default" &&
      length(local.cloud_run_network_tags) == 0 &&
      local.redis_secret_env.REDIS_HOST == "REDIS_HOST"
    )
    error_message = "prepareではCloud RunのネットワークとSecret参照を切り替えないでください。"
  }
}

run "cutover_switches_network_and_secrets" {
  command = plan

  variables {
    redis_network_migration_phase = "cutover"
  }

  assert {
    condition = (
      local.cloud_run_network_name == "stock-prod" &&
      local.cloud_run_subnetwork_name == "stock-cloud-run" &&
      length(local.cloud_run_network_tags) == 1 &&
      local.cloud_run_network_tags[0] == "stock-redis-client"
    )
    error_message = "cutoverではCloud Runを専用VPC、subnet、network tagへ切り替えてください。"
  }

  assert {
    condition = (
      local.redis_secret_env.REDIS_HOST == "REDIS_DEDICATED_HOST" &&
      local.redis_secret_env.REDIS_PASSWORD == "REDIS_DEDICATED_PASSWORD" &&
      local.redis_secret_env.REDIS_PORT == "REDIS_DEDICATED_PORT"
    )
    error_message = "cutoverでは専用RedisのSecret参照へ切り替えてください。"
  }
}

run "reject_unknown_migration_phase" {
  command = plan

  variables {
    redis_network_migration_phase = "complete"
  }

  expect_failures = [var.redis_network_migration_phase]
}

run "reject_too_small_cloud_run_subnet" {
  command = plan

  variables {
    cloud_run_subnet_cidr = "10.10.0.0/27"
  }

  expect_failures = [var.cloud_run_subnet_cidr]
}

run "reject_non_canonical_cloud_run_subnet" {
  command = plan

  variables {
    cloud_run_subnet_cidr = "10.10.0.1/26"
  }

  expect_failures = [var.cloud_run_subnet_cidr]
}
