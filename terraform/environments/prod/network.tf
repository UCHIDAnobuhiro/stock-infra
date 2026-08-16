# Cloud Run は Direct VPC egress（--network/--subnet 指定）で default VPC に出る。
# Serverless VPC Access コネクタは固定費（常時稼働インスタンス）がかかるため使わない。
# API追加時にgoogle_project_service.services全体が変更中になっても、Redisの
# authorized_networkをapply時まで未知にしない。未知値はRedisの不要な再作成を誘発する。
locals {
  default_network_name    = "default"
  default_network_id      = "projects/${var.project_id}/global/networks/${local.default_network_name}"
  default_subnetwork_name = "default"
}
