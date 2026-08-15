locals {
  common_env = {
    APP_ENV    = "production"
    LOG_FORMAT = "json"
  }

  database_secret_env = {
    DB_NAME                  = "DB_NAME"
    DB_PASSWORD              = "DB_PASSWORD"
    DB_USER                  = "DB_USER"
    INSTANCE_CONNECTION_NAME = "INSTANCE_CONNECTION_NAME"
  }

  redis_secret_env = {
    REDIS_HOST     = "REDIS_HOST"
    REDIS_PASSWORD = "REDIS_PASSWORD"
    REDIS_PORT     = "REDIS_PORT"
  }

  api_env = merge(local.common_env, {
    CANDLES_CACHE_TTL         = "24h"
    COOKIE_SECURE             = "true"
    CORS_ALLOWED_ORIGINS      = join(",", var.cors_allowed_origins)
    DB_CONN_MAX_LIFETIME      = "5m"
    DB_MAX_IDLE_CONNS         = "25"
    DB_MAX_OPEN_CONNS         = "25"
    GOOGLE_CLOUD_LOCATION     = var.region
    GOOGLE_CLOUD_PROJECT      = var.project_id
    GOOGLE_GENAI_USE_VERTEXAI = "true"
    TRUSTED_PROXY_HOPS        = "1"
  })

  api_secret_env = merge(
    local.database_secret_env,
    local.redis_secret_env,
    {
      JWT_SECRET      = "JWT_SECRET"
      PASSWORD_PEPPER = "PASSWORD_PEPPER"
    },
  )

  batch_env = merge(local.common_env, {
    CANDLES_CACHE_TTL            = "24h"
    INGEST_MAX_FAILURE_RATE      = "0.2"
    INGEST_TIMEOUT_HOURS         = "3"
    LOGO_INGEST_MAX_FAILURE_RATE = "0.2"
    LOGO_INGEST_TIMEOUT_HOURS    = "3"
  })

  batch_secret_env = merge(
    local.database_secret_env,
    local.redis_secret_env,
    {
      TWELVE_DATA_API_KEY  = "TWELVE_DATA_API_KEY"
      TWELVE_DATA_BASE_URL = "TWELVE_DATA_BASE_URL"
    },
  )

}

resource "google_cloud_run_v2_service" "api" {
  count = var.enable_cloud_run ? 1 : 0

  name                = "backend"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = true

  template {
    service_account = google_service_account.service_runner.email
    timeout         = "300s"

    scaling {
      min_instance_count = 0
      max_instance_count = var.api_max_instance_count
    }

    containers {
      name  = "backend"
      image = var.initial_api_image

      ports {
        name           = "http1"
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      startup_probe {
        failure_threshold     = 6
        initial_delay_seconds = 0
        period_seconds        = 10
        timeout_seconds       = 5

        http_get {
          path = "/healthz"
          port = 8080
        }
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      dynamic "env" {
        for_each = local.api_env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.api_secret_env
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = local.all_secret_ids[env.value]
              version = "latest"
            }
          }
        }
      }
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.main.connection_name]
      }
    }

    vpc_access {
      egress = "PRIVATE_RANGES_ONLY"
      network_interfaces {
        network    = data.google_compute_network.default.name
        subnetwork = data.google_compute_subnetwork.default.name
      }
    }
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      template[0].containers[0].image,
      traffic,
    ]
  }

  depends_on = [
    google_project_service.services["run.googleapis.com"],
    google_secret_manager_secret_iam_member.api_accessor,
    google_secret_manager_secret_version.managed,
  ]
}

