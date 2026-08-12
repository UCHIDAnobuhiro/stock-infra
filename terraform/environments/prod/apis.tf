locals {
  services = toset([
    "aiplatform.googleapis.com",       # Vertex AI (Gemini)
    "artifactregistry.googleapis.com", # コンテナイメージレジストリ
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com", # default VPC / Direct VPC egress
    "iam.googleapis.com",
    "iamcredentials.googleapis.com", # WIF トークン発行
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "redis.googleapis.com", # Memorystore
    "run.googleapis.com",   # Cloud Run / Jobs
    "secretmanager.googleapis.com",
    "serviceusage.googleapis.com",
    "sqladmin.googleapis.com", # Cloud SQL
    "sts.googleapis.com",      # WIF token exchange
    "vision.googleapis.com",   # ロゴ検出
  ])
}

resource "google_project_service" "services" {
  for_each = local.services

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
