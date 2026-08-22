# GitHub Actions から OIDC でキーレス認証する。
# 再利用され得る名前ではなく数値IDを信頼し、main上の許可済みCD workflowだけを受け入れる。
locals {
  github_numeric_attribute_condition = join(" && ", [
    "assertion.repository_id == ${jsonencode(var.github_repository_id)}",
    "assertion.repository_owner_id == ${jsonencode(var.github_repository_owner_id)}",
    "assertion.ref == ${jsonencode(var.github_ref)}",
    "assertion.workflow_ref in ${jsonencode(sort(tolist(var.github_workflow_refs)))}",
  ])
  github_legacy_attribute_condition = join(" && ", [
    "assertion.repository == ${jsonencode(var.github_repository)}",
    "assertion.ref == ${jsonencode(var.github_ref)}",
  ])
  github_attribute_condition = var.enable_github_wif_legacy_repository ? format(
    "(%s) || (%s)",
    local.github_numeric_attribute_condition,
    local.github_legacy_attribute_condition,
  ) : local.github_numeric_attribute_condition
}

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "${var.resource_prefix}-github"
  display_name              = "GitHub Actions"

  depends_on = [google_project_service.services["iam.googleapis.com"]]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub OIDC"

  attribute_mapping = merge(
    {
      "google.subject"                = "assertion.repository_id"
      "attribute.repository_id"       = "assertion.repository_id"
      "attribute.repository_owner_id" = "assertion.repository_owner_id"
      "attribute.ref"                 = "assertion.ref"
      "attribute.workflow_ref"        = "assertion.workflow_ref"
    },
    var.enable_github_wif_legacy_repository ? {
      "attribute.repository" = "assertion.repository"
    } : {},
  )

  attribute_condition = local.github_attribute_condition

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "deployer_wif" {
  count = var.enable_github_wif_legacy_repository ? 1 : 0

  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

resource "google_service_account_iam_member" "deployer_wif_repository_id" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository_id/${var.github_repository_id}"
}
