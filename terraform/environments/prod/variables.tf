variable "project_id" {
  description = "リソースを作成する GCP プロジェクトID"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id は6〜30文字の有効な GCP プロジェクトIDにしてください。"
  }
}

variable "region" {
  description = "リソースを作成するリージョン"
  type        = string
}

variable "cloud_run_subnet_cidr" {
  description = "専用VPCでCloud Run Direct VPC egressに割り当てる10.0.0.0/8内の/26以上のIPv4 CIDR"
  type        = string
  default     = "10.10.0.0/26"

  validation {
    condition = try(
      cidrhost(var.cloud_run_subnet_cidr, 0) == split("/", var.cloud_run_subnet_cidr)[0] &&
      tonumber(split("/", var.cloud_run_subnet_cidr)[1]) >= 8 &&
      tonumber(split("/", var.cloud_run_subnet_cidr)[1]) <= 26 &&
      can(regex("^10\\.", cidrhost(var.cloud_run_subnet_cidr, 0))),
      false,
    )
    error_message = "cloud_run_subnet_cidr は10.0.0.0/8内の正規化した/8〜/26 CIDRにしてください。"
  }
}

variable "vertex_ai_location" {
  description = "Vertex AI Geminiモデルを呼び出すロケーション"
  type        = string
  default     = "global"
}

variable "resource_prefix" {
  description = "GCP リソース名に付与する短いプレフィックス"
  type        = string
  default     = "stock"

  validation {
    condition = (
      length(var.resource_prefix) >= 3 &&
      length(var.resource_prefix) <= 20 &&
      can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", var.resource_prefix))
    )
    error_message = "resource_prefix は3〜20文字の小文字英数字・ハイフンで指定してください。"
  }
}

variable "github_repository" {
  description = "WIF 経由でデプロイを許可する GitHub リポジトリ（owner/repo 形式）"
  type        = string

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "github_repository は owner/repo 形式で指定してください。"
  }
}

variable "github_ref" {
  description = "WIF 経由のデプロイを許可する Git ref"
  type        = string
  default     = "refs/heads/main"
}

variable "db_name" {
  description = "アプリケーション用データベース名"
  type        = string
  default     = "app"
}

variable "db_user" {
  description = "アプリケーション用データベースユーザー名"
  type        = string
  default     = "appuser"
}

variable "twelve_data_base_url" {
  description = "Twelve Data API のベースURL"
  type        = string
  default     = "https://api.twelvedata.com"
}

variable "manual_secret_versions" {
  description = "人間が値を投入するSecretの参照version。値ではなく有効な数値versionだけを指定する"
  type = object({
    TWELVE_DATA_API_KEY  = string
    GOOGLE_CLIENT_ID     = string
    GOOGLE_CLIENT_SECRET = string
    GITHUB_CLIENT_ID     = string
    GITHUB_CLIENT_SECRET = string
  })

  validation {
    condition = alltrue([
      for version in values(var.manual_secret_versions) :
      can(regex("^[1-9][0-9]*$", version))
    ])
    error_message = "manual_secret_versions はlatestや空文字ではなく、1以上の数値versionを文字列で指定してください。"
  }
}

variable "managed_secret_version_overrides" {
  description = "Terraform管理Secretを旧versionへ戻す緊急rollback用。通常は空のまま使用する"
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for name, version in var.managed_secret_version_overrides :
      contains([
        "JWT_SECRET",
        "PASSWORD_PEPPER",
        "DB_PASSWORD",
        "DB_USER",
        "DB_NAME",
        "INSTANCE_CONNECTION_NAME",
        "REDIS_DEDICATED_HOST",
        "REDIS_DEDICATED_PORT",
        "REDIS_DEDICATED_PASSWORD",
        "TWELVE_DATA_BASE_URL",
      ], name) && can(regex("^[1-9][0-9]*$", version))
    ])
    error_message = "managed_secret_version_overrides はTerraform管理Secret名と1以上の数値versionだけを指定してください。"
  }
}

variable "initial_api_image" {
  description = "Cloud Run APIの初回作成に使うイメージ。以後の更新はbackend CDが管理する"
  type        = string

  validation {
    condition = can(regex(
      "^(:[0-9a-f]{40}|@sha256:[0-9a-f]{64})$",
      trimprefix(
        var.initial_api_image,
        "${var.region}-docker.pkg.dev/${var.project_id}/${var.resource_prefix}-registry/backend",
      ),
    ))
    error_message = "initial_api_image は対象projectの <resource_prefix>-registry/backend を40文字のcommit SHAタグまたはsha256 digestで固定してください。"
  }
}

variable "initial_batch_image" {
  description = "Cloud Run batch Jobの初回作成に使うイメージ。以後の更新はbackend CDが管理する"
  type        = string

  validation {
    condition = can(regex(
      "^(:[0-9a-f]{40}|@sha256:[0-9a-f]{64})$",
      trimprefix(
        var.initial_batch_image,
        "${var.region}-docker.pkg.dev/${var.project_id}/${var.resource_prefix}-registry/batch",
      ),
    ))
    error_message = "initial_batch_image は対象projectの <resource_prefix>-registry/batch を40文字のcommit SHAタグまたはsha256 digestで固定してください。"
  }
}

