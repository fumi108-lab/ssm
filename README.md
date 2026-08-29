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

- `Development_ReadOnly`
  plan 用。`vars.ASSUME_ROLE_ARN_CICD` を参照します。保護ルールは設定していません。
- `Development`
  deploy 用。`vars.ASSUME_ROLE_ARN_CICD` を参照します。Required reviewers による承認を必須にしています。

同時実行制御:

`concurrency` グループは `dev-ssm-deploy-${{ github.ref }}` です。複数人が別々のドキュメントを
同時に編集する運用を想定し、**ブランチ (= PR) 単位で並走**します。

- 異なるブランチの run は並走します。
- 同一ブランチを続けて実行した場合、2 本目はキャンセルされずキューで待機します
  (`cancel-in-progress: false`)。ただし GitHub は 1 グループにつき pending を 1 つしか保持しないため、
  3 本目を実行すると 2 本目はキャンセルされ、最新のものに置き換わります。

複数の PR が同じドキュメントを同時に反映した場合は、**後にデプロイされた内容が有効**になります
(後勝ち)。先にデプロイされた内容も SSM のバージョン履歴に残るため、
`aws ssm list-document-versions --name dev-<doc>` で追跡できます。

並走によって plan 作成時と deploy 実行時で状況が変わった場合の挙動は以下です。

- plan では `create` だったが他の run が先に作成していた → `update` にフォールバックします。
- plan では `update` だったが他の run が既に同じ内容を反映していた → skip します。

いずれもワークフローは成功で終わります。それ以外のエラー (権限不足など) は従来どおり停止します。

実際に何が起きたかは、Actions の Summary 画面に出る **Deploy Result** テーブルで確認できます。

| Document | Result | Version | Note |
| --- | --- | --- | --- |
| `dev-foo.sh` | updated | 8 | :information_source: 並走した run が先に作成したため create から update へフォールバック |

plan summary は deploy の実行前に生成されるため、その Note 列には deploy 時の出来事は反映されません。
デプロイ結果は必ず Deploy Result 側を参照してください。途中で失敗した場合も、そこまでに
処理されたドキュメントは Deploy Result に記録されます。

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
2. `dev` 向け Pull Request を作成します (draft のままでは実行できません)。
3. Actions の `dev-ssm-deploy` から Run workflow を実行し、「Use workflow from」で
   その PR のブランチを選びます。PR 番号の入力は不要です。
4. plan artifact と Step Summary で反映内容を確認します。
5. `Development` environment の承認後、`dev` へデプロイされます。
6. `main` へマージします。
7. `main` 向け plan を確認し、`main` push 後に `prd` へ反映します。

## Notes

- deploy workflow は削除された JSON を AWS から削除しません。
- `templates` 配下は deploy 対象ではありません。
- plan ではローカル JSON と AWS 上の document content を正規化して比較しています。