resource "google_cloud_run_v2_service_iam_member" "public" {
  count = var.enable_cloud_run ? 1 : 0

  project  = google_cloud_run_v2_service.api[0].project
  location = google_cloud_run_v2_service.api[0].location
  name     = google_cloud_run_v2_service.api[0].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service_iam_member" "deployer" {
  count = var.enable_cloud_run ? 1 : 0

  project  = google_cloud_run_v2_service.api[0].project
  location = google_cloud_run_v2_service.api[0].location
  name     = google_cloud_run_v2_service.api[0].name
  role     = "roles/run.developer"
  member   = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_cloud_run_v2_job" "batch_single" {
  count = var.enable_cloud_run ? 1 : 0

  name                = "batch"
  location            = var.region
  deletion_protection = true

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account = google_service_account.jobs_runner.email
      timeout         = "10800s"
      max_retries     = 1

      containers {
        name  = "batch"
        image = var.initial_batch_image
        args  = ["candles"]

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }

        volume_mounts {
          name       = "cloudsql"
          mount_path = "/cloudsql"
        }

        dynamic "env" {
          for_each = local.batch_env
          content {
            name  = env.key
            value = env.value
          }
        }

        dynamic "env" {
          for_each = local.batch_secret_env
          content {
            name = env.key
            value_source {
              secret_key_ref {
                secret  = local.all_secret_ids[env.value]
                version = "latest"
              }
            }
          }
        }
      }

      volumes {
        name = "cloudsql"
        cloud_sql_instance {
          instances = [google_sql_database_instance.main.connection_name]
        }
      }

      # candles実行時にMemorystoreへ到達するため、単一Jobには常にDirect VPC egressを設定する。
      vpc_access {
        egress = "PRIVATE_RANGES_ONLY"
        network_interfaces {
          network    = data.google_compute_network.default.name
          subnetwork = data.google_compute_subnetwork.default.name
        }
      }
    }
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      template[0].template[0].containers[0].image,
    ]
  }

  depends_on = [
    google_project_service.services["run.googleapis.com"],
    google_secret_manager_secret_iam_member.jobs_accessor,
    google_secret_manager_secret_version.managed,
  ]
}

resource "google_cloud_run_v2_job_iam_member" "batch_single_deployer" {
  count = var.enable_cloud_run ? 1 : 0

  project  = google_cloud_run_v2_job.batch_single[0].project
  location = google_cloud_run_v2_job.batch_single[0].location
  name     = google_cloud_run_v2_job.batch_single[0].name
  role     = "roles/run.developer"
  member   = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_cloud_run_v2_job" "migrate" {
  count = var.enable_cloud_run ? 1 : 0

  name                = "migrate"
  location            = var.region
  deletion_protection = true

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account = google_service_account.migrate_runner.email
      timeout         = "900s"
      max_retries     = 0

      containers {
        name  = "migrate"
        image = var.initial_migrate_image
        args  = ["up"]

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }

        volume_mounts {
          name       = "cloudsql"
          mount_path = "/cloudsql"
        }

        dynamic "env" {
          for_each = local.common_env
          content {
            name  = env.key
            value = env.value
          }
        }

        dynamic "env" {
          for_each = local.database_secret_env
          content {
            name = env.key
            value_source {
              secret_key_ref {
                secret  = local.all_secret_ids[env.value]
                version = "latest"
              }
            }
          }
        }
      }

      volumes {
        name = "cloudsql"
        cloud_sql_instance {
          instances = [google_sql_database_instance.main.connection_name]
        }
      }
    }
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      template[0].template[0].containers[0].image,
    ]
  }

  depends_on = [
    google_project_service.services["run.googleapis.com"],
    google_secret_manager_secret_iam_member.migrate_accessor,
    google_secret_manager_secret_version.managed,
  ]
}

resource "google_cloud_run_v2_job_iam_member" "migrate_deployer" {
  count = var.enable_cloud_run ? 1 : 0

  project  = google_cloud_run_v2_job.migrate[0].project
  location = google_cloud_run_v2_job.migrate[0].location
  name     = google_cloud_run_v2_job.migrate[0].name
  role     = "roles/run.developer"
  member   = "serviceAccount:${google_service_account.deployer.email}"
}
