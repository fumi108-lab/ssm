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

## Naming Convention

SSM ドキュメント名は `<環境名>-<種別>-<任意>` に統一します。

| ファイル | SSM ドキュメント名 (dev) |
| --- | --- |
| `command_documents/healthcheck/cmd-httpd.sh.json` | `dev-cmd-httpd.sh` |
| `automation_documents/healthcheck/automation-ec2HealthCheck.yaml` | `dev-automation-ec2HealthCheck` |

つまり **ファイル名は `cmd-` / `automation-` で始める**必要があります。ワークフローは
ファイル名の末尾の拡張子を除いた部分に環境名を前置してドキュメント名を作ります。

この規約は IAM ポリシー (`development-ssmPlan` / `development-ssmExec` など) の Resource が
`arn:aws:ssm:<region>:<account>:document/dev-cmd-*` のように限定されていることに対応しています。
規約から外れた名前は `ssm:DescribeDocument` の時点で `AccessDeniedException` になります。

種別は各ワークフローの `env.DOC_TYPE` で定義しています。**変更する場合は IAM 側の Resource も
合わせて変更してください。**

`dev-ssm-deploy` は `validate` ジョブでこの規約をチェックし、違反していれば AWS に接続する前に
Annotations 付きで停止します。既存のドキュメントには規約導入前の名前が残っているため、
チェック対象はその PR で変更されたファイルのみです。

## Workflows

### `dev-ssm-deploy`

`command_documents/healthcheck/*.json` を dev 環境の SSM ドキュメントへ反映する、手動実行のワークフローです。

**トリガーと実行方法**

`workflow_dispatch` のみ。Actions の Run workflow で「Use workflow from」に**対象ブランチ**を選びます。
入力欄はありません。選んだブランチに紐づく `dev` 向けの open Pull Request を自動で判定し、
その差分を反映します。

**停止条件**

以下はいずれも `validate` ジョブで検知し、AWS に接続する前に停止します。

