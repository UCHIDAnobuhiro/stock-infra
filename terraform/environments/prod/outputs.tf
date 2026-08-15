# GitHub Actions の Repository Secrets / Variables に設定する値。
output "github_secret_gcp_wif_provider" {
  description = "GCP_WIF_PROVIDER に設定する値"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "github_secret_gcp_wif_service_account" {
  description = "GCP_WIF_SERVICE_ACCOUNT に設定する値"
  value       = google_service_account.deployer.email
}

output "github_secret_gcp_project_id" {
  description = "GCP_PROJECT_ID に設定する値"
  value       = var.project_id
}

output "artifact_registry" {
  description = "コンテナイメージの push 先"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.registry.repository_id}"
}

output "service_runner_email" {
  description = "API のランタイム SA"
  value       = google_service_account.service_runner.email
}

output "jobs_runner_email" {
  description = "バッチのランタイム SA"
  value       = google_service_account.jobs_runner.email
}

output "migrate_runner_email" {
  description = "マイグレーションJobのランタイム SA"
  value       = google_service_account.migrate_runner.email
}

output "cloud_run_service_uri" {
  description = "APIのCloud Run URI"
  value       = try(google_cloud_run_v2_service.api[0].uri, null)
}

output "cloud_run_job_names" {
  description = "backend CDがイメージを更新するCloud Run Job名"
  value = concat(
    sort(keys(google_cloud_run_v2_job.batch)),
    try([google_cloud_run_v2_job.migrate[0].name], []),
  )
}

output "redis_host" {
  description = "Memorystore のプライベートIP（Direct VPC egress 経由で到達）"
  value       = google_redis_instance.main.host
}
