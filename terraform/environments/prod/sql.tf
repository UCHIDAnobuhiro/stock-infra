# Cloud SQL PostgreSQL 最小構成（コスト優先: 共有コア・zonal・HDD）。
# Cloud Run からは公開IP + 組み込み Cloud SQL 接続（Unix ソケット）でアクセスし、
# 承認ネットワークは追加しない。
resource "google_sql_database_instance" "main" {
  name             = "${var.resource_prefix}-db"
  database_version = "POSTGRES_17"
  region           = var.region

  # terraform destroy からの保護（provider 側フラグ）
  deletion_protection = true

  settings {
    edition           = "ENTERPRISE" # db-f1-micro は ENTERPRISE のみ指定可
    tier              = "db-f1-micro"
    availability_type = "ZONAL"
    disk_type         = "PD_HDD"
    disk_size         = 10
    disk_autoresize   = false # コスト上限を予測可能にする

    # gcloud / コンソールからの削除も防ぐ（GCP 側フラグ）
    deletion_protection_enabled = true

    ip_configuration {
      ipv4_enabled = true
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = false # 小規模構成のコストを優先。要件変更時に再評価する

      backup_retention_settings {
        retained_backups = 7
      }
    }
  }

  depends_on = [google_project_service.services["sqladmin.googleapis.com"]]
}

resource "google_sql_database" "app" {
  name     = var.db_name
  instance = google_sql_database_instance.main.name
}

# DSN で扱いづらい記号を避けるため英数字のみで生成する。
resource "random_password" "db_password" {
  length  = 32
  special = false
}

resource "google_sql_user" "app" {
  name     = var.db_user
  instance = google_sql_database_instance.main.name
  password = random_password.db_password.result
}
