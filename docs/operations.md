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

`db-f1-micro`では、API 1インスタンスあたり最大5接続、batchとmigrateは1タスクあたり
最大2接続に制限する。APIが最大3インスタンスまで増え、batchとmigrateが同時に動作しても
最大19接続とし、接続上限25のうち6接続を運用・監視用に残す。

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

再度planを確認し、Cloud Runのingress以外に意図しない差分がないことを確認してから
人間がapplyする。独自ドメインが引き続き応答し、インターネットからCloud RunのデフォルトURIへ
直接アクセスすると `404` 等で拒否されることを確認する。最後にTerraform planが
`No changes` になることを確認する。

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

## default VPCから本番専用VPCへのRedis移行

この移行は既存Redisの`authorized_network`を変更しない。`redis_network_migration_phase`を
`legacy`、`prepare`、`cutover`の順で進め、新Redisを並行作成してからCloud Runの接続先を切り替える。
エージェントはplanの提示までとし、各applyは人間がplanを確認した後に実行する。

| フェーズ | 追加・変更 | 想定影響 |
|---|---|---|
| `legacy` | 既存構成を維持 | なし |
| `prepare` | 専用VPC、`/26`以上のsubnet、firewall 2件、新Redis、専用SecretとIAMを追加 | 既存Cloud Runと旧Redisは変更しない。新Redisの追加費用が発生 |
| `cutover` | API Revisionとbatch Jobのnetwork interface、network tag、Secret参照を更新 | APIはrolling update。batchは定期実行と重ねない。空のcacheによる一時的なlatency上昇があり得る |

`prepare`以降に`legacy`へ戻すと、追加リソースの削除planになり`prevent_destroy`で停止する。
rollbackは必ず`prepare`へ戻す。旧Redis、旧Secret version、旧Revisionをrollback期間中に削除しない。

### Redisデータの扱い

現在のRedisデータは再生成可能なcacheとして扱い、RDBのexport/importは行わない。
Memorystoreのimportは新Redisを処理中に利用不能にし、失敗時には内容が消える可能性があるため、
cache移行ではリスクに見合わない。永続性が必要なkeyを将来追加した場合はこの手順を中止し、
データ所有者、整合点、RDB移送、停止時間、失敗時復旧を含む別の移行計画を作成する。

cutover後はcache missによる再取得を許容し、API latency、5xx、Redis memory、batch結果を監視する。
負荷の高いcache warmingを一括実行せず、通常リクエストと定期batchで段階的に再構築する。

### 1. 事前確認

ローカル設定とremote stateを使い、開始時のphase、旧Redis、API Revision、batch Job、
旧Redis Secretの数値versionを記録する。Secret値は取得・表示しない。

```bash
terraform -chdir=terraform/environments/prod output redis_network_migration_phase
gcloud redis instances describe <old-redis-name> --region <region> \
  --format='yaml(name,state,authorizedNetwork,host,port)'
gcloud run services describe backend --region <region> \
  --format='yaml(status.latestReadyRevisionName,status.traffic)'
gcloud run jobs describe batch --region <region> \
  --format='yaml(name,updateTime)'
gcloud secrets versions list REDIS_HOST --filter='state=ENABLED' --format='table(name,state)'
gcloud secrets versions list REDIS_PORT --filter='state=ENABLED' --format='table(name,state)'
gcloud secrets versions list REDIS_PASSWORD --filter='state=ENABLED' --format='table(name,state)'
```

同じ時間帯のbackendデプロイ、batch / migrateの手動実行、Secretローテーションを止める。
Cloud Schedulerの次回実行まで十分な時間があることを確認する。既存planが`No changes`でない場合は、
その差分を先に解消し、この移行と混在させない。backend CDがgcloudで更新した直後は、
Cloud Run Service / JobのAPI client識別用metadataである`client` / `client_version`だけを
Terraformが戻すin-place差分が出る場合がある。この2属性だけであることを実値なしで確認できた場合は
runtime設定の差分とは分けて記録し、他のCloud Run属性に差分がないことを確認する。
Cloud SQLとDB接続Secretはこの移行の対象外である。Cloud SQL、database、user、`DB_*` Secret、
migrate Jobに差分が出た場合は、その場で中止して影響を人間へ相談する。

### 2. prepare

ローカルの`terraform.tfvars`を次へ変更する。CIDRはDirect VPC egressの最小要件である`/26`以上とし、
既存のアドレス設計を確認して決める。実値をリポジトリへコミットしない。

```hcl
redis_network_migration_phase = "prepare"
cloud_run_subnet_cidr          = "10.10.0.0/26"
```

```bash
terraform -chdir=terraform/environments/prod init -backend-config=backend.hcl -reconfigure
terraform -chdir=terraform/environments/prod plan
```

planが次の追加だけであることを確認する。

