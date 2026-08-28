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

output "scheduler_email" {
  description = "Cloud SchedulerがbatchJobを起動する際に使うSA"
  value       = google_service_account.scheduler.email
}

output "cloud_run_service_uri" {
  description = "APIのCloud Run URI"
  value       = try(google_cloud_run_v2_service.api[0].uri, null)
}

output "api_base_url" {
  description = "APIの独自ドメインURL。enable_api_domain=falseの場合はnull"
  value       = local.api_domain_enabled ? "https://${var.api_domain}" : null
}

output "api_load_balancer_ipv4" {
  description = "API外部HTTPSロードバランサーの固定IPv4。enable_api_domain=falseの場合はnull"
  value       = try(google_compute_global_address.api[0].address, null)
}

output "api_dns_records" {
  description = "DNS事業者へ登録するAPIのAレコードと証明書認証用CNAME"
  value = local.api_domain_enabled ? {
    api = {
      name = var.api_domain
      type = "A"
      data = google_compute_global_address.api[0].address
    }
    certificate_authorization = {
      name = google_certificate_manager_dns_authorization.api[0].dns_resource_record[0].name
      type = google_certificate_manager_dns_authorization.api[0].dns_resource_record[0].type
      data = google_certificate_manager_dns_authorization.api[0].dns_resource_record[0].data
    }
  } : null
}

output "cloud_run_job_names" {
  description = "backend CDがイメージを更新するCloud Run Job名"
  value = concat(
    try([google_cloud_run_v2_job.batch_single[0].name], []),
    try([google_cloud_run_v2_job.migrate[0].name], []),
  )
}

output "redis_host" {
  description = "Cloud Runが参照する本番MemorystoreのプライベートIP"
  value       = google_redis_instance.prod.host
}

output "dedicated_network_name" {
  description = "本番専用VPC名"
  value       = google_compute_network.prod.name
}

output "cloud_run_subnetwork_name" {
  description = "Cloud Run Direct VPC egress用subnet名"
  value       = google_compute_subnetwork.cloud_run.name
}

output "memorystore_inspector_vm_name" {
  description = "IAP経由で接続するMemorystore調査VM名"
  value       = google_compute_instance.memorystore_inspector.name
}

output "memorystore_inspector_vm_zone" {
  description = "Memorystore調査VMのzone"
  value       = google_compute_instance.memorystore_inspector.zone
}

output "redis_auth_secret_version" {
  description = "調査時に取得するREDIS_DEDICATED_PASSWORDの数値version"
  value       = local.all_secret_versions["REDIS_DEDICATED_PASSWORD"]
}
