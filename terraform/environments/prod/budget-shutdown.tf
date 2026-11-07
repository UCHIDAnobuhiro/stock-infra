# 予算の実績額が予算額に達したら、Cloud Run APIの外部アクセスを閉じる。
#
# 課金そのものを止めるとCloud SQL等のデータを失うおそれがあるため、ingressだけを閉じる。
# 止まるのはアクセスに比例する費用で、Cloud SQL・Redis・最小インスタンス等の固定費は残る。
# 閉じたことは独自ドメインのUptime Checkのアラートで通知される。
#
# ingressはTerraform管理のため、閉じた後のplanにはingressを戻すupdateが出る。
# 同じ月のうちに戻すと次の予算通知で再び閉じるため、復旧手順は docs/operations.md に従う。

locals {
  # enable_billing_budget・enable_cloud_runとの組み合わせは変数のvalidationで保証する。
  budget_shutdown_enabled = var.enable_budget_shutdown
}

resource "google_pubsub_topic" "budget_alerts" {
  count = local.budget_shutdown_enabled ? 1 : 0

  name = "${var.resource_prefix}-budget-alerts"

  depends_on = [google_project_service.services["pubsub.googleapis.com"]]
}

# Cloud Billingが予算通知を発行するときのシステムアカウント。
resource "google_pubsub_topic_iam_member" "budget_alerts_billing_publisher" {
  count = local.budget_shutdown_enabled ? 1 : 0

  topic  = google_pubsub_topic.budget_alerts[0].id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:billing-budget-alert@system.gserviceaccount.com"
}

# WorkflowsとEventarcトリガーで共用する。対象Serviceの更新以外の権限は持たせない。
resource "google_service_account" "budget_shutdown" {
  count = local.budget_shutdown_enabled ? 1 : 0

  account_id   = "${var.resource_prefix}-budget-shutdown"
  display_name = "Close Cloud Run API ingress when over budget"
}

resource "google_cloud_run_v2_service_iam_member" "budget_shutdown_developer" {
  count = local.budget_shutdown_enabled ? 1 : 0

  project  = google_cloud_run_v2_service.api[0].project
  location = google_cloud_run_v2_service.api[0].location
  name     = google_cloud_run_v2_service.api[0].name
  role     = "roles/run.developer"
  member   = "serviceAccount:${google_service_account.budget_shutdown[0].email}"
}

# Serviceの更新にはランタイムSAのactAsが必要になる。
resource "google_service_account_iam_member" "budget_shutdown_use_service_runner" {
  count = local.budget_shutdown_enabled ? 1 : 0

  service_account_id = google_service_account.service_runner.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.budget_shutdown[0].email}"
}

# Workflowsにはworkflow単位のIAMがないため、実行権限はプロジェクト単位で付与する。
resource "google_project_iam_member" "budget_shutdown_workflows_invoker" {
  count = local.budget_shutdown_enabled ? 1 : 0

  project = var.project_id
  role    = "roles/workflows.invoker"
  member  = "serviceAccount:${google_service_account.budget_shutdown[0].email}"
}

resource "google_workflows_workflow" "budget_shutdown" {
  count = local.budget_shutdown_enabled ? 1 : 0

  name            = "${var.resource_prefix}-budget-shutdown"
  region          = var.region
  description     = "予算の実績額が予算額に達したらCloud Run APIのingressを閉じる"
  service_account = google_service_account.budget_shutdown[0].id
  source_contents = file("${path.module}/files/budget-shutdown.yaml")

  user_env_vars = {
    SERVICE_NAME = google_cloud_run_v2_service.api[0].id
    DRY_RUN      = tostring(var.budget_shutdown_dry_run)
  }

  deletion_protection = false

  depends_on = [
    google_project_service.services["workflows.googleapis.com"],
    google_cloud_run_v2_service_iam_member.budget_shutdown_developer,
    google_service_account_iam_member.budget_shutdown_use_service_runner,
  ]
}

resource "google_eventarc_trigger" "budget_shutdown" {
  count = local.budget_shutdown_enabled ? 1 : 0

  name            = "${var.resource_prefix}-budget-shutdown"
  location        = var.region
  service_account = google_service_account.budget_shutdown[0].email

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.pubsub.topic.v1.messagePublished"
  }

  transport {
    pubsub {
      topic = google_pubsub_topic.budget_alerts[0].id
    }
  }

  destination {
    workflow = google_workflows_workflow.budget_shutdown[0].id
  }

  depends_on = [
    google_project_service.services["eventarc.googleapis.com"],
    google_project_iam_member.budget_shutdown_workflows_invoker,
  ]
}
