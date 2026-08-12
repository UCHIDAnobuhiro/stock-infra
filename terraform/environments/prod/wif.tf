# GitHub Actions から OIDC でキーレス認証する。
# リポジトリと Git ref の両方を検証し、想定外のワークフローからの認証を拒否する。
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "${var.resource_prefix}-github"
  display_name              = "GitHub Actions"

  depends_on = [google_project_service.services["iam.googleapis.com"]]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
  }

  attribute_condition = <<-EOT
    assertion.repository == "${var.github_repository}" &&
    assertion.ref == "${var.github_ref}"
  EOT

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "deployer_wif" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}
