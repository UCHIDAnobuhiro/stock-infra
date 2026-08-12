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
