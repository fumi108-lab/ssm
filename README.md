# AWS SSM Documents Repository

このリポジトリは、AWS Systems Manager (SSM) Command Document を管理するためのものです。
`command_documents/healthcheck` 配下の JSON を GitHub Actions 経由で AWS に反映します。

## Directory Structure

```text
.
├── .github/workflows/
│   ├── ssm-deploy-dev.yml
│   ├── ssm-deploy-prd.yml
│   └── ssm-test.yml
└── command_documents/healthcheck/
    ├── *.json
    └── templates/
        ├── template.json
        └── template.sh
```

## Managed Documents

- `command_documents/healthcheck/*.json`
  GitHub Actions のデプロイ対象となる SSM Command Document です。
- `command_documents/healthcheck/templates/`
  新規ドキュメント作成時のテンプレート置き場です。

各 JSON は SSM Document 名と 1:1 に対応します。
たとえば `command_documents/healthcheck/sshd.sh.json` は、AWS 上では `sshd.sh` という名前のドキュメントとして扱われます。

## Workflows

### `ssm-deploy-dev`

- トリガー: `dev` ブランチ向け Pull Request
- 対象パス: `command_documents/healthcheck/*.json`
- 処理:
  1. UTF-8 / JSON 構文チェック
  2. 変更されたドキュメントの抽出
  3. AWS 上の既存ドキュメントとの差分確認
  4. deploy plan の生成と artifact 化
  5. 承認後に `dev` 環境へ反映

使用 environment:

- `dev`
  plan 用。`vars.AWS_ROLE` を参照します。
- `dev-review`
  deploy 用。保護ルールを設定する前提です。

### `ssm-deploy-prd`

- トリガー:
  - `main` ブランチ向け Pull Request
  - `main` ブランチへの push
- 対象パス: `command_documents/healthcheck/*.json`
- 処理:
  - Pull Request 時
    1. UTF-8 / JSON 構文チェック
    2. 変更されたドキュメントの抽出
    3. AWS 上との差分確認
    4. deploy plan の生成
  - push 時
    1. push 差分から変更ファイルを抽出
    2. 変更のあるドキュメントのみ create / update

使用 environment:

- `prd`
  plan 用。`vars.AWS_ROLE` を参照します。
- `prd-review`
  deploy 用。保護ルールを設定する前提です。

### `ssm-test`

手動実行用 workflow です。
指定した SSM Document を対象インスタンスへ送信し、標準出力・標準エラーと実行結果を GitHub Actions 上で確認できます。

現在は `AWS_ROLE_DEV` secret を利用しています。

## GitHub Configuration

### Environments

少なくとも以下の environment を作成してください。

- `dev`
- `dev-review`
- `prd`
- `prd-review`

`ssm-deploy-dev.yml` と `ssm-deploy-prd.yml` は、それぞれの environment 内の `vars.AWS_ROLE` を参照します。

想定する運用は以下です。

- `dev`, `prd`
  保護なし。plan 実行用
- `dev-review`, `prd-review`
  required reviewers あり。deploy 実行用

### Variables / Secrets

必要な設定は以下です。

- Environment variable: `AWS_ROLE`
  各 environment ごとに設定する、OIDC で AssumeRole する IAM Role ARN
- Repository secret: `AWS_ROLE_DEV`
  `ssm-test.yml` 用

### AWS Side Requirements

- GitHub OIDC を信頼する IAM Role が作成されていること
- 対象 role に必要な SSM 権限が付与されていること
  - plan 用: `ssm:DescribeDocument`, `ssm:GetDocument`
  - deploy 用: `ssm:CreateDocument`, `ssm:UpdateDocument`, `ssm:UpdateDocumentDefaultVersion`

## How To Update A Document

1. `command_documents/healthcheck` 配下の JSON を追加または更新します。
2. `dev` 向け Pull Request を作成します。
3. GitHub Actions の plan artifact を確認します。
4. 承認後、`dev` へデプロイします。
5. `main` へマージします。
6. `main` 向け plan を確認し、`main` push 後に `prd` へ反映します。

## Notes

- deploy workflow は削除された JSON を AWS から削除しません。
- `templates` 配下は deploy 対象ではありません。
- plan ではローカル JSON と AWS 上の document content を正規化して比較しています。
