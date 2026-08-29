# AWS SSM Documents Repository

このリポジトリは、AWS Systems Manager (SSM) Command Document を管理するためのものです。
`command_documents/healthcheck` 配下の JSON を GitHub Actions 経由で AWS に反映します。

## Directory Structure

```text
.
├── .github/workflows/
│   ├── common-ssm-test.yml
│   ├── dev-ssm-deploy.yml
│   └── prd-ssm-deploy.yml
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

### `dev-ssm-deploy`

- トリガー: 手動実行 (`workflow_dispatch`)
  - Actions の Run workflow で「Use workflow from」に**対象ブランチ**を選びます。入力欄はありません。
  - 選んだブランチに紐づく `dev` 向けの open Pull Request を自動で判定し、その差分を反映します。
  - 以下の場合はエラーで停止します。
    - 選んだブランチに base が `dev` の open PR が存在しない（マージ済み・クローズ済み・base が `main` など）
    - 該当する open PR が複数ある（対象を特定できない）
    - PR が draft である
    - PR の head と実行対象コミットが一致しない（実行開始後に push された等）
- 対象パス: `command_documents/healthcheck/*.json`
- 処理:
  1. 選択ブランチから対象 PR を特定（上記のガードを実施）
  2. UTF-8 / JSON 構文チェック
  3. `origin/dev` との merge-base を基準に、変更されたドキュメントを抽出
  4. AWS 上の既存ドキュメントとの差分確認
  5. deploy plan の生成と artifact 化（summary に PR 番号・タイトル・作者・コミットを表示）
  6. 承認後に `dev` 環境へ反映

使用 environment:

- `dev`
  plan 用。`vars.AWS_ROLE` を参照します。
- `dev-review`
  deploy 用。保護ルールを設定する前提です。

### `prd-ssm-deploy`

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

### `common-ssm-test`

手動実行用 workflow です。
指定した SSM Document を対象インスタンスへ送信し、標準出力・標準エラーと実行結果を GitHub Actions 上で確認できます。

実行ブランチに応じて参照する environment を切り替えます。

- `main` ブランチ: `prd`
- それ以外: `dev`

認証には各 environment の `vars.AWS_ROLE` を利用します。

## GitHub Configuration

### Environments

少なくとも以下の environment を作成してください。

- `dev`
- `dev-review`
- `prd`
- `prd-review`

`dev-ssm-deploy.yml`、`prd-ssm-deploy.yml`、`common-ssm-test.yml` は、それぞれの environment 内の `vars.AWS_ROLE` を参照します。

想定する運用は以下です。

- `dev`, `prd`
  保護なし。plan 実行用
- `dev-review`, `prd-review`
  required reviewers あり。deploy 実行用

### Variables

必要な設定は以下です。

- Environment variable: `AWS_ROLE`
  各 environment ごとに設定する、OIDC で AssumeRole する IAM Role ARN

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
