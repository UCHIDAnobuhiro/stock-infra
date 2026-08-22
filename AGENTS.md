# AGENTS.md

このファイルは、AIエージェントがこのリポジトリを安全に扱うためのガイドです。

## リポジトリの役割

株式情報アプリケーションの構築済み本番GCP基盤をTerraformで管理する。実環境の設定値はローカル設定、管理対象リソースの状態はremote stateを正とし、実際のプロジェクトIDや認証情報はコミットしない。

| Terraform root | 責務 |
|---|---|
| `terraform/bootstrap` | GCPプロジェクト、前提API、Terraform stateバケット |
| `terraform/environments/prod` | Cloud Runサービス・Jobsとその設定、Cloud SQL、Memorystore、Artifact Registry、Secret Manager、サービスアカウント、IAM、WIF、API有効化 |
| backend GitHub Actions CD | コンテナイメージのbuild/push、既存Cloud Runリソースのイメージ更新、traffic切替、Job実行 |

Cloud RunのイメージとServiceのtrafficだけはbackend CDが管理し、Terraformでは
`lifecycle.ignore_changes` の対象とする。それ以外の環境変数、Secret参照、ネットワーク、
リソース制限、ランタイムSA、Job引数をCDから変更してはいけない。

## 開発コマンド

```bash
terraform fmt -recursive
terraform fmt -check -recursive
terraform -chdir=terraform/bootstrap init -backend=false
terraform -chdir=terraform/bootstrap validate
terraform -chdir=terraform/environments/prod init -backend=false
terraform -chdir=terraform/environments/prod validate
```

`plan` はGCP認証とローカル設定が用意されている場合のみ実行する。

## 変更時の必須ルール

### 構築済み環境への影響を先に確認する

- すべての変更を新規構築ではなく既存の本番リソースに対する変更として扱う
- example設定から実環境の状態を推測せず、ローカル設定とremote stateを使用したplanで影響を確認する
- planでは更新・削除・再作成の有無を確認し、認証やローカル設定がなくplanできない場合は未確認であることを報告する
- ネットワークやRedis等の移行は通常の変更と分離し、移行手順・影響・ロールバックを人間が確認できる単独の変更として扱う

### `terraform apply` を実行しない

エージェントの作業は検証と `terraform plan` の提示までとする。`apply` は人間がplanを確認した後に実行する。`terraform destroy` は提案も実行もしない。

### 再作成があれば止める

planに `must be replaced` または `forces replacement` が出た場合は作業を止め、対象と影響を報告する。

| リソース | 主な影響 |
|---|---|
| Cloud SQL | DBデータを失う可能性がある |
| Memorystore | キャッシュが消え、接続先変更時は再デプロイが必要 |
| Artifact Registry | 保存済みコンテナイメージを失う |
| Secret Manager | 対象シークレットの全versionを失う |
| `random_password` | 認証不能、強制ログアウト、DB接続停止につながる |

### `random_password` を不用意に変更しない

- `PASSWORD_PEPPER`: 再生成すると既存のパスワードハッシュを検証できなくなる
- `JWT_SECRET`: 再生成すると発行済みトークンが無効になる
- `DB_PASSWORD`: 再生成後、アプリケーションの再デプロイまでDB接続が失敗する

ローテーションを目的とし、人間が影響を確認した場合のみ変更する。

### 実値をコミットしない

- `terraform.tfvars` と `backend.hcl` はローカル専用
- 公開する設定例は `*.example` のみ
- プロジェクトID、課金・組織情報、stateバケット名、実際のGitHubリポジトリ名を文書へ固定しない
- APIキー、パスワード、サービスアカウントJSON、tfstateをコードへ保存しない
- Terraform生成シークレットもstateには平文で入る前提で扱う

### コメントの「なぜ」を保持する

Direct VPC egress、PITR無効、ディスク自動拡張無効、RedisのTLS無効とAUTH有効などのコメントは、コストや制約を踏まえた判断を残している。リファクタでも削除しない。

## よくある変更

### シークレットを追加する

値の出どころを `secrets.tf` のA/B/Cへ分類する。外部APIキー等はsecret本体だけをTerraform管理し、versionは人間が安全な入力経路で追加する。IAMの `local.all_secret_ids` と `cloud-run.tf` のSecret環境変数を合わせて確認する。

### GCP APIを追加する

`apis.tf` の `local.services` に用途コメント付きで追加し、依存リソースには対象 `google_project_service` への `depends_on` を設定する。

### IAMを追加する

最小権限を維持する。Secret Manager、Artifact Registry、サービスアカウントの権限を安易にプロジェクト単位へ広げない。

## ドキュメント同期

構成や責務が変わった場合は `README.md` と `docs/` を同時に更新する。実環境固有値はドキュメントへ追加しない。

## Gitルール

- コミットメッセージとPRは日本語で記述する
- ブランチ操作は `git checkout` ではなく `git switch` を使用する
