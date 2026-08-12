# Cloud Run は Direct VPC egress（--network/--subnet 指定）で default VPC に出る。
# Serverless VPC Access コネクタは固定費（常時稼働インスタンス）がかかるため使わない。
data "google_compute_network" "default" {
  name = "default"

  depends_on = [google_project_service.services["compute.googleapis.com"]]
}

data "google_compute_subnetwork" "default" {
  name   = "default"
  region = var.region

  depends_on = [google_project_service.services["compute.googleapis.com"]]
}
