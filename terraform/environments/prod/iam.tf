# --- サービスアカウント ---
resource "google_service_account" "service_runner" {
  account_id   = "${var.resource_prefix}-api"
  display_name = "Cloud Run API runtime"
}

resource "google_service_account" "jobs_runner" {
  account_id   = "${var.resource_prefix}-jobs"
  display_name = "Cloud Run Jobs runtime"
}

resource "google_service_account" "deployer" {
  account_id   = "${var.resource_prefix}-deployer"
  display_name = "GitHub Actions deployer (WIF)"
}

# --- ランタイム SA のプロジェクトレベルロール ---
resource "google_project_iam_member" "service_runner_cloudsql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.service_runner.email}"
}

# API は起動時に Vertex AI (Gemini) クライアントを初期化する。
resource "google_project_iam_member" "service_runner_aiplatform" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.service_runner.email}"
}

resource "google_project_iam_member" "jobs_runner_cloudsql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.jobs_runner.email}"
}

# --- シークレット単位の accessor（最小権限） ---
locals {
  all_secret_ids = merge(
    { for key, secret in google_secret_manager_secret.managed : key => secret.secret_id },
    { TWELVE_DATA_API_KEY = google_secret_manager_secret.twelve_data_api_key.secret_id },
  )

  # API は全シークレットを参照する。
  api_secret_names = keys(local.all_secret_ids)

  # バッチは認証系シークレットを使わない。
  jobs_secret_names = [
    for name in keys(local.all_secret_ids) : name
    if !contains(["JWT_SECRET", "PASSWORD_PEPPER"], name)
  ]
}

resource "google_secret_manager_secret_iam_member" "api_accessor" {
  for_each = toset(local.api_secret_names)

  secret_id = local.all_secret_ids[each.value]
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.service_runner.email}"
}

resource "google_secret_manager_secret_iam_member" "jobs_accessor" {
  for_each = toset(local.jobs_secret_names)

  secret_id = local.all_secret_ids[each.value]
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.jobs_runner.email}"
}

# --- デプロイ用 SA の権限 ---
# Cloud Run サービス / Jobs の create・update・traffic 操作・jobs execute に必要。
resource "google_project_iam_member" "deployer_run_admin" {
  project = var.project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.deployer.email}"
}

# イメージ push はリポジトリ単位で付与する。
resource "google_artifact_registry_repository_iam_member" "deployer_writer" {
  repository = google_artifact_registry_repository.registry.name
  location   = var.region
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.deployer.email}"
}

# ランタイム SA を指定してデプロイするため、対象 SA 単位で付与する。
resource "google_service_account_iam_member" "deployer_use_service_runner" {
  service_account_id = google_service_account.service_runner.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_service_account_iam_member" "deployer_use_jobs_runner" {
  service_account_id = google_service_account.jobs_runner.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deployer.email}"
}
