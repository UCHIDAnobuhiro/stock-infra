# 運用手順

この文書は人間の作業者向けである。`terraform apply` は必ずplanを確認した後に実行する。

## 前提

- Terraform 1.9以上
- Google Cloud CLI
- プロジェクト作成と課金アカウント関連付けに必要なGCP権限
- GitHub CLI（CD用のRepository Secretsを設定する場合）

## 1. GCP認証

```bash
gcloud auth login
gcloud auth application-default login
```

bootstrapを実行する主体には、プロジェクト作成・課金関連付け・バケット作成に必要な権限が必要になる。

## 2. bootstrap設定

```bash
cp terraform/bootstrap/terraform.tfvars.example terraform/bootstrap/terraform.tfvars
```

`terraform.tfvars` に新しいプロジェクトID、プロジェクト名、Billing Account ID、リージョン、stateバケット名を設定する。このファイルはコミットしない。

```bash
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap fmt -check
terraform -chdir=terraform/bootstrap validate
terraform -chdir=terraform/bootstrap plan
```

planでプロジェクトとstateバケット以外の意図しない操作がないことを確認し、人間がapplyする。

## 3. bootstrap stateの移行

stateバケット作成後、bootstrap自身のローカルstateをGCSへ移す。

```bash
cp terraform/bootstrap/backend.local.tf.example terraform/bootstrap/backend.local.tf
cp terraform/bootstrap/backend.hcl.example terraform/bootstrap/backend.hcl
```

`backend.hcl` に作成済みバケット名を設定し、次を実行する。

```bash
terraform -chdir=terraform/bootstrap init -migrate-state -backend-config=backend.hcl
```

移行結果を確認するまでローカルstateを手動削除しない。

## 4. 本番基盤の設定

```bash
cp terraform/environments/prod/terraform.tfvars.example terraform/environments/prod/terraform.tfvars
cp terraform/environments/prod/backend.hcl.example terraform/environments/prod/backend.hcl
```

両ファイルへ実値を設定する。GitHubリポジトリは `owner/repo`、Git refは `refs/heads/main` のように指定する。
`cors_allowed_origins` には本番frontendのHTTPS originを設定する。
新規環境の初回applyでは `enable_cloud_run = false` にして、Secret Manager、WIF、
Artifact Registry等の前提基盤を先に作成する。

```bash
terraform -chdir=terraform/environments/prod init -backend-config=backend.hcl
terraform -chdir=terraform/environments/prod fmt -check
terraform -chdir=terraform/environments/prod validate
terraform -chdir=terraform/environments/prod plan
```

planに `must be replaced` や想定外のIAM変更がないことを確認し、人間がapplyする。

## 5. 外部APIキーの投入

Terraformは外部APIキーのsecret本体だけを作成する。値はapply後にSecret Managerへ追加する。

```bash
gcloud secrets versions add TWELVE_DATA_API_KEY --data-file=-
```

コマンド実行後に標準入力から値を入力する。値をコマンド引数、ファイル、シェル履歴へ残さない。

## 6. CD設定

`terraform/environments/prod` のoutputから、GitHub Actionsで必要な値を取得する。

```bash
terraform -chdir=terraform/environments/prod output
```

WIF Provider、デプロイ用サービスアカウント、GCPプロジェクトIDを対象リポジトリの
Repository SecretsまたはVariablesへ設定する。Cloud SQL接続名やランタイムSAはbackend CDへ渡さない。
実値をREADMEやissueへ貼り付けない。

backendのAPI・batch・migrate CDを `publish_only=true` で実行する。GitHub ActionsのSummaryに
表示されたcommit SHA付きURIを `initial_api_image`、`initial_batch_image`、
`initial_migrate_image` へ設定し、`enable_cloud_run = true` へ変更する。

新規環境では `retain_legacy_batch_jobs = false` にしたうえで、再度Terraform planを確認して
人間がapplyする。この段階ではAPIサービス1件、単一のbatch Job、migrate Job 1件と関連IAMが
追加される。初回作成後のイメージ更新はbackend CDが担当し、
Terraformはイメージ差分を無視する。

通常のbackend CDは既存Cloud Runリソースのイメージだけを更新する。デプロイ後に
Terraform planを実行し、イメージとtraffic以外の差分がないことを確認する。

## 旧バッチJobsから単一Jobへの移行

`candles`、`logo`、`auth-session-cleanup` の3 Jobsが既にTerraform stateへ登録されている環境は、
削除保護を安全に解除するため2段階で移行する。

1. `retain_legacy_batch_jobs = true` のままplanし、新しい `batch` Jobの追加と旧3 Jobsの
   `deletion_protection = false` への変更だけであることを確認して、人間がapplyする
2. backendのbatch CDを `publish_only=false`、`execute=false` で実行し、単一 `batch` Jobの
   イメージを更新する
3. `retain_legacy_batch_jobs = false` に変更してplanし、削除対象が旧3 JobsとそのIAMだけである
   ことを確認して、人間がapplyする
4. `terraform output legacy_batch_job_names` が空であることを確認する

単一Jobのバッチ実行はbackendのbatch CDで `execute=true` と `job_id` を指定するか、次のように
実行時引数を上書きする。

```bash
gcloud run jobs execute batch \
  --region asia-northeast1 \
  --args=candles \
  --wait
```

## 日常の変更

1. `terraform fmt -recursive`
2. 対象rootで `terraform validate`
3. `terraform plan` を保存せずに確認
4. 再作成、IAM拡大、シークレット再生成があれば中止
5. 人間の承認後にapply

## 禁止事項

- 自動化エージェントによるapply
- `terraform destroy`
- plan未確認でのapply
- `random_password` の不用意な変更や `-replace`
- state、plan、認証情報のGitへの追加
