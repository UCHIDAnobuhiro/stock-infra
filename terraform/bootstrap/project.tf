# 本番リソースとは state を分離し、プロジェクト自体のライフサイクルを保護する。
resource "google_project" "main" {
  project_id      = var.project_id
  name            = var.project_name
  billing_account = var.billing_account_id
  org_id          = var.organization_id
  folder_id       = var.folder_id

  # 構築済みprojectのForceNewを避けるため変更しない。prodの専用VPC移行後は依存せず、
  # default VPC自体の削除はrollback期間終了後に人間が別作業として判断する。
  auto_create_network = true
  deletion_policy     = "PREVENT"

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  bootstrap_services = toset([
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
  ])
}

resource "google_project_service" "bootstrap" {
  for_each = local.bootstrap_services

  project            = google_project.main.project_id
  service            = each.value
  disable_on_destroy = false
}
