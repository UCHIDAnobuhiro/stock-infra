# セキュリティ方針

## 公開情報の分類

| 分類 | 例 | 保存先 |
|---|---|---|
| 公開可能 | Terraformコード、Provider制約、設計判断、架空値のexample | Gitリポジトリ |
| 環境固有 | GCPプロジェクトID、Billing Account、Organization / Folder ID、stateバケット名、許可するGitHubリポジトリ | `.gitignore` 対象のローカル設定 |
| 秘密情報 | APIキー、パスワード、秘密鍵、サービスアカウントJSON、tfstate | Secret Managerまたは保護されたstate |

GCPプロジェクトID等は認証情報ではないが、公開リポジトリから実環境を分離し、誤操作を防ぐためローカル設定として扱う。

## Terraform state

Terraformが生成・導出するシークレットはstateに平文で保存される。stateバケットでは次を必須とする。

- Public Access Preventionを強制
- Uniform bucket-level accessを有効化
- オブジェクトバージョニングを有効化
- `force_destroy = false`
- Terraformの `prevent_destroy`
- stateを操作できる主体を必要最小限に限定

stateファイルをGit、チャット、issue、CIログへ貼り付けない。

## シークレットの分類

| 分類 | 例 | 管理方法 |
|---|---|---|
| A: 生成値 | JWT署名鍵、password pepper、DBパスワード | Terraformで生成しSecret Managerへ保存 |
| B: 導出値 | DB接続名、Redis接続情報 | Terraformリソースから導出しSecret Managerへ保存 |
| C: 外部値 | 外部APIキー、OAuth Client ID / Client Secret | secret本体のみTerraformで作り、値は人間が手動投入 |

分類Cの値は `.tf`、`.tfvars`、シェル履歴へ残さない入力方法を使用する。

Cloud Run Service / Jobsは`latest`を参照せず、すべて数値versionへ固定する。分類A/Bは
Terraformが管理する`google_secret_manager_secret_version`のversionを参照し、分類Cは
ローカルの`terraform.tfvars`にversion番号だけを記録する。分類A/Bのversion更新では
`deletion_policy = "ABANDON"`により旧versionを残し、動作確認とrollback期間の終了後に
人間が無効化・破棄を判断する。

## IAM

- API、バッチ、マイグレーション、デプロイ、Cloud Scheduler呼び出しでサービスアカウントを分離する
- Secret Manager accessorはsecret単位で付与する
- Artifact Registry writerはrepository単位で付与する
- `serviceAccountUser` は対象サービスアカウント単位で付与する
- ランタイムサービスアカウントへデプロイ権限を付与しない
- デプロイ用サービスアカウントのCloud Run Developerは各Service / Job単位で付与し、プロジェクト全体のCloud Run Adminは付与しない
- Cloud SchedulerのJob起動SAには対象Job単位で最小限のCloud Run固有ロール（`roles/run.jobsExecutor`系）のみ付与し、
  上書き実行が必要なJobにのみ `run.jobs.runWithOverrides` を含むロールを与える。`roles/run.developer` のような
  Job定義自体を変更できるロールは与えない
- 予算通知のWorkflows SAには、通知済み印バケットへの`roles/storage.objectCreator`（作成のみ）とログ書き込みだけを付与する。
  Eventarcトリガー専用SAには`roles/workflows.invoker`だけを付与する。Workflowsにはworkflow単位のIAMがないため、この2つはプロジェクト単位になる
- 予算のPub/Sub topicへの発行権限は、Cloud Billingのシステムアカウント`billing-budget-alert@system.gserviceaccount.com`にtopic単位で付与する

## ネットワーク境界

- Cloud Run API / batch / migrateはdefault VPCではなく本番専用custom-mode VPCを使用する
- Cloud SQLはpublic IPと承認ネットワークを持たず、Private Service Access経由のprivate IPだけで公開する
- Cloud SQLは`ENCRYPTED_ONLY`で平文接続を拒否し、backendはCloud SQL Go ConnectorのmTLSとIAM認可を経由する
- Direct VPC egressのnetwork tagをegress firewallの対象にし、Cloud SQLの3307とRedisのTCP portだけを各private IPの`/32`宛てに許可する
- tag対象の他のVPC向け通信はdeny ruleで拒否し、専用VPCに将来リソースを追加しても暗黙に到達させない
- Memorystore調査VMは外部IPとサービスアカウントを持たず、IAPからのSSHとRedis宛てegressだけを許可する
- 調査VMはOS Loginを使い、AUTH stringをinstance metadata、startup script、Terraform stateへ複製しない
- 調査用クライアントは読み取りコマンドのallowlistを持ち、本番Redisへの書き込み操作を受け付けない
- Direct VPC egressで未サポートのfirewall loggingには依存せず、Cloud RunとRedisのメトリクス・アプリログで疎通を監視する
- Redis SecretのaccessorはAPI / batchだけに付与し、migrateには付与しない

## Workload Identity Federation

GitHub Actionsからの認証はOIDCを使用し、サービスアカウントキーを発行しない。Providerのconditionで `repository` と `ref` の両方を検証する。許可対象を変更した場合は、CDワークフローと同時に見直す。

## 公開前チェック

1. `terraform.tfvars`、`backend.hcl`、state、planが含まれていないこと
2. APIキー、秘密鍵、トークン形式の文字列がないこと
3. 実際のプロジェクトID、バケット名、課金・組織情報がないこと
4. exampleが架空値だけで構成されていること
5. Git履歴にも秘密情報がないこと
