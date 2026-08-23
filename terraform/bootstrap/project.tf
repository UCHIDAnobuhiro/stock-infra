# 本番リソースとは state を分離し、プロジェクト自体のライフサイクルを保護する。
resource "google_project" "main" {
  project_id      = var.project_id
  name            = var.project_name
  billing_account = var.billing_account_id
  org_id          = var.organization_id
  folder_id       = var.folder_id

  # project作成時にだけ評価される属性であり、構築済みprojectのForceNewを避けるため変更しない。
  # default VPCは本番リソースから切り離して廃止し、projectを再作成しない限り復元されない。
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
