# 本プロジェクトの月次予算。しきい値を超えるとBilling Account管理者・ユーザーへメールで通知する。
#
# 予算は通知するだけで課金を止めない。また費用データの反映には数時間の遅れがある。
#
# 予算APIはユーザー認証で呼び出すとquota projectが必要になる。実行者のADCに
# 本プロジェクトをquota projectとして設定する（docs/operations.md「予算とコスト通知」）。

locals {
  # 実績額は段階的に、予測額は予算到達の見込みだけを通知する。
  budget_threshold_rules = [
    { percent = 0.5, spend_basis = "CURRENT_SPEND" },
    { percent = 0.9, spend_basis = "CURRENT_SPEND" },
    { percent = 1.0, spend_basis = "CURRENT_SPEND" },
    { percent = 1.0, spend_basis = "FORECASTED_SPEND" },
  ]
}

data "google_project" "current" {
  count = var.enable_billing_budget ? 1 : 0

  project_id = var.project_id
}

resource "google_billing_budget" "monthly" {
  count = var.enable_billing_budget ? 1 : 0

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

  # all_updates_ruleを指定しない場合、Billing Account管理者・ユーザーへ既定のメール通知が届く。
  # 予算超過で外部アクセスを閉じる場合だけ、通知をPub/Subへも発行する（budget-shutdown.tf）。
  # disable_default_iam_recipientsの既定値はfalseのため、メール通知は残る。
  dynamic "all_updates_rule" {
    for_each = local.budget_shutdown_enabled ? [google_pubsub_topic.budget_alerts[0].id] : []
    content {
      pubsub_topic   = all_updates_rule.value
      schema_version = "1.0"
    }
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