- 本番専用custom-mode VPCとCloud Run用subnet
- Cloud Run tagから新RedisのTCP portを許可するegress ruleと、他のVPC向け通信を拒否するrule
- 旧Redisと別名の新Redis
- `REDIS_DEDICATED_*` Secret本体と数値version
- API / batchランタイムSAから上記Secretへのsecret単位のaccessor

事前確認で記録した`client` / `client_version`だけのmetadata driftが残っている場合は、
Cloud Run 2件のin-place更新が併記される。それ以外のCloud Run template差分があれば中止する。

既存Redis、上記metadata以外のCloud Run属性、既存`REDIS_*` version、`random_password`の更新や、
リソースの削除・再作成が1件でもあれば中止する。特に`must be replaced`または`forces replacement`が
あればapplyしない。
人間がapplyした後、新Redisが`READY`で専用VPCを参照し、firewallのallowがdenyより高い優先度で
専用network tagを対象としていることを確認する。Secretは値を表示せずversionの存在だけを確認する。

```bash
gcloud redis instances describe <new-redis-name> --region <region> \
  --format='yaml(name,state,authorizedNetwork,host,port)'
gcloud compute firewall-rules describe <allow-rule-name> \
  --format='yaml(network,direction,priority,destinationRanges,targetTags,allowed)'
gcloud compute firewall-rules describe <deny-rule-name> \
  --format='yaml(network,direction,priority,destinationRanges,targetTags,denied)'
gcloud secrets versions list REDIS_DEDICATED_HOST --filter='state=ENABLED' --format='table(name,state)'
gcloud secrets versions list REDIS_DEDICATED_PORT --filter='state=ENABLED' --format='table(name,state)'
gcloud secrets versions list REDIS_DEDICATED_PASSWORD --filter='state=ENABLED' --format='table(name,state)'
```

確認後に再度planし、`No changes`になるまでcutoverへ進まない。

### 3. cutover

サービスの一時停止を許容するメンテナンス時間を確保し、定期batchが実行中でない時間帯に、
ローカル設定を次へ変更する。Cloud Runは通常rolling updateになるが、無停止を前提にせず、
疎通確認が終わるまで利用者向けメンテナンスとして扱う。

```hcl
redis_network_migration_phase = "cutover"
```

planではAPI Serviceとbatch Jobのnetwork interface、network tag、Redis Secret参照だけが
in-place更新されることを確認する。事前に確認済みの場合は`client` / `client_version`のmetadata差分も
併記される。migrate Job、既存 / 新Redis、Secret version、IAM、
`random_password`に差分があってはいけない。削除・再作成があれば中止する。

人間がapplyした後、APIの新Revisionとbatch Jobが専用VPC / subnet / tag、および
`REDIS_DEDICATED_*`の数値versionを参照していることを確認する。Secret値は表示しない。

```bash
gcloud run services describe backend --region <region> \
  --format='yaml(spec.template.metadata.annotations,spec.template.spec.containers[0].env,status.latestReadyRevisionName,status.traffic)'
gcloud run jobs describe batch --region <region> \
  --format='yaml(spec.template.spec.template.metadata.annotations,spec.template.spec.template.spec.containers[0].env)'
curl -fsS https://<api-domain>/healthz
gcloud run jobs execute batch --region <region> --args=candles --wait
gcloud run services logs read backend --region <region> --limit 100
```

API health check、Redisを利用する通常リクエスト、candles Jobを確認し、Redis接続エラー、API 5xx、
p95 latency、Cloud Run instance起動失敗、Redis memory / connection数を監視する。
最後にremote stateでplanが`No changes`となることを確認する。これを満たした時点で
Cloud Runと稼働中Redisのdefault VPC依存は解消される。

### 4. rollback

次のいずれかがあれば、原因調査と並行して`redis_network_migration_phase = "prepare"`へ戻す。

- 新Revisionが起動しない、またはhealth checkが失敗する
- Redis接続エラーやAPI 5xxが継続する
- latencyやRedis負荷が許容範囲を超える
- batchがRedis接続を原因として失敗する

rollback planがAPI Serviceとbatch Jobのnetwork interface / Secret参照を旧構成へ戻すだけであり、
Redis、Secret version、`random_password`の更新や削除・再作成を含まないことを確認してから、
人間がapplyする。旧Revisionへtrafficを戻すだけではbatch JobとSecret参照が戻らないため、
Terraformのrollbackを省略しない。復旧後はAPI、通常リクエスト、batchを再確認し、新Redisは削除せず
原因調査用に保持する。

### 5. rollback期間終了後

十分な監視期間を置き、旧Redisへの接続がないことを確認する。旧Redis、旧`REDIS_*` Secret / IAM、
default VPCを削除する場合は、この移行と分離した単独の変更として移行手順・plan・rollback不能になる
時点を人間が確認する。`prevent_destroy`を外す変更や削除をこの手順の延長で実行しない。
bootstrapの`auto_create_network`は構築済みprojectの再作成を避けるため変更しない。

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
