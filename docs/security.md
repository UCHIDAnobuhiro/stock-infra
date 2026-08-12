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
| C: 外部値 | 外部APIキー | secret本体のみTerraformで作り、値は人間が手動投入 |

分類Cの値は `.tf`、`.tfvars`、シェル履歴へ残さない入力方法を使用する。

## IAM

- API、バッチ、デプロイでサービスアカウントを分離する
- Secret Manager accessorはsecret単位で付与する
- Artifact Registry writerはrepository単位で付与する
- `serviceAccountUser` は対象サービスアカウント単位で付与する
- ランタイムサービスアカウントへデプロイ権限を付与しない

## Workload Identity Federation

GitHub Actionsからの認証はOIDCを使用し、サービスアカウントキーを発行しない。Providerのconditionで `repository` と `ref` の両方を検証する。許可対象を変更した場合は、CDワークフローと同時に見直す。

## 公開前チェック

1. `terraform.tfvars`、`backend.hcl`、state、planが含まれていないこと
2. APIキー、秘密鍵、トークン形式の文字列がないこと
3. 実際のプロジェクトID、バケット名、課金・組織情報がないこと
4. exampleが架空値だけで構成されていること
5. Git履歴にも秘密情報がないこと
