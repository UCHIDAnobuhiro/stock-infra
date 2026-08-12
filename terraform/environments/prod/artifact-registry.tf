resource "google_artifact_registry_repository" "registry" {
  repository_id = "${var.resource_prefix}-registry"
  location      = var.region
  format        = "DOCKER"
  description   = "API・バッチ・マイグレーション用コンテナイメージ"

  # SHA タグでイメージが増え続けるため、古い世代を自動削除して保管費を抑える。
  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-recent-10"
    action = "KEEP"

    most_recent_versions {
      keep_count = 10
    }
  }

  cleanup_policies {
    id     = "delete-stale"
    action = "DELETE"

    condition {
      older_than = "2592000s" # 30日
    }
  }

  depends_on = [google_project_service.services["artifactregistry.googleapis.com"]]
}
