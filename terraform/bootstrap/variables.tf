variable "project_id" {
  description = "新規作成する GCP プロジェクトID（グローバルで一意）"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id は6〜30文字の有効な GCP プロジェクトIDにしてください。"
  }
}

variable "project_name" {
  description = "GCP コンソールに表示するプロジェクト名"
  type        = string
}

variable "billing_account_id" {
  description = "紐付ける Billing Account ID。公開リポジトリには実値を保存しない"
  type        = string
  sensitive   = true
}

variable "organization_id" {
  description = "所属させる Organization ID。個人プロジェクトでは null"
  type        = string
  default     = null
}

variable "folder_id" {
  description = "所属させる Folder ID。利用しない場合は null"
  type        = string
  default     = null
}

variable "region" {
  description = "state バケットと本番リソースの基準リージョン"
  type        = string
}

variable "state_bucket_name" {
  description = "Terraform state 用 GCS バケット名（グローバルで一意）"
  type        = string
}

check "project_parent" {
  assert {
    condition     = var.organization_id == null || var.folder_id == null
    error_message = "organization_id と folder_id は同時に指定できません。"
  }
}
