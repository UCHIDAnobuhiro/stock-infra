locals {
  api_domain_enabled = var.enable_cloud_run && var.enable_api_domain
}

resource "google_compute_global_address" "api" {
  count = local.api_domain_enabled ? 1 : 0

  name         = "${var.resource_prefix}-api-ip"
  address_type = "EXTERNAL"
  ip_version   = "IPV4"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.services["compute.googleapis.com"]]
}

resource "google_compute_region_network_endpoint_group" "api" {
  count = local.api_domain_enabled ? 1 : 0

  name                  = "${var.resource_prefix}-api-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.api[0].name
  }

  depends_on = [google_project_service.services["compute.googleapis.com"]]
}

resource "google_compute_backend_service" "api" {
  count = local.api_domain_enabled ? 1 : 0

  name                  = "${var.resource_prefix}-api-backend"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"

  # Serverless NEGのBackend Serviceはtimeout_secをサポートしない。
  # リクエストのタイムアウトはCloud Run Service側の300秒設定で管理する。

  backend {
    group = google_compute_region_network_endpoint_group.api[0].id
  }

  log_config {
    enable      = true
    sample_rate = 1
  }
}

resource "google_compute_url_map" "api" {
  count = local.api_domain_enabled ? 1 : 0

  name            = "${var.resource_prefix}-api-url-map"
  default_service = google_compute_backend_service.api[0].id

  host_rule {
    hosts        = [var.api_domain]
    path_matcher = "api"
  }

  path_matcher {
    name            = "api"
    default_service = google_compute_backend_service.api[0].id
  }
}

resource "google_certificate_manager_dns_authorization" "api" {
  count = local.api_domain_enabled ? 1 : 0

  name        = "${var.resource_prefix}-api-dns-auth"
  description = "DNS authorization for the API custom domain"
  domain      = var.api_domain

  depends_on = [google_project_service.services["certificatemanager.googleapis.com"]]
}

resource "google_certificate_manager_certificate" "api" {
  count = local.api_domain_enabled ? 1 : 0

  name        = "${var.resource_prefix}-api-certificate"
  description = "Google-managed certificate for the API custom domain"

  managed {
    domains = [var.api_domain]
    dns_authorizations = [
      google_certificate_manager_dns_authorization.api[0].id,
    ]
  }
}

resource "google_certificate_manager_certificate_map" "api" {
  count = local.api_domain_enabled ? 1 : 0

  name        = "${var.resource_prefix}-api-certificate-map"
  description = "Certificate map for the API HTTPS load balancer"

  depends_on = [google_project_service.services["certificatemanager.googleapis.com"]]
}

resource "google_certificate_manager_certificate_map_entry" "api" {
  count = local.api_domain_enabled ? 1 : 0

  name         = "${var.resource_prefix}-api-certificate-map-entry"
  map          = google_certificate_manager_certificate_map.api[0].name
  hostname     = var.api_domain
  certificates = [google_certificate_manager_certificate.api[0].id]
}

resource "google_compute_ssl_policy" "api" {
  count = local.api_domain_enabled ? 1 : 0

  name            = "${var.resource_prefix}-api-tls-policy"
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"

  depends_on = [google_project_service.services["compute.googleapis.com"]]
}

resource "google_compute_target_https_proxy" "api" {
  count = local.api_domain_enabled ? 1 : 0

  name            = "${var.resource_prefix}-api-https-proxy"
  url_map         = google_compute_url_map.api[0].id
  certificate_map = "//certificatemanager.googleapis.com/${google_certificate_manager_certificate_map.api[0].id}"
  ssl_policy      = google_compute_ssl_policy.api[0].id
}

resource "google_compute_global_forwarding_rule" "api_https" {
  count = local.api_domain_enabled ? 1 : 0

  name                  = "${var.resource_prefix}-api-https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  network_tier          = "PREMIUM"
  ip_address            = google_compute_global_address.api[0].address
  port_range            = "443"
  target                = google_compute_target_https_proxy.api[0].id
}

resource "google_compute_url_map" "api_http_redirect" {
  count = local.api_domain_enabled ? 1 : 0

  name = "${var.resource_prefix}-api-http-redirect"

  default_url_redirect {
    https_redirect = true
    strip_query    = false
  }

  depends_on = [google_project_service.services["compute.googleapis.com"]]
}

resource "google_compute_target_http_proxy" "api_redirect" {
  count = local.api_domain_enabled ? 1 : 0

  name    = "${var.resource_prefix}-api-http-proxy"
  url_map = google_compute_url_map.api_http_redirect[0].id
}

resource "google_compute_global_forwarding_rule" "api_http" {
  count = local.api_domain_enabled ? 1 : 0

  name                  = "${var.resource_prefix}-api-http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  network_tier          = "PREMIUM"
  ip_address            = google_compute_global_address.api[0].address
  port_range            = "80"
  target                = google_compute_target_http_proxy.api_redirect[0].id
}