- 選んだブランチに base が `dev` の open PR が存在しない（マージ済み・クローズ済み・base が `main` など）
- 該当する open PR が複数ある（対象を特定できない）
- PR が draft である
- PR の head と実行対象コミットが一致しない（実行開始後に push された等）
- 変更したファイルの**命名が規約から外れている**（[Naming Convention](#naming-convention) 参照）
- JSON が UTF-8 として読めない、または構文が不正（変更分だけでなく `DOC_DIR` 配下すべてが対象）

**処理の流れ**

1. 選択ブランチから対象 PR を特定（上記のガードを実施）
2. UTF-8 / JSON 構文チェック
3. `origin/dev` との merge-base を基準に、変更されたドキュメントを抽出
4. 命名規則チェック
5. AWS 上の既存ドキュメントとの差分確認、deploy plan の生成と artifact 化
6. 承認後に `dev` 環境へ反映

**使用 environment**

| environment | 用途 | 保護ルール |
| --- | --- | --- |
| `Development_ReadOnly` | plan 用。読み取り専用ロールを紐付けるために指定 | なし |
| `Development` | deploy 用。ここで承認待ちになる | Required reviewers |

どちらも `vars.ASSUME_ROLE_ARN_CICD` を参照します。

**同時実行と競合時の挙動**

`concurrency` グループは `dev-ssm-deploy-${{ github.ref }}` で、**ブランチ (= PR) 単位で並走**します。

- 異なるブランチの run は並走します。
- 同一ブランチを続けて実行した場合、2 本目はキューで待機します（`cancel-in-progress: false`）。
  ただし GitHub は 1 グループにつき pending を 1 つしか保持しないため、3 本目を実行すると
  2 本目はキャンセルされ、最新のものに置き換わります。

複数の PR が同じドキュメントを同時に反映した場合は**後にデプロイされた内容が有効**になります（後勝ち）。
先の内容も SSM のバージョン履歴に残るため `aws ssm list-document-versions --name dev-cmd-<doc>` で追跡できます。

plan 作成時と deploy 実行時で状況が変わった場合は、以下のとおり成功として扱います。
それ以外のエラー（権限不足など）は停止します。

| plan の判定 | deploy 時の状況 | 実際の動作 |
| --- | --- | --- |
| `create` | 他の run が先に作成済み | `update` にフォールバック |
| `update` | 他の run が既に同じ内容を反映済み | skip |

**実行結果の確認**

Actions の Summary 画面に **Deploy Result** テーブルが出ます。

| Document | Result | Version | Note |
| --- | --- | --- | --- |
| `dev-cmd-foo.sh` | updated | 8 | :information_source: 並走した run が先に作成したため create から update へフォールバック |

plan summary は deploy の実行前に生成されるため、その Note 列に deploy 時の出来事は反映されません。
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

## Design Decisions

`dev-ssm-deploy` を現在の形にするまでの判断と、その理由の記録です。仕様そのものは上の
[`dev-ssm-deploy`](#dev-ssm-deploy) の節を参照してください。ここには**なぜそうしたか**だけを書きます。

### なぜ手動実行なのか（[#92](https://github.com/fumi108-lab/ssm/pull/92)）

以前は `dev` 向け Pull Request をトリガーにしていましたが、PR を編集するたびに Actions が
実行されてしまうため、実行タイミングを人の判断下に置きました。

### なぜ PR 番号入力ではなくブランチ逆引きなのか（[#95](https://github.com/fumi108-lab/ssm/pull/95)）

当初は `workflow_dispatch` の入力で PR 番号を受け取っていましたが、自由入力のため
タイプミスやマージ済みの古い番号でも実行できてしまいました。「番号を打つ」行為自体を無くし、
選択したブランチから `gh pr list --head <branch> --base dev --state open` で逆引きする形にしています。

**却下した案**: 番号入力を残したまま state / draft のガードを足す。誤入力の余地が残るため見送りました。

### なぜ concurrency がブランチ単位なのか（[#100](https://github.com/fumi108-lab/ssm/pull/100) → [#107](https://github.com/fumi108-lab/ssm/pull/107)）

最初は全 run を直列化していました（`group: dev-ssm-deploy`）。`deploy-dev` は承認待ちで長時間
停止するため、この粒度では**承認待ちの run が他の全員をブロック**してしまいます。
複数人が別々のドキュメントを同時に編集する運用を想定し、ブランチ単位へ緩めました。

直列化が担保していた「default version 昇格の競合が起きないこと」は、`update-document` の
レスポンス（`DocumentDescription.DocumentVersion`）から自分が作ったバージョンを取得する方式に
変えることで解決しています。以前は `describe-document` で `LatestVersion` を取り直しており、
その間に別の run が更新すると他 run のバージョンを昇格させてしまう競合がありました。

**却下した案**: ドキュメント単位で matrix 分割し leg ごとに concurrency を付ける。
厳密になりますが承認ゲートが leg ごとに発生するため見送りました。

### なぜ同一ドキュメントの競合を後勝ちにするのか（[#107](https://github.com/fumi108-lab/ssm/pull/107)）

dev 環境であり、どちらの内容が正かは Git 側で PR がマージされる時点で決着するためです。
ワークフローがエラーで落ちないことを優先しました。

`DocumentAlreadyExists`（他の run が先に作成済み）と `DuplicateDocumentContent`（既に同じ内容）は
「目的が既に達成されている」と解釈して成功扱いにしています。**エラーを一律に握りつぶすものではなく**、
権限不足などそれ以外のエラーは停止します。

**却下した案**: deploy 直前に AWS の内容を再確認し、plan 作成時から変わっていたら停止する。
同じファイルを触る PR が重なると deploy が失敗しやすくなるため見送りました。

### なぜ Deploy Result を別テーブルにしたのか（[#114](https://github.com/fumi108-lab/ssm/pull/114)）

plan summary は `plan` ジョブが `deploy-dev` の**実行前**に生成するため、フォールバックのような
deploy 時の出来事を後から plan summary の Note 列へ書き込むことは構造上できません。
そのため `deploy-dev` から独立したテーブルを出力しています。

### なぜ命名チェックが変更ファイルのみなのか（[#122](https://github.com/fumi108-lab/ssm/pull/122)）

既存ドキュメントには規約導入前の名前が残っているため、`DOC_DIR` 全体を対象にすると
すべてリネームするまで常に失敗します。変更分から段階的に規約を適用する方針です。

命名の導出は `validate` の `Collect changed documents` の 1 箇所だけで行い、`plan` 以降は
その結果（`targets_json`）をそのまま使います。チェックした名前と実際にデプロイされる名前が
必ず一致し、命名規則を変える際の修正箇所も 1 つで済みます。

## Commenting Policy

ワークフローを後から読み返せるように、以下の方針でコメントを残します。

- コメントには「何を」ではなく**「なぜ」**を書きます。YAML を読めば分かることは書きません。
- **外部依存との結合は必ずコメントに残します。** IAM ポリシーの Resource 条件、environment の
  保護ルール、`gh` コマンドに必要な `permissions` などです。過去に `AccessDeniedException` で
  つまずいた原因は、この結合がコード上から見えなかったことでした。
- 複数の PR にまたがる経緯や却下した案は上の Design Decisions に、コードのすぐ隣で必要な理由は
  YAML のコメントに書きます。

## Notes

- deploy workflow は削除された JSON を AWS から削除しません。
- `templates` 配下は deploy 対象ではありません。
- plan ではローカル JSON と AWS 上の document content を正規化して比較しています。
