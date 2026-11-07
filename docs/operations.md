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
`region` にはCloud Run等のGCPリソース配置先、`vertex_ai_location` には使用するGeminiモデルの
対応ロケーションを指定する。現在のデフォルトは `global` とする。
`cors_allowed_origins` には本番frontendのHTTPS originを末尾スラッシュなしで設定する。
`cookie_domain` にはfrontendとAPIで認証セッションCookieを共有する親ドメインを、
スキームや先頭ドットなしで設定する。
`manual_secret_versions`には分類CのSecret値ではなく、Secret Managerに存在する数値versionだけを
設定する。OAuthを無効にしている間も5項目を省略せず、使用開始前に実際のversionへ合わせる。
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
作成されたversion番号を確認し、`terraform.tfvars`の`manual_secret_versions.TWELVE_DATA_API_KEY`へ
文字列で設定する。`latest`は指定しない。

```bash
gcloud secrets versions list TWELVE_DATA_API_KEY \
  --filter='state=ENABLED' \
  --sort-by='~createTime'
```

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
4つすべてにversionが作成されたことを確認し、それぞれの数値versionを
`manual_secret_versions`へ設定してから、`terraform.tfvars`へ次を設定する。

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

Cloud SQLはprivate IPだけで公開するため、初回イメージには`INSTANCE_CONNECTION_NAME`と
`DB_IP_TYPE=PRIVATE`でCloud SQL Go Connectorを使うbackendのcommitを使用する。
public IP前提の`/cloudsql` Unixソケットで接続するイメージではDBへ接続できない。

backendのAPI・batch・migrate CDを `publish_only=true` で実行する。GitHub ActionsのSummaryに
表示されたcommit SHA付きURIを `initial_api_image`、`initial_batch_image`、
`initial_migrate_image` へ設定し、`enable_cloud_run = true` へ変更する。3つのURIは同じ40文字の
commit SHAタグを使い、対象projectの `${resource_prefix}-registry` にある `backend`、`batch`、
`migrate` イメージを指定する。digestで固定する場合は3つすべてを `@sha256:<digest>` 形式にする。

再度Terraform planを確認して人間がapplyする。この段階ではAPIサービス1件、単一のbatch Job、
migrate Job 1件、Cloud Scheduler 3件（auth-session-cleanup-daily、candles-daily、logo-weekly）と
関連IAMが追加される。
初回作成後のイメージ更新はbackend CDが担当し、Terraformはイメージ差分を無視する。

通常のbackend CDは既存Cloud Runリソースのイメージだけを更新する。デプロイ後に
Terraform planを実行し、イメージとtraffic以外の差分がないことを確認する。

### Cloud SQL接続プールの確認

`db-f1-micro`では、API 1インスタンスあたり最大5接続、migrateは1タスクあたり最大2接続、
batchは1タスクあたり処理用1接続とadvisory lock専用1接続に制限する。
APIが最大3インスタンスまで増え、batch 1タスクとmigrate 1タスクが同時に動作しても
`5 × 3 + (1 + 1) + 2 = 19` 接続とし、接続上限25のうち6接続を運用・監視用に残す。
backendのlock専用プールは1接続固定であり、batchの`DB_MAX_OPEN_CONNS=1`は処理用プールだけに適用される。

適用前に実環境へ接続し、想定している接続上限と一致することを確認する。

```sql
SHOW max_connections;

SELECT application_name, state, count(*) AS connections
FROM pg_stat_activity
GROUP BY application_name, state
ORDER BY connections DESC;
```

`max_connections`が25でない場合やtierを変更する場合は、そのままapplyせず、
`terraform/environments/prod/sql.tf`の接続予算を実測値に合わせて見直す。
Terraform apply後は通常時とピーク時に同じクエリを実行し、Cloud SQLの接続数、
Cloud Run APIの5xxエラー率、batchとmigrateの実行結果を確認する。