variable "initial_migrate_image" {
  description = "Cloud Run migrate Jobの初回作成に使うイメージ。以後の更新はbackend CDが管理する"
  type        = string

  validation {
    condition = can(regex(
      "^(:[0-9a-f]{40}|@sha256:[0-9a-f]{64})$",
      trimprefix(
        var.initial_migrate_image,
        "${var.region}-docker.pkg.dev/${var.project_id}/${var.resource_prefix}-registry/migrate",
      ),
    ))
    error_message = "initial_migrate_image は対象projectの <resource_prefix>-registry/migrate を40文字のcommit SHAタグまたはsha256 digestで固定してください。"
  }

  validation {
    condition = (
      (
        alltrue([
          for image in [var.initial_api_image, var.initial_batch_image, var.initial_migrate_image] :
          can(regex(":[0-9a-f]{40}$", image))
        ]) &&
        length(toset([
          for image in [var.initial_api_image, var.initial_batch_image, var.initial_migrate_image] :
          try(regex("[0-9a-f]{40}$", image), "")
        ])) == 1
      ) ||
      alltrue([
        for image in [var.initial_api_image, var.initial_batch_image, var.initial_migrate_image] :
        can(regex("@sha256:[0-9a-f]{64}$", image))
      ])
    )
    error_message = "初回イメージは3つとも同一commit SHAタグを指定するか、3つともsha256 digestで固定してください。"
  }
}

variable "cors_allowed_origins" {
  description = "APIがCORSで許可する本番originの一覧"
  type        = list(string)

  validation {
    condition = (
      length(var.cors_allowed_origins) > 0 &&
      alltrue([
        for origin in var.cors_allowed_origins :
        can(regex("^https://[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(:[0-9]{1,5})?$", origin))
      ])
    )
    error_message = "cors_allowed_origins は末尾スラッシュを含まないHTTPS originを1件以上指定してください。"
  }
}

variable "cookie_domain" {
  description = "認証セッションCookieを共有する親ドメイン。スキーム、先頭ドット、ポート、パスを含めない"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.cookie_domain))
    error_message = "cookie_domain は小文字の親ドメイン（例: example.com）にしてください。"
  }
}

variable "enable_oauth" {
  description = "Google/GitHub OAuthをCloud Run APIで有効化するか"
  type        = bool
  default     = false

  validation {
    condition = !var.enable_oauth || (
      var.enable_cloud_run &&
      var.enable_api_domain &&
      var.api_domain != "" &&
      var.oauth_frontend_redirect_url != ""
    )
    error_message = "enable_oauth を有効にする場合はCloud RunとAPI独自ドメインを有効化し、oauth_frontend_redirect_urlを設定してください。"
  }
}

variable "oauth_frontend_redirect_url" {
  description = "OAuth認証完了後に戻すfrontendのHTTPS origin。末尾スラッシュを含めない"
  type        = string
  default     = ""

  validation {
    condition = (
      var.oauth_frontend_redirect_url == "" ||
      can(regex("^https://[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+(:[0-9]{1,5})?$", var.oauth_frontend_redirect_url))
    )
    error_message = "oauth_frontend_redirect_url は空文字か、末尾スラッシュを含まないHTTPS originにしてください。"
  }
}

variable "enable_api_domain" {
  description = "API独自ドメイン用の外部HTTPSロードバランサーを作成するか。Cloud Run作成後に有効化する"
  type        = bool
  default     = false

  validation {
    condition = !var.enable_api_domain || (
      var.enable_cloud_run && var.api_domain != ""
    )
    error_message = "enable_api_domain を有効にする場合は、enable_cloud_run=true と有効な api_domain が必要です。"
  }
}

variable "api_domain" {
  description = "APIの独自ドメイン。スキームやパスを含まないFQDNで指定する"
  type        = string
  default     = ""

  validation {
    condition = (
      var.api_domain == "" ||
      can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.api_domain))
    )
    error_message = "api_domain は空文字か、小文字のFQDN（例: api.example.com）にしてください。"
  }
}

variable "restrict_api_to_load_balancer" {
  description = "Cloud Run APIへの外部通信をロードバランサー経由に限定するか。DNS・証明書・疎通確認後に有効化する"
  type        = bool
  default     = false

  validation {
    condition     = !var.restrict_api_to_load_balancer || var.enable_api_domain
    error_message = "restrict_api_to_load_balancer を有効にする前に enable_api_domain を有効にしてください。"
  }
}

variable "api_max_instance_count" {
  description = "Cloud Run APIの最大インスタンス数"
  type        = number
  default     = 3

  validation {
    condition     = var.api_max_instance_count >= 1
    error_message = "api_max_instance_count は1以上にしてください。"
  }
}

variable "enable_cloud_run" {
  description = "Cloud Run Service / Jobsを作成するか。新規環境では基盤の初回apply後に有効化する"
  type        = bool
  default     = true
}

variable "slack_notification_channel_id" {
  description = "Cloud MonitoringでOAuth連携済みのSlack通知チャネルID。tokenをTerraform stateへ保存しないためチャネル自体はGCP側で作成する"
  type        = string
  default     = ""

  validation {
    condition = (
      var.slack_notification_channel_id == "" ||
      can(regex(
        "^projects/[a-z][a-z0-9-]{4,28}[a-z0-9]/notificationChannels/[0-9]+$",
        var.slack_notification_channel_id,
      ))
    )
    error_message = "slack_notification_channel_id は空文字か、projects/<project-id>/notificationChannels/<channel-id> 形式にしてください。"
  }
}
