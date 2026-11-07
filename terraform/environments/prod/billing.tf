# 月次予算と、しきい値超過のSlack通知。
#
# Cloud Billingの予算はMonitoringのメール通知チャネルにしか直接通知できないため、
# 予算 → Pub/Sub → Workflows（構造化ログ出力）→ ログアラート → 既存のSlackチャネル
# の経路で通知する。Slackのtokenやwebhook URLをTerraform stateへ保存しないための構成。
#
# 予算は通知するだけで課金を止めない。また費用データの反映には数時間の遅れがある。
#
# 予算APIはユーザー認証で呼び出すとquota projectが必要になる。実行者のADCに
# 本プロジェクトをquota projectとして設定する（docs/operations.md「予算とコスト通知」）。

locals {
  billing_budget_enabled = var.enable_billing_budget

  # 実績額は段階的に、予測額は予算到達の見込みだけを通知する。
  budget_threshold_rules = [
    { percent = 0.5, spend_basis = "CURRENT_SPEND" },
    { percent = 0.9, spend_basis = "CURRENT_SPEND" },
    { percent = 1.0, spend_basis = "CURRENT_SPEND" },
    { percent = 1.0, spend_basis = "FORECASTED_SPEND" },
  ]

  # Cloud Billingが予算通知をPub/Subへ発行するときのシステムSA。
  billing_budget_publisher = "serviceAccount:billing-budget-alert@system.gserviceaccount.com"
}

data "google_project" "current" {
  count = local.billing_budget_enabled ? 1 : 0

  project_id = var.project_id
}

resource "google_pubsub_topic" "budget_alerts" {
  count = local.billing_budget_enabled ? 1 : 0

  name = "${var.resource_prefix}-budget-alerts"

  depends_on = [google_project_service.services["pubsub.googleapis.com"]]
}

resource "google_pubsub_topic_iam_member" "budget_alerts_billing_publisher" {
  count = local.billing_budget_enabled ? 1 : 0

  topic  = google_pubsub_topic.budget_alerts[0].id
  role   = "roles/pubsub.publisher"
  member = local.billing_budget_publisher
}

resource "google_billing_budget" "monthly" {
  count = local.billing_budget_enabled ? 1 : 0

  billing_account = var.billing_account_id
  display_name    = "${var.resource_prefix} monthly budget"

  budget_filter {
    projects               = ["projects/${data.google_project.current[0].number}"]
    calendar_period        = "MONTH"
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = var.budget_currency_code
      units         = tostring(var.monthly_budget_amount)
    }
  }

  dynamic "threshold_rules" {
    for_each = local.budget_threshold_rules
    content {
      threshold_percent = threshold_rules.value.percent
      spend_basis       = threshold_rules.value.spend_basis
    }
  }

  all_updates_rule {
    pubsub_topic   = google_pubsub_topic.budget_alerts[0].id
    schema_version = "1.0"

    # Slackが届かない場合の保険として、Billing Account管理者へのメール通知も残す。
    disable_default_iam_recipients = false
  }

  lifecycle {
    precondition {
      condition     = var.billing_account_id != null && var.billing_account_id != ""
      error_message = "enable_billing_budget を有効にする場合は billing_account_id を設定してください。"
    }
  }

  depends_on = [
    google_project_service.services["billingbudgets.googleapis.com"],
    google_pubsub_topic_iam_member.budget_alerts_billing_publisher,
  ]
}

# --- 通知済みしきい値の記録 ---

# 1オブジェクト＝「対象月・判定基準・しきい値」の通知済み印。中身に費用情報は持たない。
resource "google_storage_bucket" "budget_alert_state" {
  count = local.billing_budget_enabled ? 1 : 0

  name     = "${var.project_id}-budget-alert-state"
  location = var.region

  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # 通知済み印は当月分だけ使う。前年同月と衝突しないよう対象月の開始日時をキーに含めており、
  # 古い印は約1年後に削除する。
  lifecycle_rule {
    condition {
      age = 400
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.services["storage.googleapis.com"]]
}

# --- Workflows ---

resource "google_service_account" "budget_notifier" {
  count = local.billing_budget_enabled ? 1 : 0

  account_id   = "${var.resource_prefix}-budget-notifier"
  display_name = "Budget notification workflow runtime"
}

# 通知済み印の作成だけを許可する。上書き・削除はできないため、重複判定を壊せない。
resource "google_storage_bucket_iam_member" "budget_notifier_marker_creator" {
  count = local.billing_budget_enabled ? 1 : 0

  bucket = google_storage_bucket.budget_alert_state[0].name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.budget_notifier[0].email}"
}