Cloud Run Jobは複数Executionを同時に起動できる。同じ`job_id`のbatchはアプリケーション側の
PostgreSQL advisory lockで排他され、後続Executionは処理本体を実行せず終了コード0で完了する。
異なる`job_id`同士、およびbatchとmigrateの間は排他されない。バックフィルや手動migrateを行う際は、
異なる`job_id`のbatchやmigrateが実行中でないことを確認し、接続予算に含めていない同時実行を避ける。
重複をスキップするExecutionもlock判定中は一時的に1接続を使用するため、手動での大量起動は避ける。
backendのmigrate CDは固定concurrency groupでAPI CD経由と単独手動実行を直列化するが、
`gcloud`やConsoleからの直接実行、batch CDやSchedulerとは排他されない。
`queue: max`で待機実行を最大100件保持し、後続による待機中の取り消しを防ぐ。
上限超過や手動キャンセル時は実行履歴とDB状態を確認して必要な実行だけを再実行する。
dispatch順は保証されないため、`up`/`down`等の順序が必要な操作は前の完了後に起動する。

単一Jobのバッチ実行はbackendのbatch CDで `execute=true` と `job_id` を指定するか、次のように
実行時引数を上書きする。

```bash
gcloud run jobs execute batch \
  --region asia-northeast1 \
  --args=candles \
  --wait
```

auth-session-cleanupは毎日3:30 JST、candlesは毎日7:00 JST、logoは毎週日曜10:00 JSTに
Cloud Schedulerが自動実行する。上記の手動実行はバックフィルや動作確認用である。
同じ`job_id`の定期実行と重なった場合も新しいExecution自体は作成されるが、batchはlockを待たずに
`event=batch_skipped`、`reason=already_running`を記録して終了コード0で正常終了する。
待機キューにはならないため、先行Executionの完了後に実行する必要がある場合は、完了を確認してから
改めて1回だけ実行する。異なる`job_id`は並行実行できるため、外部APIとDB接続の使用量を確認する。
定期実行の状態確認や単発トリガーには次を使う。

```bash
gcloud scheduler jobs describe auth-session-cleanup-daily --location asia-northeast1
gcloud scheduler jobs run auth-session-cleanup-daily --location asia-northeast1
gcloud scheduler jobs describe candles-daily --location asia-northeast1
gcloud scheduler jobs run candles-daily --location asia-northeast1
gcloud run jobs executions list --job batch --region asia-northeast1
```

重複判定とlockエラーは構造化ログで確認する。

```bash
gcloud logging read \
  'resource.type="cloud_run_job" AND resource.labels.job_name="batch" AND (jsonPayload.event="batch_skipped" OR jsonPayload.event="batch_lock_failed")' \
  --freshness=24h \
  --limit=50
```

`batch_skipped`は同じ`job_id`の先行Executionが動作していることを示す正常系であり、再実行しない。
`batch_lock_failed`はDB接続やlockクエリの異常なので、該当Executionの終了コード、Cloud SQL接続数、
直前のエラーを確認する。

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

再度planを確認し、Cloud Runのingressと`TRUSTED_PROXY_HOPS`以外に意図しない差分がないことを確認してから
人間がapplyする。独自ドメインが引き続き応答し、インターネットからCloud RunのデフォルトURIへ
直接アクセスすると `404` 等で拒否されることを確認する。最後にTerraform planが
`No changes` になることを確認する。

