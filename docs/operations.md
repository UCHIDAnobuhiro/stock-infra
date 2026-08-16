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
`cors_allowed_origins` には本番frontendのHTTPS originを末尾スラッシュなしで設定する。
`cookie_domain` にはfrontendとAPIで認証セッションCookieを共有する親ドメインを、
スキームや先頭ドットなしで設定する。
新規環境の初回applyでは `enable_cloud_run = false` にして、Secret Manager、WIF、
Artifact Registry等の前提基盤を先に作成する。`enable_api_domain` もこの段階では
`false` のままにする。

```bash
terraform -chdir=terraform/environments/prod init -backend-config=backend.hcl
terraform -chdir=terraform/environments/prod fmt -check
terraform -chdir=terraform/environments/prod validate
terraform -chdir=terraform/environments/prod plan
```

planに `must be replaced` や想定外のIAM変更がないことを確認し、人間がapplyする。

## 5. 外部credentialの投入

Terraformは外部APIキーとOAuth credentialのsecret本体だけを作成する。値はapply後にSecret Managerへ追加する。

```bash
gcloud secrets versions add TWELVE_DATA_API_KEY --data-file=-
```

コマンド実行後に標準入力から値を入力する。値をコマンド引数、ファイル、シェル履歴へ残さない。

### OAuthを有効化する場合

最初は `enable_oauth = false` のままapplyし、OAuth credential用のsecret本体を作成する。
作成後、Google/GitHubで発行した値を対応するsecretへ投入する。

```bash
gcloud secrets versions add GOOGLE_CLIENT_ID --data-file=-
gcloud secrets versions add GOOGLE_CLIENT_SECRET --data-file=-
gcloud secrets versions add GITHUB_CLIENT_ID --data-file=-
gcloud secrets versions add GITHUB_CLIENT_SECRET --data-file=-
```

各コマンドの実行後、値を貼り付けた直後にEnterを押さず `Ctrl-D` で入力を終了する。
4つすべてにversionが作成されたことを確認してから、`terraform.tfvars`へ次を設定する。

```hcl
enable_oauth                = true
oauth_frontend_redirect_url = "https://www.example.com"
```

再度planを実行し、Cloud Run APIへのOAuth環境変数・Secret参照と、APIランタイムSAへの
4つのSecret Manager accessor追加だけであることを確認してからapplyする。

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

再度Terraform planを確認して人間がapplyする。この段階ではAPIサービス1件、単一のbatch Job、
migrate Job 1件、Cloud Scheduler 2件（candles-daily、logo-weekly）と関連IAMが追加される。
初回作成後のイメージ更新はbackend CDが担当し、Terraformはイメージ差分を無視する。

通常のbackend CDは既存Cloud Runリソースのイメージだけを更新する。デプロイ後に
Terraform planを実行し、イメージとtraffic以外の差分がないことを確認する。

単一Jobのバッチ実行はbackendのbatch CDで `execute=true` と `job_id` を指定するか、次のように
実行時引数を上書きする。

```bash
gcloud run jobs execute batch \
  --region asia-northeast1 \
  --args=candles \
  --wait
```

candlesは毎日7:00 JST、logoは毎週日曜10:00 JSTにCloud Schedulerが自動実行する。上記の手動実行は
バックフィルや動作確認用であり、Cloud Schedulerの定期実行を妨げず、いつでも追加で実行できる。
定期実行の状態確認や単発トリガーには次を使う。

```bash
gcloud scheduler jobs describe candles-daily --location asia-northeast1
gcloud scheduler jobs run candles-daily --location asia-northeast1
gcloud run jobs executions list --job batch --region asia-northeast1
```

## 7. API独自ドメインの設定

Cloud Run APIがデフォルトURIで正常に応答することを確認してから、ローカルの
`terraform.tfvars` に次を設定する。実ドメインはexample、README、issueへ記載しない。

```hcl
enable_api_domain             = true
api_domain                    = "api.example.com"
restrict_api_to_load_balancer = false
```

初回は `restrict_api_to_load_balancer = false` を維持する。次を実行し、固定IP、
Serverless NEG、ロードバランサー、証明書だけが追加されることを確認する。

```bash
terraform -chdir=terraform/environments/prod plan
```

`must be replaced` や既存リソースの削除があれば中止する。人間がplanを確認してapplyした後、
DNS事業者へ登録する値を取得する。
途中のリソース作成が失敗した場合は作成済みリソースを手動削除せず、設定を修正して
再度planする。再作成や削除がなく、未作成分の追加だけであることを確認する。

```bash
terraform -chdir=terraform/environments/prod output -json api_dns_records
```

outputの `api` をAレコード、`certificate_authorization` をCNAMEレコードとして
DNS事業者へ登録する。DNS画面がホスト名のみを求める場合はゾーン名との重複を避ける。
同じAPIホスト名に旧CNAMEが残っている場合は、Aレコードと共存できないため旧CNAMEを削除する。
既存のMX、TXT、無関係なA/CNAMEレコードは変更しない。証明書認証用CNAMEは自動更新に
必要なため、証明書が発行された後も残す。

DNS反映と証明書発行後に次を確認する。

```bash
dig +short api.example.com A
dig +short <certificate-authorization-record> CNAME
gcloud certificate-manager certificates describe <resource-prefix>-api-certificate \
  --location=global \
  --project=<project-id> \
  --format='value(managed.state)'
curl -fsS https://api.example.com/healthz
curl -I http://api.example.com/healthz
```

CNAMEのホスト名は固定せず、`api_dns_records` の実際のoutputに合わせる。
証明書はDNS反映後もしばらく `PROVISIONING` になる。`ACTIVE` へ変わるまで
`restrict_api_to_load_balancer = false` を維持する。数時間経っても `ACTIVE` にならない場合は、
`managed.authorizationAttemptInfo` とCNAMEの公開DNS応答を確認する。HTTPSがhealth checkに成功し、
HTTPがHTTPSへリダイレクトされることを確認する。

疎通確認後に次へ変更する。

```hcl
restrict_api_to_load_balancer = true
```

再度planを確認し、Cloud Runのingress以外に意図しない差分がないことを確認してから
人間がapplyする。独自ドメインが引き続き応答し、インターネットからCloud RunのデフォルトURIへ
直接アクセスすると `404` 等で拒否されることを確認する。最後にTerraform planが
`No changes` になることを確認する。

Serverless NEGのBackend Serviceに `timeout_sec` を設定するとGCP APIが拒否する。
リクエストのタイムアウトはCloud Run Service側で管理し、Backend Serviceには設定しない。

切り替え後にロードバランサー経路の障害が発生した場合は、ロードバランサーやDNSを削除せず、
`restrict_api_to_load_balancer = false` へ戻すplanを確認して人間がapplyする。

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