# sys.logで通知用の構造化ログを書き込むため。ログ書き込みはプロジェクト単位でしか付与できない。
resource "google_project_iam_member" "budget_notifier_log_writer" {
  count = local.billing_budget_enabled ? 1 : 0

  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.budget_notifier[0].email}"
}

resource "google_workflows_workflow" "budget_notifier" {
  count = local.billing_budget_enabled ? 1 : 0

  name            = "${var.resource_prefix}-budget-notifier"
  region          = var.region
  description     = "Cloud Billingの予算しきい値超過をログへ1回だけ出力する"
  service_account = google_service_account.budget_notifier[0].id
  source_contents = file("${path.module}/files/budget-notifier.yaml")

  user_env_vars = {
    STATE_BUCKET = google_storage_bucket.budget_alert_state[0].name
  }

  deletion_protection = false

  depends_on = [
    google_project_service.services["workflows.googleapis.com"],
    google_storage_bucket_iam_member.budget_notifier_marker_creator,
    google_project_iam_member.budget_notifier_log_writer,
  ]
}

# --- Eventarc（Pub/Sub → Workflows） ---

resource "google_service_account" "budget_trigger" {
  count = local.billing_budget_enabled ? 1 : 0

  account_id   = "${var.resource_prefix}-budget-trigger"
  display_name = "Eventarc trigger for budget notifications"
}

# Workflows には workflow 単位のIAMがないため、実行権限はプロジェクト単位で付与する。
# このSAはEventarcトリガー専用で、ほかの権限は持たせない。
resource "google_project_iam_member" "budget_trigger_workflows_invoker" {
  count = local.billing_budget_enabled ? 1 : 0

  project = var.project_id
  role    = "roles/workflows.invoker"
  member  = "serviceAccount:${google_service_account.budget_trigger[0].email}"
}

resource "google_eventarc_trigger" "budget_notifier" {
  count = local.billing_budget_enabled ? 1 : 0

  name            = "${var.resource_prefix}-budget-notifier"
  location        = var.region
  service_account = google_service_account.budget_trigger[0].email

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
    workflow = google_workflows_workflow.budget_notifier[0].id
  }

  depends_on = [
    google_project_service.services["eventarc.googleapis.com"],
    google_project_iam_member.budget_trigger_workflows_invoker,
  ]
}

# --- Slack通知 ---

# 実績額と予測額を別policyにする。ログアラートは通知頻度をpolicy単位で制限するため、
# 同じメッセージで両方を超えた場合に片方の通知が抑止されないようにする。
resource "google_monitoring_alert_policy" "budget_threshold" {
  for_each = local.billing_budget_enabled ? {
    actual = {
      title       = "actual spend"
      description = "当月の実績額が予算のしきい値を超えました。"
      severity    = "WARNING"
    }
    forecast = {
      title       = "forecasted spend"
      description = "当月の予測額が予算を超える見込みです。"
      severity    = "WARNING"
    }
  } : {}

  display_name = "${var.resource_prefix}: Budget ${each.value.title} exceeded threshold"
  combiner     = "OR"
  severity     = each.value.severity

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      ${each.value.description}

      `docs/operations.md`の「予算超過の通知」に従い、Billingレポートでサービス別・SKU別の
      費用を確認してください。費用データには数時間の遅れがあり、予算は課金を止めません。
    EOT
  }

  conditions {
    display_name = "Budget notifier logged ${each.key} threshold exceeded"

    condition_matched_log {
      filter = <<-EOT
        resource.type="workflows.googleapis.com/Workflow"
        resource.labels.workflow_id="${google_workflows_workflow.budget_notifier[0].name}"
        resource.labels.location="${var.region}"
        jsonPayload.event="budget_threshold_exceeded"
        jsonPayload.spend_basis="${each.key}"
      EOT

      label_extractors = {
        threshold_percent = "EXTRACT(jsonPayload.threshold_percent)"
        cost_amount       = "EXTRACT(jsonPayload.cost_amount)"
        budget_amount     = "EXTRACT(jsonPayload.budget_amount)"
      }
    }
  }

  notification_channels = local.monitoring_notification_channels

  alert_strategy {
    auto_close = "1800s"

    notification_rate_limit {
      period = "300s"
    }
  }

  user_labels = {
    component = "billing"
    severity  = "warning"
  }

  depends_on = [
    google_project_service.services["logging.googleapis.com"],
    google_project_service.services["monitoring.googleapis.com"],
  ]
}
