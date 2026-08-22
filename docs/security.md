# セキュリティ方針

## 公開情報の分類

| 分類 | 例 | 保存先 |
|---|---|---|
| 公開可能 | Terraformコード、Provider制約、設計判断、架空値のexample | Gitリポジトリ |
| 環境固有 | GCPプロジェクトID、Billing Account、Organization / Folder ID、stateバケット名、許可するGitHubの数値ID・workflow | `.gitignore` 対象のローカル設定 |
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

## Workload Identity Federation

GitHub Actionsからの認証はOIDCを使用し、サービスアカウントキーを発行しない。
Providerのconditionでは、再利用されない `repository_id` と `repository_owner_id`、
`refs/heads/main`、許可したCD workflowの `workflow_ref` をすべて検証する。
サービスアカウントの `roles/iam.workloadIdentityUser` は、名前ではなく
`attribute.repository_id` のprincipalSetへ付与する。`google.subject` にも数値repository IDを使用する。

`workflow_ref` はworkflowファイルのパスを含むため、リポジトリ改名時には設定更新が必要になるが、
主体の信頼判断は数値IDでも行う。許可workflowの追加・改名時はCD側の変更と同時にallowlistを見直す。
名前ベースの `repository` claimは既存環境の段階移行中だけ明示的に併用し、数値IDでのCD確認後に撤去する。

## 公開前チェック

1. `terraform.tfvars`、`backend.hcl`、state、planが含まれていないこと
2. APIキー、秘密鍵、トークン形式の文字列がないこと
3. 実際のプロジェクトID、バケット名、課金・組織情報がないこと
4. exampleが架空値だけで構成されていること
5. Git履歴にも秘密情報がないこと
