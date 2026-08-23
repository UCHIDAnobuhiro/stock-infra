mock_provider "google" {}

mock_provider "random" {}

variables {
  project_id        = "example-project-123"
  region            = "asia-northeast1"
  resource_prefix   = "stock"
  github_repository = "example/backend"

  manual_secret_versions = {
    TWELVE_DATA_API_KEY  = "1"
    GOOGLE_CLIENT_ID     = "1"
    GOOGLE_CLIENT_SECRET = "1"
    GITHUB_CLIENT_ID     = "1"
    GITHUB_CLIENT_SECRET = "1"
  }

  initial_api_image     = "asia-northeast1-docker.pkg.dev/example-project-123/stock-registry/backend:0123456789abcdef0123456789abcdef01234567"
  initial_batch_image   = "asia-northeast1-docker.pkg.dev/example-project-123/stock-registry/batch:0123456789abcdef0123456789abcdef01234567"
  initial_migrate_image = "asia-northeast1-docker.pkg.dev/example-project-123/stock-registry/migrate:0123456789abcdef0123456789abcdef01234567"

  cors_allowed_origins = ["https://www.example.com"]
  cookie_domain        = "example.com"
  enable_cloud_run     = false
}

run "accept_same_commit_sha" {
  command = plan
}

run "accept_digest_pinned_images" {
  command = plan

  variables {
    initial_api_image     = "asia-northeast1-docker.pkg.dev/example-project-123/stock-registry/backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    initial_batch_image   = "asia-northeast1-docker.pkg.dev/example-project-123/stock-registry/batch@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    initial_migrate_image = "asia-northeast1-docker.pkg.dev/example-project-123/stock-registry/migrate@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  }
}

run "reject_different_project" {
  command = plan

  variables {
    initial_api_image = "asia-northeast1-docker.pkg.dev/another-project-123/stock-registry/backend:0123456789abcdef0123456789abcdef01234567"
  }

  expect_failures = [var.initial_api_image]
}

run "reject_different_repository" {
  command = plan

  variables {
    initial_batch_image = "asia-northeast1-docker.pkg.dev/example-project-123/another-registry/batch:0123456789abcdef0123456789abcdef01234567"
  }

  expect_failures = [var.initial_batch_image]
}

run "reject_mutable_tag" {
  command = plan

  variables {
    initial_migrate_image = "asia-northeast1-docker.pkg.dev/example-project-123/stock-registry/migrate:latest"
  }

  expect_failures = [var.initial_migrate_image]
}

run "reject_different_commit_sha" {
  command = plan

  variables {
    initial_migrate_image = "asia-northeast1-docker.pkg.dev/example-project-123/stock-registry/migrate:89abcdef0123456789abcdef0123456789abcdef"
  }

  expect_failures = [var.initial_migrate_image]
}
