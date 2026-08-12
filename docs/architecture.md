# アーキテクチャ

## スコープ

このリポジトリはGCPプロジェクトのbootstrapと、アプリケーションが利用する本番マネージドサービスを管理する。アプリケーションコード、ローカル開発環境、Cloud Runの継続的なデプロイは対象外とする。

## Terraform root

### bootstrap

`terraform/bootstrap` は次を管理する。

- GCPプロジェクト
- 課金アカウントとの関連付け
- bootstrapに必要なAPI
- Terraform state用GCSバケット

プロジェクトとstateバケットには削除防止を設定する。初回だけローカルstateで作成し、バケット作成後にbootstrap自身のstateもGCSへ移行する。

### prod

`terraform/environments/prod` は次を管理する。

- 利用するGCP API
- default VPCとサブネットの参照
- Cloud SQL for PostgreSQL
- Memorystore for Redis
- Artifact Registry
- Secret Manager
- ランタイム・デプロイ用サービスアカウント
- IAM
- GitHub Actions用Workload Identity Federation

## リクエストとデプロイの流れ

```mermaid
sequenceDiagram
    participant GH as GitHub Actions
    participant WIF as Workload Identity Federation
    participant SA as Deploy service account
    participant AR as Artifact Registry
    participant RUN as Cloud Run / Jobs
    participant SM as Secret Manager
    participant SQL as Cloud SQL
    participant REDIS as Memorystore

    GH->>WIF: GitHub OIDC token
    WIF->>WIF: repository と ref を検証
    WIF->>SA: 短期認証情報を発行
    SA->>AR: コンテナイメージをpush
    SA->>RUN: サービスまたはJobをdeploy
    RUN->>SM: ランタイムSAでsecretを取得
    RUN->>SQL: Cloud SQL接続を使用
    RUN->>REDIS: Direct VPC egressで接続
```

## Cloud RunをTerraform管理しない理由

Cloud RunはGitHub Actionsがコンテナイメージ、環境変数、secret参照を更新する。Terraformでも同じサービスを管理すると変更主体が二つになり、イメージ等を `ignore_changes` にする範囲が広がる。結果としてplanのdrift検出能力が低下するため、作成・更新をCDに集約する。

## ネットワーク

- Cloud SQLはCloud Run組み込み接続を利用する
- Redisはdefault VPC内に配置する
- Cloud RunからRedisへはDirect VPC egressを利用する
- 常時稼働コストが発生するServerless VPC Accessコネクタは使用しない
- RedisはVPC内通信に限定し、AUTHを有効にする

## 拡張方針

本番以外の環境や複数プロジェクトへの展開が必要になった場合は、`terraform/environments/<environment>` を追加し、重複が明確になった段階で共通moduleを抽出する。