`TRUSTED_PROXY_HOPS`はLB限定時に`2`、直接公開中（独自ドメインの移行期間を含む）は`1`とする。
[外部Application Load Balancerの仕様](https://cloud.google.com/load-balancing/docs/https#x-forwarded-for_header)では
X-Forwarded-For末尾に`client-ip,load-balancer-ip`が追加されるため、LB限定時は右から2番目を選ぶ。
直接公開中に`2`へ切り替えると、直接リクエストの偽装エントリを信頼するおそれがある。
移行期間のLB経由リクエストは末尾のLB IPで判定されるため、移行は疎通確認後に完了させる。
適用時には実際にコンテナが受信するXFFの末尾と解決したIPを確認し、異なる接続元や偽装XFFを
付けたリクエストでも期待したクライアントIPになることを確認する。追加プロキシがある場合や
内部ネットワークから直接アクセスする場合は、経路ごとの信頼境界を見直す。

Serverless NEGのBackend Serviceに `timeout_sec` を設定するとGCP APIが拒否する。
リクエストのタイムアウトはCloud Run Service側で管理し、Backend Serviceには設定しない。

切り替え後にロードバランサー経路の障害が発生した場合は、ロードバランサーやDNSを削除せず、
`restrict_api_to_load_balancer = false` へ戻すplanを確認して人間がapplyする。

## 8. 監視とSlack通知

### Slack通知チャネルを作成する

SlackのOAuth tokenを`terraform.tfvars`やTerraform stateへ保存しないため、通知チャネルは
Cloud MonitoringとSlackのOAuth連携を使ってGCP Consoleで作成する。

1. Cloud MonitoringのAlerting画面で`Edit notification channels`を開く。
2. Slackの`Add new`から対象workspaceを選び、Cloud Monitoringのアクセスを許可する。
3. 通知先channel名と表示名を設定する。private channelではSlack側で
   `/invite @Google Cloud Monitoring`を実行する。
4. `Send test notification`を実行し、対象channelにテスト通知が届いたことを確認する。
5. 作成したSlack通知チャネルのresource nameを取得する。

```bash
gcloud beta monitoring channels list \
  --filter='type=slack AND enabled=true' \
  --format='table(name,displayName)'
```

resource nameは`projects/<project-id>/notificationChannels/<channel-id>`形式である。
OAuth tokenやSlackのchannel URLは記録せず、resource nameだけをローカルの
`terraform.tfvars`へ設定する。

```hcl
slack_notification_channel_id = "projects/<project-id>/notificationChannels/<channel-id>"
```

`slack_notification_channel_id`が空でもalert policyは作成できるが、Slackへ通知されない。
本番への監視追加planは、必ず空でない実在するSlackチャネルIDを設定してから確認する。

### 監視設定を反映する

次の症状ベースの監視をTerraformで管理する。

| 対象 | 条件 | 通知ノイズの抑制 |
|---|---|---|
| Cloud SQLディスク | 使用率80%超 | 5分継続 |
| Cloud SQL接続数 | 全database合計20以上 | 5分継続 |
| Cloud Run API 5xx | 全requestに対する5xx率5%超 | 5分集計・5分継続 |
| Cloud Run APIレイテンシ | p95が2秒超 | 5分集計・5分継続 |
| Cloud Run Job | batchまたはmigrate Execution失敗 | 単発で検知 |
| Cloud Scheduler | AttemptFinishedがERROR | 単発で検知・通知は1時間に1回まで |
| API Uptime Check | 2拠点以上で`/healthz`失敗 | 2分継続 |

remote stateとローカル設定を使ってplanし、Uptime Check 1件とalert policy 7件の追加、
各policyの`notification_channels`にSlackチャネルIDが設定されることを確認する。

```bash
terraform -chdir=terraform/environments/prod init -backend-config=backend.hcl -reconfigure
terraform -chdir=terraform/environments/prod plan
```

既存リソースの更新・削除・再作成、`random_password`やSecret versionの変更があれば中止する。
人間がplanを確認してapplyした後、Cloud MonitoringのAlerting画面でpolicyが有効であり、
Slack通知チャネルが設定されていることを確認する。`terraform apply`はエージェントに実行させない。

### アラート発生時の一次対応

通知を受けたら、最初にCloud Monitoringのincidentを開き、発生時刻、対象resource、
condition、直前のデプロイ・手動Job実行の有無を記録する。復旧確認前にincidentを閉じず、
同じ操作を連続実行しない。

#### Cloud SQLディスク使用率

1. MonitoringのMetrics Explorerで`database/disk/utilization`の推移と増加速度を確認する。
2. 大量投入中のbatchや手動処理があれば、新しい実行を止める。実行中処理の強制終了は影響を確認する。
3. 不要データ削除、保持期間変更、disk拡張のどれを行うかを単独の変更として計画する。
4. `disk_autoresize`や`disk_size`の変更はplanを確認し、Cloud SQL再作成が出た場合は中止する。

#### Cloud SQL接続数

1. 重複したCloud Run Job ExecutionとAPIインスタンス数を確認する。
2. `pg_stat_activity`をapplication、state別に集計し、接続リークや長時間transactionを特定する。
3. 新しいbatch・migrate実行を止め、原因のRevisionまたは処理を特定する。
4. 接続上限やpool設定を変える場合は、`SHOW max_connections`の実測と接続予算を同時に更新する。

#### Cloud Run APIの5xx率

```bash
gcloud run services logs read backend \
  --region <region> \
  --limit 100
```

直近Revisionの例外、Cloud SQL・Redis接続エラー、外部APIエラーを確認する。
直近デプロイが原因ならbackend CDの既存手順で正常なイメージへ戻し、Terraformから
imageやtrafficを変更しない。

#### Cloud Run APIのレイテンシ

Metrics Explorerで`request_latencies`をresponse code別に確認し、Cloud Runのinstance数、
Cloud SQL接続数、遅いquery、外部API待ちを切り分ける。timeoutや最大instance数の変更は
原因を特定した後に単独のTerraform変更としてplanする。

#### Cloud Run Job失敗

```bash
gcloud run jobs executions list --job batch --region <region>
gcloud run jobs executions list --job migrate --region <region>
```

失敗したExecutionのログ、終了コード、実行引数、retry回数を確認する。入力データや外部APIが
原因の場合は復旧を確認してから1回だけ再実行する。migrate失敗ではDB schemaを確認し、
原因を確認せずに再実行や逆migrationを行わない。

#### Cloud Scheduler実行失敗

```bash
gcloud logging read \
  'resource.type="cloud_scheduler_job" AND jsonPayload."@type"="type.googleapis.com/google.cloud.scheduler.logging.AttemptFinished" AND severity>=ERROR' \
  --freshness=24h \
  --limit=50
```

`job_id`、status、HTTP応答を確認する。401/403ではscheduler SAと対象Jobの
`roles/run.jobsExecutorWithOverrides`、5xx/timeoutではCloud Run Admin APIと対象Jobの状態を確認する。
Schedulerのretryが複数Executionを作成しても、同じ`job_id`の後続処理はbatch側で安全に終了する。
HTTP失敗を補うための手動実行は、SchedulerとCloud Run Jobの実行状況、および`batch_skipped` /
`batch_lock_failed`ログを確認してから1回だけ行う。

#### API Uptime Check失敗

```bash
curl -fsS https://<api-domain>/healthz
gcloud certificate-manager certificates describe <resource-prefix>-api-certificate \
  --location=global \
  --format='value(managed.state)'
gcloud run services describe backend --region <region>
```

公開DNS、証明書、ロードバランサー、Cloud Run Revision、Cloud SQL・Redisの順に切り分ける。
ロードバランサー経路だけの障害で緊急回避が必要な場合は、既存の手順どおり
`restrict_api_to_load_balancer = false`へ戻すplanを人間が確認してapplyする。

### 通知されない場合

Slack通知チャネルがenabledであり、policyの`notification_channels`に同じresource nameが
設定されていることを確認する。private channelでは`@Google Cloud Monitoring`が参加していること、
GCP Consoleのテスト通知が届くことを再確認する。OAuth tokenを取得してTerraformへ移さない。

## 9. 予算とコスト通知

### 前提

- planとapplyを実行する人間に、Billing Accountの`roles/billing.costsManager`以上の権限が必要
- 予算APIはユーザー認証で呼び出すとquota projectを要求するため、ADCへ本プロジェクトを設定する

```bash
gcloud auth application-default set-quota-project <project-id>
```

- 「8. 監視とSlack通知」のSlack通知チャネルを設定済みであること

### 予算を有効にする

ローカルの`terraform.tfvars`へ次を設定する。Billing Account IDは`.tf`やドキュメントへ書かない。
通貨はBilling Accountの通貨と一致させる。

```hcl
enable_billing_budget = true
billing_account_id    = "<billing-account-id>"
monthly_budget_amount = 20000
budget_currency_code  = "JPY"
```

remote stateとローカル設定でplanし、次の追加だけであることを確認する。

| 区分 | 件数 | 内容 |
|---|---|---|
| API | 5 | `billingbudgets`、`eventarc`、`pubsub`、`storage`、`workflows`。`storage`はbootstrapで有効化済みのためno-opで取り込まれる |
| 予算と通知 | 13 | 予算、Pub/Sub topicと発行権限、通知済み印バケット、SA 2つとIAM 3つ、Workflows、Eventarcトリガー、alert policy 2つ |

既存リソースの更新・削除・再作成があれば中止する。`enable_billing_budget = false`のままでもAPI 5件の追加は出る。

### 疎通を確認する

apply後、本物の対象月と衝突しない`costIntervalStart`でテストメッセージを発行する。

```bash
gcloud pubsub topics publish <resource-prefix>-budget-alerts \
  --attribute=budgetId=manual-test \
  --message='{"budgetDisplayName":"manual test","costAmount":10000,"costIntervalStart":"manual-test-1","budgetAmount":20000,"budgetAmountType":"SPECIFIED_AMOUNT","alertThresholdExceeded":0.5,"currencyCode":"JPY"}'
```

1. Workflowsの`<resource-prefix>-budget-notifier`に成功したExecutionがあること
2. Slackへ「Budget actual spend exceeded threshold」が届くこと
3. 同じメッセージを再発行してもSlackへ再通知されないこと

確認後、テスト用の通知済み印を削除する。

```bash
gcloud storage rm "gs://<project-id>-budget-alert-state/manual-test-1/**"
```

初回の本物の予算通知はapplyから数時間後に届く。

### 予算超過の通知

1. BillingのレポートをサービスとSKU別に表示し、増えた費目と開始日を特定する。
2. Cloud Runのインスタンス数とリクエスト数、batch Jobの実行回数、Vertex AI・Vision APIの呼び出しを確認する。
3. 直近のデプロイや手動実行が原因なら、その処理を止めてから対策を単独の変更として計画する。
4. 予測額の通知は月末時点の見込みである。実績額の推移と合わせて判断する。

予算は課金を止めない。費用データには数時間の遅れがあり、通知時点の金額は確定値ではない。

### 予算通知が届かない場合

1. Workflowsに予算通知のExecutionがあるか確認する。ない場合はEventarcトリガー、Pub/Sub topicの
   `billing-budget-alert@system.gserviceaccount.com`の発行権限、予算の`all_updates_rule`を確認する。
2. Executionが失敗している場合はエラーを確認する。GCSの403は通知済み印バケットのIAM、ログ書き込み失敗はWorkflows SAの`roles/logging.logWriter`を確認する。
3. Executionが`already_notified`を返す場合は、その月・しきい値を通知済みである。
4. ログは出ているのにSlackへ届かない場合は「通知されない場合」を確認する。Billing Account管理者へのメール通知は別経路で届く。

## 本番専用VPCとCloud SQL・Redisの運用

Cloud Run API・batch Job・migrate Jobは本番専用custom-mode VPCの専用subnetからDirect VPC egressを使う。
Cloud SQLとRedisはPrivate Service Accessの予約レンジ（`private_service_access_cidr`）でVPCへ接続し、
Cloud SQLはpublic IPを持たない。Redis接続情報は`REDIS_*`の数値versionを参照する。
エージェントはplanの提示までとし、各applyと実環境の削除は人間がplanと依存関係を確認した後に実行する。

`private_service_access_cidr`はCloud Run subnet・調査VM subnetと重複させない。Cloud SQLの
`private_network`は一度設定すると外せず、予約レンジを使用中のインスタンスがある間はレンジや
peeringを縮小・削除できない。レンジを変える場合は通常変更に混ぜず、独立した計画を作成する。

### Cloud SQLの内容を確認する

Cloud SQLはpublic IPを持たないため、ローカル端末から`psql`等で直接接続しない。GCP Consoleの
Cloud SQL Studioから対象インスタンスとdatabaseを選び、組み込みユーザーで認証する。
ユーザー名とパスワードはTerraformが固定している数値versionの`DB_USER`・`DB_PASSWORD`から取得し、
shell history、ファイル、issueへ残さない。

```bash
DB_PASSWORD_VERSION="$(terraform -chdir=terraform/environments/prod output -raw db_password_secret_version)"
gcloud secrets versions access "$DB_PASSWORD_VERSION" --secret=DB_PASSWORD
```

Cloud SQL Studioの利用者には対象projectでCloud SQL Studioを使うためのIAMロールを個別に付与し、
この構成から広いIAMを追加しない。調査では`SELECT`等の読み取りクエリを基本とし、データ修正は
migrationとして別途レビューする。

### Memorystoreの内容を調査する

調査VMは同じ本番専用VPCの専用`/29` subnetへ配置する`e2-micro`で、外部IPと
サービスアカウントを持たない。SSHはIAP TCP forwardingとOS Loginに限定し、egressは
稼働中MemorystoreのTCP portだけを許可する。Terraformが配置する`memorystore-inspect`は
読み取りコマンドのallowlistを持ち、`SET`、`DEL`、`KEYS`等を受け付けない。

apply前の全体planでは、IAP API、調査VM、専用subnet、Firewall 3件のcreateだけであることを確認する。
Cloud SQL、Redis、Cloud Run、Secret version、`random_password`のupdate・delete・replaceが
含まれる場合は中止する。applyは人間が最新planを確認した後に実行する。

接続する利用者には`roles/iap.tunnelResourceAccessor`と`roles/compute.osLogin`、sudoが必要な場合だけ
`roles/compute.osAdminLogin`が必要である。gcloudから接続する利用者は`compute.projects.get`も必要になる。
権限は対象者へ個別に付与し、この構成から広いIAMを追加しない。

ローカル端末でVM名とzoneを取得し、IAP経由で接続する。

```bash
VM_NAME="$(terraform -chdir=terraform/environments/prod output -raw memorystore_inspector_vm_name)"
VM_ZONE="$(terraform -chdir=terraform/environments/prod output -raw memorystore_inspector_vm_zone)"
gcloud compute ssh "$VM_NAME" --zone "$VM_ZONE" --tunnel-through-iap
```

別の信頼できるローカル端末で、Terraformが固定している数値versionのAUTH stringを取得する。
値をコマンドライン引数、shell history、ファイルへ保存しない。VM上の非表示promptへ貼り付ける。

```bash
REDIS_AUTH_VERSION="$(terraform -chdir=terraform/environments/prod output -raw redis_auth_secret_version)"
gcloud secrets versions access "$REDIS_AUTH_VERSION" --secret=REDIS_PASSWORD
```

VM上では最初に疎通とkeyspaceを確認し、全keyを一度に走査する`KEYS`ではなく`SCAN`を使う。
複数コマンドを実行する場合はAUTH stringを環境変数へ一時保持し、終了時に必ず解除する。

```bash
read -rs REDISCLI_AUTH
export REDISCLI_AUTH

memorystore-inspect PING
memorystore-inspect INFO keyspace
memorystore-inspect DBSIZE
memorystore-inspect SCAN 0 MATCH '*' COUNT 100
memorystore-inspect TYPE '<key>'
memorystore-inspect GET '<string-key>'
memorystore-inspect HGETALL '<hash-key>'

unset REDISCLI_AUTH
```

調査後はSSH sessionとAUTH stringを破棄し、VMを残す必要性を見直す。停止・削除は本変更のapplyへ
混ぜず、対象VMと専用subnet・Firewallだけに限定された別のplanを人間が確認して実施する。

## Secret versionの固定とローテーション

Cloud Run Service / JobsのSecret参照はすべて数値versionへ固定する。分類A/BはTerraform管理の
Secret versionを参照し、分類Cは`manual_secret_versions`で参照先を選ぶ。旧versionはrollback期間が
終わるまで有効なまま残し、新旧versionを同時に`latest`で配布しない。

### 既存環境を`latest`から移行する

1. 分類Cの各Secretで現在使用している有効なversion番号を確認し、ローカルの
   `terraform.tfvars`に設定する。値そのものは取得・記録しない。
2. `terraform plan`を実行する。分類A/BのSecretデータと`random_password`に変更がなく、
   Secret versionの削除ポリシー変更と、Cloud Run Service / Jobsの参照が`latest`から現在の
   数値versionへ変わるだけであることを確認する。
3. `must be replaced`、Secret versionの追加、`random_password`・Cloud SQL・Redisの変更、
   リソースの削除が1件でもあれば移行を中止する。
4. 人間がplanを確認してapplyした後、APIの新Revisionとbatch / migrate Job定義が意図した
   数値versionを参照していることを確認する。Secret値は表示しない。
5. APIのhealth check、認証、DB・Redis接続を確認し、batchとmigrateを安全なタイミングで
   1回ずつ実行する。APIのtrafficが新Revisionへ切り替わっていなければ、backend CDの
   traffic切り替え手順を使う。

```bash
gcloud run services describe backend --region <region> \
  --format='yaml(spec.template.spec.containers[0].env)'
gcloud run services describe backend --region <region> \
  --format='yaml(status.traffic,status.latestReadyRevisionName)'
gcloud run jobs describe batch --region <region> \
  --format='yaml(spec.template.spec.template.spec.containers[0].env)'
gcloud run jobs describe migrate --region <region> \
  --format='yaml(spec.template.spec.template.spec.containers[0].env)'
```

### 共通のローテーション手順

ローテーションはSecretの種類ごとに単独の変更として行い、Redis等の移行や通常のデプロイと
同時に実施しない。開始前に現在の数値version、API Revision、Job定義、依存リソースの状態を
記録し、旧versionを無効化しない。

1. 新しいSecret versionを作成する。分類Cは標準入力から手動投入し、分類A/Bは承認済みの
   元データ変更によってTerraformに作成させる。
2. DBパスワードやRedis接続情報では、依存リソースの切り替え順序、停止時間、復旧手順を
   個別のplanと手順書で確認する。再作成を含むplanは通常変更としてapplyしない。
3. 分類Cは`manual_secret_versions`を新versionへ更新する。分類A/Bは新しく作成される
   `google_secret_manager_secret_version.managed[*].version`が自動的に参照される。
4. planで対象のSecret version、依存リソース、Cloud Runテンプレート以外に差分がないことを
   確認し、人間がapplyする。Terraformは分類A/Bの旧versionをSecret Managerに残す。
5. APIの新Revisionへtrafficが切り替わったこと、health check・認証・DB・Redis接続、対象Jobの
   Executionを確認する。監視期間が終了するまで旧versionと旧Revisionを残す。
6. 問題があれば分類Cは`manual_secret_versions`を旧番号へ戻す。分類A/Bは依存リソースを旧値へ
   戻したうえで、`managed_secret_version_overrides`に旧番号を一時設定する。planを確認して
   applyし、API trafficとJob定義が旧versionへ戻ったことを確認する。
7. 復旧後は原因を解消して新versionを発行し直し、正常化を確認してからoverrideを削除する。
   rollback期間の終了後、不要なversionの無効化・破棄は人間が別作業として実施する。

`managed_secret_version_overrides`は緊急rollback専用である。依存リソースを戻さずに接続情報だけを
旧versionへ戻してはいけない。また、恒久設定として残さない。

### Secret別の注意事項

- `TWELVE_DATA_API_KEY`とOAuth credentialは、新version追加、`manual_secret_versions`更新、
  APIまたはbatchの動作確認の順に切り替える。rollbackは旧version番号へ戻す。
- `JWT_SECRET`の変更では発行済みトークンが無効になる。強制再ログインとメンテナンス時間を
  事前告知し、即時rollbackは旧Secretを参照するAPI Revisionへtrafficを戻す。
- `PASSWORD_PEPPER`を変更すると既存のパスワードハッシュを検証できない。複数pepper対応や
  パスワード再設定計画がない限りローテーションしない。誤変更時は直ちに旧Revisionへ戻す。
- `DB_PASSWORD`は単一DBユーザーのパスワードと同時に切り替わるため、無停止の新旧併用はできない。
  専用のメンテナンス変更として扱い、旧パスワードへ戻す手段を確認してから実施する。
- Redis接続情報はRedis再作成と分離できない場合がある。再作成を示すplanでは停止し、データ消失、
  接続先変更、API / Job再デプロイ、旧インスタンスへの切り戻しを含む単独の移行手順を作成する。

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
