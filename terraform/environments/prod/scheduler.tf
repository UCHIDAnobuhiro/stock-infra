# candles/logoバッチを定期実行するCloud Scheduler。
#
# Cloud Run Admin API v2 の projects.locations.jobs.run をHTTPターゲットとして呼び出す。
# デフォルトargsは cloud-run.tf 側の batch_single Job定義（["candles"]）に依存するため、
# candles/logoどちらも overrides.containerOverrides で job_id を明示的に指定する。
# こうすることで、将来デフォルトargsが変わってもScheduler側の挙動はこのファイルの記述だけで分かる。
#
# google_cloud_scheduler_job には deletion_protection 相当の属性が存在しない。
# stateを持たないリソースであり置き換えによるデータ損失もないため prevent_destroy は付けないが、
# AGENTS.mdの規約通り plan で forces replacement が出た場合は他リソースと同様に作業を止めて報告する。

locals {
  # Cloud Run Admin API v2 の projects.locations.jobs.run エンドポイント。
  # enable_cloud_run = false（batch_singleが存在しない初回applyの前段階）でも
  # plan自体が失敗しないよう try() で null にフォールバックする。
  batch_job_run_uri = try(
    "https://run.googleapis.com/v2/projects/${google_cloud_run_v2_job.batch_single[0].project}/locations/${google_cloud_run_v2_job.batch_single[0].location}/jobs/${google_cloud_run_v2_job.batch_single[0].name}:run",
    null
  )
}

resource "google_cloud_scheduler_job" "candles_daily" {
  count = var.enable_cloud_run ? 1 : 0

  name        = "candles-daily"
  description = "batch Job(job_id=candles)を毎日7:00 JSTに実行する"
  schedule    = "0 7 * * *"
  time_zone   = "Asia/Tokyo"
  region      = var.region

  # jobs.run呼び出しはExecutionの起動をキューイングして即座に応答するため、
  # batch Job本体のtimeout(10800s)より十分短いdeadlineでよい。
  attempt_deadline = "300s"

  retry_config {
    retry_count          = 3
    min_backoff_duration = "5s"
    max_backoff_duration = "60s"
    max_doublings        = 3
  }

  http_target {
    uri         = local.batch_job_run_uri
    http_method = "POST"

    headers = {
      "Content-Type" = "application/json"
    }

    # containerの name は cloud-run.tf の batch_single Job定義（containers { name = "batch" }）と一致させる。
    body = base64encode(jsonencode({
      overrides = {
        containerOverrides = [
          {
            name = "batch"
            args = ["candles"]
          },
        ]
      }
    }))

    oauth_token {
      service_account_email = google_service_account.scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_project_service.services["cloudscheduler.googleapis.com"],
    google_cloud_run_v2_job_iam_member.batch_single_scheduler,
  ]
}

resource "google_cloud_scheduler_job" "logo_weekly" {
  count = var.enable_cloud_run ? 1 : 0

  name        = "logo-weekly"
  description = "batch Job(job_id=logo)を毎週日曜10:00 JSTに実行する"
  schedule    = "0 10 * * 0"
  time_zone   = "Asia/Tokyo"
  region      = var.region

  attempt_deadline = "300s"

  retry_config {
    retry_count          = 3
    min_backoff_duration = "5s"
    max_backoff_duration = "60s"
    max_doublings        = 3
  }

  http_target {
    uri         = local.batch_job_run_uri
    http_method = "POST"

    headers = {
      "Content-Type" = "application/json"
    }

    body = base64encode(jsonencode({
      overrides = {
        containerOverrides = [
          {
            name = "batch"
            args = ["logo"]
          },
        ]
      }
    }))

    oauth_token {
      service_account_email = google_service_account.scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_project_service.services["cloudscheduler.googleapis.com"],
    google_cloud_run_v2_job_iam_member.batch_single_scheduler,
  ]
}
