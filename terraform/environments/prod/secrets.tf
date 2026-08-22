# Secret Manager の値は3分類で管理する。
#   A. Terraform が生成し version まで管理（JWT_SECRET / PASSWORD_PEPPER / DB_PASSWORD）
#   B. Terraform がリソース属性から導出し version まで管理（接続情報など）
#   C. secret 本体のみ Terraform 管理し、外部credentialの値は手動投入
#
# A/B の値は tfstate に平文で保存されるため、state バケットを非公開・
# バージョニング有効・公開アクセス禁止で運用する。

# --- A. 生成シークレット（アプリ要件: 32バイト以上） ---
resource "random_password" "jwt_secret" {
  length  = 48
  special = false
}

resource "random_password" "password_pepper" {
  length  = 48
  special = false
}

# --- A + B: version まで Terraform 管理するシークレット ---
locals {
  managed_secrets = {
    JWT_SECRET               = random_password.jwt_secret.result
    PASSWORD_PEPPER          = random_password.password_pepper.result
    DB_PASSWORD              = random_password.db_password.result
    DB_USER                  = var.db_user
    DB_NAME                  = var.db_name
    INSTANCE_CONNECTION_NAME = google_sql_database_instance.main.connection_name
    REDIS_HOST               = google_redis_instance.main.host
    REDIS_PORT               = tostring(google_redis_instance.main.port)
    REDIS_PASSWORD           = google_redis_instance.main.auth_string
    TWELVE_DATA_BASE_URL     = var.twelve_data_base_url
  }
}

resource "google_secret_manager_secret" "managed" {
  for_each = local.managed_secrets

  secret_id = each.key

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.services["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_version" "managed" {
  for_each = local.managed_secrets

  secret          = google_secret_manager_secret.managed[each.key].id
  secret_data     = each.value
  deletion_policy = "ABANDON"

  # ローテーション時は新versionを先に作り、rollback用の旧versionをSecret Managerに残す。
  lifecycle {
    create_before_destroy = true
  }
}

locals {
  # Cloud Runでlatestを参照せず、このresourceが管理する数値versionへ固定する。
  managed_secret_versions = {
    for key, secret_version in google_secret_manager_secret_version.managed :
    key => secret_version.version
  }
}

# --- C. 値は人間が gcloud で投入する。version がない間はデプロイしない。 ---
resource "google_secret_manager_secret" "twelve_data_api_key" {
  secret_id = "TWELVE_DATA_API_KEY"

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.services["secretmanager.googleapis.com"]]
}

locals {
  oauth_secret_names = toset([
    "GOOGLE_CLIENT_ID",
    "GOOGLE_CLIENT_SECRET",
    "GITHUB_CLIENT_ID",
    "GITHUB_CLIENT_SECRET",
  ])
}

resource "google_secret_manager_secret" "oauth" {
  for_each = local.oauth_secret_names

  secret_id = each.key

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.services["secretmanager.googleapis.com"]]
}

locals {
  # 分類Cは値をTerraformへ渡さず、人間が投入したversion番号だけをローカル設定で管理する。
  # managed_secret_version_overridesは依存リソースを旧値へ戻す緊急rollback時だけ使用する。
  all_secret_versions = merge(
    local.managed_secret_versions,
    var.manual_secret_versions,
    var.managed_secret_version_overrides,
  )
}
