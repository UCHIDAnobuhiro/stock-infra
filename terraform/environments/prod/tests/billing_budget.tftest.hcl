mock_provider "google" {}

mock_provider "random" {}

variables {
  project_id        = "example-project-123"
  region            = "asia-northeast1"
  resource_prefix   = "stock"
  github_repository = "example/backend"

  manual_secret_versions = {
    TWELVE_DATA_API_KEY  = "1"
    GOOGLE_CLIENT_ID     = "1"
    GOOGLE_CLIENT_SECRET = "1"
    GITHUB_CLIENT_ID     = "1"
    GITHUB_CLIENT_SECRET = "1"
  }

  initial_api_image     = "asia-northeast1-docker.pkg.dev/example-project-123/stock-registry/backend:${join("", ["0123456789abcdef", "0123456789abcdef", "01234567"])}"
  initial_batch_image   = "asia-northeast1-docker.pkg.dev/example-project-123/stock-registry/batch:${join("", ["0123456789abcdef", "0123456789abcdef", "01234567"])}"
  initial_migrate_image = "asia-northeast1-docker.pkg.dev/example-project-123/stock-registry/migrate:${join("", ["0123456789abcdef", "0123456789abcdef", "01234567"])}"

  cors_allowed_origins = ["https://www.example.com"]
  cookie_domain        = "example.com"
}

run "billing_budget_is_disabled_by_default" {
  command = plan

  assert {
    condition     = length(google_billing_budget.monthly) == 0
    error_message = "enable_billing_budget を指定しない既存環境では予算を作成しないでください。"
  }
}

run "billing_budget_notifies_by_email" {
  command = plan

  variables {
    enable_billing_budget = true
    billing_account_id    = "000000-000000-000000"
  }

  assert {
    condition = (
      google_billing_budget.monthly[0].amount[0].specified_amount[0].units == "20000" &&
      google_billing_budget.monthly[0].amount[0].specified_amount[0].currency_code == "JPY" &&
      google_billing_budget.monthly[0].budget_filter[0].calendar_period == "MONTH"
    )
    error_message = "既定の予算は月20,000円にしてください。"
  }

  assert {
    condition = (
      length(google_billing_budget.monthly[0].threshold_rules) == 4 &&
      contains([for rule in google_billing_budget.monthly[0].threshold_rules : "${rule.spend_basis}:${rule.threshold_percent}"], "FORECASTED_SPEND:1")
    )
    error_message = "実績50/90/100%と予測100%のしきい値を設定してください。"
  }

  assert {
    condition     = length(google_billing_budget.monthly[0].all_updates_rule) == 0
    error_message = "既定のメール通知だけを使い、追加の通知先を設定しないでください。"
  }
}

run "billing_budget_requires_billing_account" {
  command = plan

  variables {
    enable_billing_budget = true
  }

  expect_failures = [google_billing_budget.monthly]
}
