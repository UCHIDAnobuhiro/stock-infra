# 段階移行でcount付きにした稼働中リソースを定常addressへ移す。
# moved blockによりGCP上の実体は更新・再作成しない。
moved {
  from = google_compute_network.prod[0]
  to   = google_compute_network.prod
}

moved {
  from = google_compute_subnetwork.cloud_run[0]
  to   = google_compute_subnetwork.cloud_run
}

moved {
  from = google_compute_firewall.cloud_run_allow_redis_egress[0]
  to   = google_compute_firewall.cloud_run_allow_redis_egress
}

moved {
  from = google_compute_firewall.cloud_run_deny_other_egress[0]
  to   = google_compute_firewall.cloud_run_deny_other_egress
}

moved {
  from = google_redis_instance.dedicated[0]
  to   = google_redis_instance.prod
}

# 旧REDIS_*だけをprevent_destroy付きmanaged resourceから削除専用resourceへ移す。
# targetのfor_eachは空のため、この3件だけがdestroy planになり、DB・認証・
# 稼働中RedisのSecretは引き続きgoogle_secret_manager_secret.managedで保護される。
moved {
  from = google_secret_manager_secret.managed["REDIS_HOST"]
  to   = google_secret_manager_secret.retired_redis["REDIS_HOST"]
}

moved {
  from = google_secret_manager_secret.managed["REDIS_PORT"]
  to   = google_secret_manager_secret.retired_redis["REDIS_PORT"]
}

moved {
  from = google_secret_manager_secret.managed["REDIS_PASSWORD"]
  to   = google_secret_manager_secret.retired_redis["REDIS_PASSWORD"]
}

moved {
  from = google_secret_manager_secret_version.managed["REDIS_HOST"]
  to   = google_secret_manager_secret_version.retired_redis["REDIS_HOST"]
}

moved {
  from = google_secret_manager_secret_version.managed["REDIS_PORT"]
  to   = google_secret_manager_secret_version.retired_redis["REDIS_PORT"]
}

moved {
  from = google_secret_manager_secret_version.managed["REDIS_PASSWORD"]
  to   = google_secret_manager_secret_version.retired_redis["REDIS_PASSWORD"]
}
