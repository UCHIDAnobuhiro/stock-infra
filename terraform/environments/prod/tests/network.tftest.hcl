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

run "connects_managed_services_via_private_service_access" {
  command = plan

  assert {
    condition = (
      google_compute_network.prod.name == "stock-prod" &&
      google_compute_subnetwork.cloud_run.name == "stock-cloud-run" &&
      contains(local.services, "servicenetworking.googleapis.com")
    )
    error_message = "本番専用VPCとCloud Run subnetを作成し、servicenetworking APIを管理してください。"
  }

  assert {
    condition = (
      google_compute_global_address.private_service_access.purpose == "VPC_PEERING" &&
      google_compute_global_address.private_service_access.address_type == "INTERNAL" &&
      google_compute_global_address.private_service_access.address == "10.20.0.0" &&
      google_compute_global_address.private_service_access.prefix_length == 20 &&
      google_service_networking_connection.private_service_access.service == "servicenetworking.googleapis.com" &&
      google_service_networking_connection.private_service_access.deletion_policy == "ABANDON"
    )
    error_message = "Cloud SQLとMemorystore用のPrivate Service Accessレンジをpeeringで接続してください。"
  }

  assert {
    condition = (
      !google_sql_database_instance.main.settings[0].ip_configuration[0].ipv4_enabled &&
      google_sql_database_instance.main.settings[0].ip_configuration[0].ssl_mode == "ENCRYPTED_ONLY" &&
      length(google_sql_database_instance.main.settings[0].ip_configuration[0].authorized_networks) == 0
    )
    error_message = "Cloud SQLはpublic IPと承認ネットワークを持たせず、暗号化接続だけを許可してください。"
  }

  assert {
    condition = (
      google_redis_instance.prod.name == "stock-redis" &&
      google_redis_instance.prod.connect_mode == "PRIVATE_SERVICE_ACCESS" &&
      google_redis_instance.prod.auth_enabled
    )
    error_message = "MemorystoreはPrivate Service Access経由で作成し、AUTHを有効化してください。"
  }
}

run "restricts_backend_egress_to_sql_and_redis" {
  command = plan

  assert {
    condition = (
      length(local.cloud_run_network_tags) == 1 &&
      local.cloud_run_network_tags[0] == "stock-backend"
    )
    error_message = "Cloud Runにはbackend workload用network tagを1つだけ設定してください。"
  }

  assert {
    condition = (
      google_compute_firewall.cloud_run_allow_sql_egress.direction == "EGRESS" &&
      toset(one(google_compute_firewall.cloud_run_allow_sql_egress.allow).ports) == toset(["3307"]) &&
      google_compute_firewall.cloud_run_allow_sql_egress.priority < google_compute_firewall.cloud_run_deny_other_egress.priority &&
      google_compute_firewall.cloud_run_allow_redis_egress.priority < google_compute_firewall.cloud_run_deny_other_egress.priority &&
      toset(google_compute_firewall.cloud_run_deny_other_egress.destination_ranges) == toset(["0.0.0.0/0"])
    )
    error_message = "Cloud RunのVPC egressはCloud SQL Connectorの3307とRedisだけを許可し、その他を拒否してください。"
  }

  assert {
    condition = alltrue([
      for env in [local.api_env, local.batch_env, local.migrate_env] :
      env.DB_IP_TYPE == "PRIVATE"
    ])
    error_message = "API・batch・migrateはCloud SQL Connectorでprivate IPへ接続してください。"
  }
}

run "routes_all_cloud_run_workloads_through_vpc" {
  command = plan

  variables {
    enable_cloud_run = true
  }

  assert {
    condition = alltrue([
      for tags in [
        google_cloud_run_v2_service.api[0].template[0].vpc_access[0].network_interfaces[0].tags,
        google_cloud_run_v2_job.batch_single[0].template[0].template[0].vpc_access[0].network_interfaces[0].tags,
        google_cloud_run_v2_job.migrate[0].template[0].template[0].vpc_access[0].network_interfaces[0].tags,
      ] :
      length(tags) == 1 && tolist(tags)[0] == "stock-backend"
    ])
    error_message = "private IPのCloud SQLへ到達するため、API・batch・migrateすべてにDirect VPC egressとtagを設定してください。"
  }

  assert {
    condition = (
      length(google_cloud_run_v2_service.api[0].template[0].volumes) == 0 &&
      length(google_cloud_run_v2_job.batch_single[0].template[0].template[0].volumes) == 0 &&
      length(google_cloud_run_v2_job.migrate[0].template[0].template[0].volumes) == 0
    )
    error_message = "public IP前提の組み込みCloud SQL接続（/cloudsql volume）を使わないでください。"
  }
}

run "uses_plain_redis_secret_names" {
  command = plan

  assert {
    condition = (
      local.redis_secret_env.REDIS_HOST == "REDIS_HOST" &&
      local.redis_secret_env.REDIS_PASSWORD == "REDIS_PASSWORD" &&
      local.redis_secret_env.REDIS_PORT == "REDIS_PORT"
    )
    error_message = "Cloud RunはRedis接続情報をREDIS_* Secretから参照してください。"
  }

  assert {
    condition = alltrue([
      for name in ["REDIS_HOST", "REDIS_PORT", "REDIS_PASSWORD"] :
      contains(keys(local.managed_secrets), name) &&
      contains(local.api_secret_names, name) &&
      contains(local.jobs_secret_names, name) &&
      !contains(local.migrate_secret_names, name)
    ])
    error_message = "Redis SecretのaccessorはAPI・batchだけに付与してください。"
  }
}

run "accept_redis_secret_override" {
  command = plan

  variables {
    managed_secret_version_overrides = {
      REDIS_HOST = "1"
    }
  }
}

run "reject_unknown_secret_override" {
  command = plan

  variables {
    managed_secret_version_overrides = {
      REDIS_DEDICATED_HOST = "1"
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

run "reject_too_small_private_service_access_range" {
  command = plan

  variables {
    private_service_access_cidr = "10.20.0.0/25"
  }

  expect_failures = [var.private_service_access_cidr]
}

run "reject_private_service_access_overlap" {
  command = plan

  variables {
    private_service_access_cidr = "10.10.0.0/20"
  }

  expect_failures = [google_compute_global_address.private_service_access]
}
