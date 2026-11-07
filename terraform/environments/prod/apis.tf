locals {
  services = toset([
    "aiplatform.googleapis.com",         # Vertex AI (Gemini)
    "artifactregistry.googleapis.com",   # コンテナイメージレジストリ
    "billingbudgets.googleapis.com",     # 月次予算と予算通知
    "certificatemanager.googleapis.com", # API独自ドメインのGoogle管理TLS証明書
    "cloudresourcemanager.googleapis.com",
    "cloudscheduler.googleapis.com", # batch Jobの定期実行(Cloud Scheduler)
    "compute.googleapis.com",        # 専用VPC / Direct VPC egress
    "eventarc.googleapis.com",       # 予算通知のPub/SubからWorkflowsを起動
    "iap.googleapis.com",            # 調査VMへのIAP TCP forwarding
    "iam.googleapis.com",
    "iamcredentials.googleapis.com", # WIF トークン発行
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "pubsub.googleapis.com", # 予算通知の受け口
    "redis.googleapis.com",  # Memorystore
    "run.googleapis.com",    # Cloud Run / Jobs
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com", # Cloud SQL / MemorystoreのPrivate Service Access
    "serviceusage.googleapis.com",
    "sqladmin.googleapis.com",  # Cloud SQL
    "storage.googleapis.com",   # 予算通知の通知済み記録（bootstrapでも有効化済み）
    "sts.googleapis.com",       # WIF token exchange
    "vision.googleapis.com",    # ロゴ検出
    "workflows.googleapis.com", # 予算通知の重複排除とログ出力
  ])
}

resource "google_project_service" "services" {
  for_each = local.services

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
