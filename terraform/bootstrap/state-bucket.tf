# tfstate には生成パスワード等が平文で保存されるため、公開アクセスを明示的に拒否する。
resource "google_storage_bucket" "terraform_state" {
  project  = google_project.main.project_id
  name     = var.state_bucket_name
  location = var.region

  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.bootstrap["storage.googleapis.com"]]
}
