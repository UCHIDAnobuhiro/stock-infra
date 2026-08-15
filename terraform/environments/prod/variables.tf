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

variable "initial_api_image" {
  description = "Cloud Run APIの初回作成に使うイメージ。以後の更新はbackend CDが管理する"
  type        = string

  validation {
    condition     = trimspace(var.initial_api_image) != ""
    error_message = "initial_api_image は空にできません。"
  }
}

variable "initial_batch_image" {
  description = "Cloud Run batch Jobの初回作成に使うイメージ。以後の更新はbackend CDが管理する"
  type        = string

  validation {
    condition     = trimspace(var.initial_batch_image) != ""
    error_message = "initial_batch_image は空にできません。"
  }
}

variable "initial_migrate_image" {
  description = "Cloud Run migrate Jobの初回作成に使うイメージ。以後の更新はbackend CDが管理する"
  type        = string

  validation {
    condition     = trimspace(var.initial_migrate_image) != ""
    error_message = "initial_migrate_image は空にできません。"
  }
}

variable "cors_allowed_origins" {
  description = "APIがCORSで許可する本番originの一覧"
  type        = list(string)

  validation {
    condition = (
      length(var.cors_allowed_origins) > 0 &&
      alltrue([for origin in var.cors_allowed_origins : can(regex("^https://", origin))])
    )
    error_message = "cors_allowed_origins はhttps://で始まるoriginを1件以上指定してください。"
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

