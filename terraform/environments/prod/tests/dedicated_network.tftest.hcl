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

run "keeps_dedicated_network_as_steady_state" {
  command = plan

  assert {
    condition = (
      google_compute_network.prod.name == "stock-prod" &&
      google_compute_subnetwork.cloud_run.name == "stock-cloud-run" &&
      google_redis_instance.prod.name == "stock-redis-v2"
    )
    error_message = "本番専用VPC、Cloud Run subnet、専用Redisを定常リソースとして維持してください。"
  }

  assert {
    condition = (
      length(local.cloud_run_network_tags) == 1 &&
      local.cloud_run_network_tags[0] == "stock-redis-client"
    )
    error_message = "Cloud Runには専用Redis向けnetwork tagを常に設定してください。"
  }

  assert {
    condition = (
      local.redis_secret_env.REDIS_HOST == "REDIS_DEDICATED_HOST" &&
      local.redis_secret_env.REDIS_PASSWORD == "REDIS_DEDICATED_PASSWORD" &&
      local.redis_secret_env.REDIS_PORT == "REDIS_DEDICATED_PORT"
    )
    error_message = "Cloud Runは専用RedisのSecretだけを参照してください。"
  }
}

run "retires_only_legacy_redis_secrets" {
  command = plan

  assert {
    condition = (
      length(local.retired_redis_managed_secrets) == 0 &&
      alltrue([
        for name in ["REDIS_HOST", "REDIS_PORT", "REDIS_PASSWORD"] :
        !contains(keys(local.managed_secrets), name)
      ])
    )
    error_message = "旧REDIS_*はmanaged Secretから除外し、削除専用resourceでだけ廃止してください。"
  }

  assert {
    condition = alltrue([
      for name in ["REDIS_DEDICATED_HOST", "REDIS_DEDICATED_PORT", "REDIS_DEDICATED_PASSWORD"] :
      contains(keys(local.managed_secrets), name) &&
      contains(local.api_secret_names, name) &&
      contains(local.jobs_secret_names, name)
    ])
    error_message = "専用Redis SecretとAPI・batchのaccessor権限を維持してください。"
  }
}

run "accept_dedicated_redis_secret_override" {
  command = plan

  variables {
    managed_secret_version_overrides = {
      REDIS_DEDICATED_HOST = "1"
    }
  }
}

run "reject_retired_redis_secret_override" {
  command = plan

  variables {
    managed_secret_version_overrides = {
      REDIS_HOST = "1"
    }
  }

  expect_failures = [var.managed_secret_version_overrides]
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
