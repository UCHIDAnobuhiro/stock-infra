# SlackのOAuth tokenをTerraform stateへ保存しないため、通知チャネル自体は
# Cloud Monitoringで人間が作成し、このファイルではチャネルIDだけを参照する。
locals {
  monitoring_notification_channels = var.slack_notification_channel_id == "" ? [] : [
    var.slack_notification_channel_id,
  ]
}

resource "google_monitoring_uptime_check_config" "api_healthz" {
  count = var.enable_api_domain ? 1 : 0

  display_name = "${var.resource_prefix}-api-healthz"
  timeout      = "10s"
  period       = "60s"
  checker_type = "STATIC_IP_CHECKERS"

  http_check {
    path           = "/healthz"
    port           = 443
    request_method = "GET"
    use_ssl        = true
    validate_ssl   = true

    accepted_response_status_codes {
      status_class = "STATUS_CLASS_2XX"
    }
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      host       = var.api_domain
      project_id = var.project_id
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.services["monitoring.googleapis.com"]]
}

resource "google_monitoring_alert_policy" "cloud_sql_disk" {
  display_name = "${var.resource_prefix}: Cloud SQL disk usage >= 80%"
  combiner     = "OR"
  severity     = "ERROR"

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      Cloud SQLのディスク使用率が5分間80%を超えています。

      `docs/operations.md`の「Cloud SQLディスク使用率」を確認し、書き込み増加の原因と
      空き容量を調査してください。ディスク自動拡張はコスト管理のため無効です。
    EOT
  }

  conditions {
    display_name = "Disk utilization > 0.8 for 5 minutes"

    condition_threshold {
      filter = join(" AND ", [
        "resource.type = \"cloudsql_database\"",
        "metric.type = \"cloudsql.googleapis.com/database/disk/utilization\"",
        "resource.label.database_id = \"${var.project_id}:${google_sql_database_instance.main.name}\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      duration        = "300s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.monitoring_notification_channels

  alert_strategy {
    auto_close = "86400s"
  }

  user_labels = {
    component = "cloud-sql"
    severity  = "critical"
  }

  depends_on = [google_project_service.services["monitoring.googleapis.com"]]
}

resource "google_monitoring_alert_policy" "cloud_sql_connections" {
  display_name = "${var.resource_prefix}: Cloud SQL connections >= 20"
  combiner     = "OR"
  severity     = "WARNING"

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      Cloud SQLの接続数が5分間20以上です。接続上限25のうち運用・監視用に確保した
      6接続を消費し始めています。

      `docs/operations.md`の「Cloud SQL接続数」に従い、重複Job、接続リーク、
      Cloud Runのインスタンス数を確認してください。
    EOT
  }

  conditions {
    display_name = "PostgreSQL backends > 19 for 5 minutes"

    condition_threshold {
      filter = join(" AND ", [
        "resource.type = \"cloudsql_database\"",
        "metric.type = \"cloudsql.googleapis.com/database/postgresql/num_backends\"",
        "resource.label.database_id = \"${var.project_id}:${google_sql_database_instance.main.name}\"",
      ])
      comparison = "COMPARISON_GT"
      threshold_value = (
        local.database_connection_limit - local.database_connection_reserve
      )
      duration = "300s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_MAX"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.database_id"]
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.monitoring_notification_channels

  alert_strategy {
    auto_close = "86400s"
  }

  user_labels = {
    component = "cloud-sql"
    severity  = "warning"
  }

  depends_on = [google_project_service.services["monitoring.googleapis.com"]]
}

resource "google_monitoring_alert_policy" "api_5xx_rate" {
  count = var.enable_cloud_run ? 1 : 0

  display_name = "${var.resource_prefix}: Cloud Run API 5xx rate > 5%"
  combiner     = "OR"
  severity     = "ERROR"

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      Cloud Run APIの5xx率が5分間5%を超えています。

      `docs/operations.md`の「Cloud Run APIの5xx率」に従い、直近Revisionのログ、
      Cloud SQL・Redisの状態、直近デプロイを確認してください。
    EOT
  }

  conditions {
    display_name = "5xx requests / all requests > 0.05 for 5 minutes"

    condition_threshold {
      filter = join(" AND ", [
        "resource.type = \"cloud_run_revision\"",
        "metric.type = \"run.googleapis.com/request_count\"",
        "resource.label.service_name = \"${google_cloud_run_v2_service.api[0].name}\"",
        "resource.label.location = \"${var.region}\"",
        "metric.label.response_code_class = \"5xx\"",
      ])
      denominator_filter = join(" AND ", [
        "resource.type = \"cloud_run_revision\"",
        "metric.type = \"run.googleapis.com/request_count\"",
        "resource.label.service_name = \"${google_cloud_run_v2_service.api[0].name}\"",
        "resource.label.location = \"${var.region}\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 0.05
      duration        = "300s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields = [
          "resource.label.location",
          "resource.label.service_name",
        ]
      }

      denominator_aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields = [
          "resource.label.location",
          "resource.label.service_name",
        ]
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.monitoring_notification_channels

  alert_strategy {
    auto_close = "21600s"
  }

  user_labels = {
    component = "cloud-run-api"
    severity  = "critical"
  }

  depends_on = [google_project_service.services["monitoring.googleapis.com"]]
}

resource "google_monitoring_alert_policy" "api_latency" {
  count = var.enable_cloud_run ? 1 : 0

  display_name = "${var.resource_prefix}: Cloud Run API p95 latency > 2s"
  combiner     = "OR"
  severity     = "WARNING"

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      Cloud Run APIのp95レイテンシが5分間2秒を超えています。

      `docs/operations.md`の「Cloud Run APIのレイテンシ」に従い、遅いエンドポイント、
      Cloud SQL接続数、外部API待ち、Cloud Runのスケーリング状況を確認してください。
    EOT
  }

  conditions {
    display_name = "p95 request latency > 2000ms for 5 minutes"

    condition_threshold {
      filter = join(" AND ", [
        "resource.type = \"cloud_run_revision\"",
        "metric.type = \"run.googleapis.com/request_latencies\"",
        "resource.label.service_name = \"${google_cloud_run_v2_service.api[0].name}\"",
        "resource.label.location = \"${var.region}\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 2000
      duration        = "300s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_PERCENTILE_95"
        cross_series_reducer = "REDUCE_PERCENTILE_95"
        group_by_fields = [
          "resource.label.location",
          "resource.label.service_name",
        ]
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.monitoring_notification_channels

  alert_strategy {
    auto_close = "21600s"
  }

  user_labels = {
    component = "cloud-run-api"
    severity  = "warning"
  }

  depends_on = [google_project_service.services["monitoring.googleapis.com"]]
}

resource "google_monitoring_alert_policy" "cloud_run_job_failure" {
  count = var.enable_cloud_run ? 1 : 0

  display_name = "${var.resource_prefix}: Cloud Run Job failed"
  combiner     = "OR"
  severity     = "ERROR"

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      Cloud Runのbatchまたはmigrate Jobが失敗しました。

      `docs/operations.md`の「Cloud Run Job失敗」に従い、失敗したExecutionのログと
      終了コードを確認してください。原因を確認せずにJobを連続再実行しないでください。
    EOT
  }

  conditions {
    display_name = "batch execution failed"

    condition_threshold {
      filter = join(" AND ", [
        "resource.type = \"cloud_run_job\"",
        "metric.type = \"run.googleapis.com/job/completed_execution_count\"",
        "resource.label.job_name = \"${google_cloud_run_v2_job.batch_single[0].name}\"",
        "resource.label.location = \"${var.region}\"",
        "metric.label.result = \"failed\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }

      trigger {
        count = 1
      }
    }
  }

  conditions {
    display_name = "migrate execution failed"

    condition_threshold {
      filter = join(" AND ", [
        "resource.type = \"cloud_run_job\"",
        "metric.type = \"run.googleapis.com/job/completed_execution_count\"",
        "resource.label.job_name = \"${google_cloud_run_v2_job.migrate[0].name}\"",
        "resource.label.location = \"${var.region}\"",
        "metric.label.result = \"failed\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.monitoring_notification_channels

  alert_strategy {
    auto_close = "21600s"
  }

  user_labels = {
    component = "cloud-run-job"
    severity  = "critical"
  }

  depends_on = [google_project_service.services["monitoring.googleapis.com"]]
}

# Cloud Schedulerには失敗回数のネイティブメトリクスがないため、公式のAttemptFinished実行ログを使う。
# 成功はINFO、失敗はERRORで記録されるため、ERROR以上だけを通知対象にする。
resource "google_monitoring_alert_policy" "scheduler_failure" {
  count = var.enable_cloud_run ? 1 : 0

  display_name = "${var.resource_prefix}: Cloud Scheduler execution failed"
  combiner     = "OR"
  severity     = "ERROR"

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      Cloud Schedulerの実行が失敗しました。

      `docs/operations.md`の「Cloud Scheduler実行失敗」に従い、抽出されたjob ID、
      AttemptFinishedログ、Cloud Run Admin APIの応答、scheduler SAのIAMを確認してください。
    EOT
  }

  conditions {
    display_name = "AttemptFinished log has ERROR severity"

    condition_matched_log {
      filter = <<-EOT
        resource.type="cloud_scheduler_job"
        resource.labels.location="${var.region}"
        jsonPayload."@type"="type.googleapis.com/google.cloud.scheduler.logging.AttemptFinished"
        severity>=ERROR
      EOT

      label_extractors = {
        job_id = "EXTRACT(resource.labels.job_id)"
        status = "EXTRACT(jsonPayload.status)"
      }
    }
  }

  notification_channels = local.monitoring_notification_channels

  alert_strategy {
    auto_close = "86400s"

    notification_rate_limit {
      period = "3600s"
    }
  }

  user_labels = {
    component = "cloud-scheduler"
    severity  = "critical"
  }

  depends_on = [
    google_project_service.services["logging.googleapis.com"],
    google_project_service.services["monitoring.googleapis.com"],
  ]
}

resource "google_monitoring_alert_policy" "api_uptime" {
  count = var.enable_api_domain ? 1 : 0

  display_name = "${var.resource_prefix}: API /healthz unavailable"
  combiner     = "OR"
  severity     = "ERROR"

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      複数のUptime Check拠点から独自ドメインの`/healthz`へ2分間到達できません。

      `docs/operations.md`の「API Uptime Check失敗」に従い、証明書、ロードバランサー、
      Cloud Run Revision、Cloud SQL・Redisの順に確認してください。
    EOT
  }

  conditions {
    display_name = "At least two checkers fail for 2 minutes"

    condition_threshold {
      filter = join(" AND ", [
        "resource.type = \"uptime_url\"",
        "metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\"",
        "metric.label.check_id = \"${google_monitoring_uptime_check_config.api_healthz[0].uptime_check_id}\"",
      ])
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "120s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_NEXT_OLDER"
      }

      trigger {
        count = 2
      }
    }
  }

  notification_channels = local.monitoring_notification_channels

  alert_strategy {
    auto_close = "21600s"
  }

  user_labels = {
    component = "uptime-check"
    severity  = "critical"
  }

  depends_on = [google_project_service.services["monitoring.googleapis.com"]]
}
