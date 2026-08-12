output "project_id" {
  description = "作成した GCP プロジェクトID"
  value       = google_project.main.project_id
}

output "state_bucket_name" {
  description = "Terraform state 用 GCS バケット名"
  value       = google_storage_bucket.terraform_state.name
}
