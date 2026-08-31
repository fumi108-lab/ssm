# AWS SSM Documents Repository

このリポジトリは、AWS Systems Manager (SSM) Command Document を管理するためのものです。
`command_documents/healthcheck` 配下の JSON を GitHub Actions 経由で AWS に反映します。

## Directory Structure

```text
.
├── .github/workflows/
│   ├── ssm-deploy.yml                  # 再利用可能ワークフロー (デプロイ処理の実体)
│   │                                   #   Actions では "ssm-deploy (共通処理 / 直接実行しない)" と表示
│   ├── dev-ssm-cmd-deploy.yml          # ↓ 4 本は ssm-deploy.yml を呼び出すラッパー
│   ├── prd-ssm-cmd-deploy.yml
│   ├── dev-ssm-automation-deploy.yml
│   ├── prd-ssm-automation-deploy.yml
│   ├── common-ssm-batch-test.yml
│   └── common-ssm-test.yml
├── automation_documents/healthcheck/
│   └── automation-*.yaml
└── command_documents/healthcheck/
    ├── cmd-*.json
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

種別は各ワークフローの `env.DOC_TYPE`、拡張子は `env.DOC_EXT` で定義しています。
**`DOC_TYPE` を変更する場合は IAM 側の Resource も合わせて変更してください。**

各デプロイワークフローは `validate` ジョブでこの規約をチェックし、違反していれば AWS に接続する前に
Annotations 付きで停止します。既存のドキュメントには規約導入前の名前が残っているため、
チェック対象はその PR で変更されたファイルのみです。
（`automation_documents/healthcheck/*.yaml` の 2 件はどちらも規約に適合済みです。
未適合が残っているのは `command_documents/healthcheck` 配下です。）

## Workflows

### 構成

デプロイ系ワークフローの処理は `.github/workflows/ssm-deploy.yml`（`on: workflow_call` の
再利用可能ワークフロー）に 1 本化しています。各ワークフローは実行方法と環境固有の値だけを
定義する薄いラッパーです。

| パラメータ | dev-ssm-cmd-deploy | prd-ssm-cmd-deploy | dev-ssm-automation-deploy | prd-ssm-automation-deploy |
| --- | --- | --- | --- | --- |
| `env_name` | `dev` | `prd` | `dev` | `prd` |
| `doc_dir` | `command_documents/healthcheck` | 同左 | `automation_documents/healthcheck` | 同左 |
| `doc_ext` | `json` | `json` | `yaml` | `yaml` |
| `doc_type` | `cmd` | `cmd` | `automation` | `automation` |
| `base_branches` | `dev` | `main master` | `dev` | `main master` |
| `ssm_document_type` | `Command` | `Command` | `Automation` | `Automation` |
| `ssm_document_format` | `JSON` | `JSON` | `YAML` | `YAML` |
| `plan_artifact_name` | `ssm-cmd-deploy-plan` | 同左 | `ssm-automation-deploy-plan` | 同左 |
| `environment_plan` | `Development_ReadOnly` | `Production_ReadOnly` | `Development_ReadOnly` | `Production_ReadOnly` |
| `environment_deploy` | `Development` | `Production` | `Development` | `Production` |

`concurrency` と `permissions` は呼び出し側で宣言します。呼び出し側の `permissions` が
`ssm-deploy.yml` にも適用され、再利用側では制限しかできないためです。

Actions 画面のジョブ名は `<呼び出し側のジョブ ID> / <再利用側のジョブ名>` の形式になります。
呼び出し側のジョブ ID は環境が分かる名前（`dev` / `prd` など）にしておくと、
`dev / validate` のように表示され、他のデプロイワークフローと並んだときに見分けやすくなります。

`uses: ./.github/workflows/ssm-deploy.yml` のローカルパス形式は**呼び出し側と同じコミットの定義**を
使うため、「選択した ref の定義で実行される」という性質はそのまま保たれます。

`ssm-deploy.yml` は Actions のサイドバーに `ssm-deploy (共通処理 / 直接実行しない)` として並びますが、
`workflow_dispatch` を持たないため **Run workflow ボタンは出ず、直接実行はできません**。
呼び出された側の run は呼び出し側のワークフローに集約されるため、ここに run が積まれることもありません。
（GitHub には再利用専用ワークフローを一覧から隠す設定がないため、名前で区別しています。）

### `dev-ssm-cmd-deploy`

`command_documents/healthcheck/*.json` を dev 環境の SSM ドキュメントへ反映する、手動実行のワークフローです。
以降の 3 本（`prd-ssm-cmd-deploy` と automation 系 2 本）も同じロジックのため、仕様はここにまとめて記載します。

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

`concurrency` グループは `dev-ssm-cmd-deploy-${{ github.ref }}` で、**ブランチ (= PR) 単位で並走**します。

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

### `prd-ssm-cmd-deploy`

`command_documents/healthcheck/*.json` を prd 環境の SSM ドキュメントへ反映する、手動実行のワークフローです。
`dev-ssm-cmd-deploy` と**同じ設計・同じロジック**で、環境依存の値（`NAME` / `BASE_BRANCHES` / environment 名）
だけが異なります。

**トリガーと実行方法**

`workflow_dispatch` のみ。Actions の Run workflow で「Use workflow from」に**対象ブランチ**を選びます。
選んだブランチに紐づく `main`（または `master`）向けの open Pull Request を自動で判定し、その差分を反映します。
通常は `dev` ブランチを選ぶことになります。

受け付ける base ブランチは `env.BASE_BRANCHES`（既定 `"main master"`）で定義しています。

**停止条件**

`dev-ssm-cmd-deploy` と同じです。いずれも `validate` ジョブで検知し、AWS に接続する前に停止します。

- 選んだブランチに base が `main` / `master` の open PR が存在しない
- 該当する open PR が複数ある（対象を特定できない）
- PR が draft である
- PR の head と実行対象コミットが一致しない（実行開始後に push された等）
- 変更したファイルの命名が規約から外れている（[Naming Convention](#naming-convention) 参照。prd では `prd-cmd-*`）
- JSON が UTF-8 として読めない、または構文が不正（変更分だけでなく `DOC_DIR` 配下すべてが対象）

**処理の流れ**

1. 選択ブランチから対象 PR を特定（上記のガードを実施）
2. UTF-8 / JSON 構文チェック
3. PR の base との merge-base を基準に、変更されたドキュメントを抽出
4. 命名規則チェック
5. AWS 上の既存ドキュメントとの差分確認、deploy plan の生成と artifact 化
6. 承認後に `prd` 環境へ反映

**使用 environment**

| environment | 用途 | 保護ルール |
| --- | --- | --- |
| `Production_ReadOnly` | plan 用。読み取り専用ロールを紐付けるために指定 | なし |
| `Production` | deploy 用。ここで承認待ちになる | Required reviewers |

どちらも `vars.ASSUME_ROLE_ARN_CICD` を参照します。

**同時実行と競合時の挙動 / 実行結果の確認**

`concurrency` グループが `prd-ssm-cmd-deploy-${{ github.ref }}` である点を除き、
[`dev-ssm-cmd-deploy`](#dev-ssm-cmd-deploy) と同じです。Deploy Result テーブルも同様に出力されます。

### `dev-ssm-automation-deploy` / `prd-ssm-automation-deploy`

`automation_documents/healthcheck/*.yaml` を SSM **Automation** ドキュメントとして反映します。
トリガー・停止条件・処理の流れ・同時実行と競合時の挙動・Deploy Result は
[`dev-ssm-cmd-deploy`](#dev-ssm-cmd-deploy) と**まったく同じ**です（環境依存の値以外、ロジックは同一）。

command 系との違いは以下だけです。

| 項目 | command 系 | automation 系 |
| --- | --- | --- |
| `DOC_DIR` | `command_documents/healthcheck` | `automation_documents/healthcheck` |
| `DOC_EXT` | `json` | `yaml` |
| `DOC_TYPE` | `cmd` | `automation` |
| ドキュメント名 | `<環境名>-cmd-*` | `<環境名>-automation-*` |
| 構文チェック | 共通（`yaml.safe_load` は JSON も読めるため 1 本化） | 同左 |
| 差分比較 | 共通（ローカルを JSON へ正規化し、AWS 側も `--document-format JSON` で取得） | 同左 |
| SSM への登録 | `--document-type Command --document-format JSON` | `--document-type Automation --document-format YAML` |
| plan artifact 名 | `ssm-cmd-deploy-plan` | `ssm-automation-deploy-plan` |

使用する environment は command 系と同じ（`Development_ReadOnly` / `Development` /
`Production_ReadOnly` / `Production`）です。`concurrency` グループは
`<環境名>-ssm-automation-deploy-${{ github.ref }}` で、command 系とは独立して並走します。

### `common-ssm-test`

手動実行用 workflow です。
指定した SSM Document を対象インスタンスへ送信し、標準出力・標準エラーと実行結果を GitHub Actions 上で確認できます。

実行ブランチに応じて参照する environment を切り替えます。

- `main` ブランチ: `Production_ReadOnly`
- それ以外: `Development_ReadOnly`

認証には各 environment の `vars.ASSUME_ROLE_ARN_OPERATION` を利用します
（デプロイ系が使う `ASSUME_ROLE_ARN_CICD` とは別のロールです）。

## GitHub Configuration

### Environments

以下の environment を作成してください。

| environment | 用途 | 保護ルール |
| --- | --- | --- |
| `Development_ReadOnly` | dev の plan 用 | なし |
| `Development` | dev の deploy 用 | Required reviewers |
| `Production_ReadOnly` | prd の plan 用 | なし |
| `Production` | prd の deploy 用 | Required reviewers |

承認ゲートは `Development` / `Production` の Required reviewers で実現しています。
`*_ReadOnly` に保護ルールを付けないのは、plan で承認を求めず内容を先に見せるためです。

### Variables

environment ごとに以下を設定します。いずれも OIDC で AssumeRole する IAM Role ARN です。

| 変数 | 参照するワークフロー |
| --- | --- |
| `ASSUME_ROLE_ARN_CICD` | `dev-ssm-cmd-deploy` / `prd-ssm-cmd-deploy` / automation 系 |
| `ASSUME_ROLE_ARN_OPERATION` | `common-ssm-test` / `common-ssm-batch-test` |

### AWS Side Requirements

- GitHub OIDC を信頼する IAM Role が作成されていること
- 対象 role に必要な SSM 権限が付与されていること
  - plan 用: `ssm:DescribeDocument`, `ssm:GetDocument`
  - deploy 用: `ssm:CreateDocument`, `ssm:UpdateDocument`, `ssm:UpdateDocumentDefaultVersion`
- **Resource は `document/<環境名>-cmd-*` / `document/<環境名>-automation-*` に限定されていること。**
  この制限が [Naming Convention](#naming-convention) の根拠です。規約から外れた名前は
  `ssm:DescribeDocument` の時点で `AccessDeniedException` になります

## How To Update A Document

1. `command_documents/healthcheck` 配下の JSON を追加または更新します。
2. `dev` 向け Pull Request を作成します (draft のままでは実行できません)。
3. Actions の `dev-ssm-cmd-deploy` から Run workflow を実行し、「Use workflow from」で
   その PR のブランチを選びます。PR 番号の入力は不要です。
4. plan artifact と Step Summary で反映内容を確認します。
5. `Development` environment の承認後、`dev` へデプロイされます。
6. `main` 向け Pull Request を作成します。
7. Actions の `prd-ssm-cmd-deploy` から Run workflow を実行し、「Use workflow from」で
   その PR のブランチ（通常は `dev`）を選びます。
8. plan artifact と Step Summary で反映内容を確認します。
9. `Production` environment の承認後、`prd` へデプロイされます。
10. `main` へマージします。

Automation ドキュメント（`automation_documents/healthcheck/*.yaml`）の場合も流れは同じです。
実行するワークフローを `dev-ssm-automation-deploy` / `prd-ssm-automation-deploy` に読み替えてください。

## Design Decisions

`dev-ssm-cmd-deploy` を現在の形にするまでの判断と、その理由の記録です。仕様そのものは上の
[`dev-ssm-cmd-deploy`](#dev-ssm-cmd-deploy) の節を参照してください。ここには**なぜそうしたか**だけを書きます。

`prd-ssm-cmd-deploy` は `dev-ssm-cmd-deploy` と同一のロジックです（環境依存の値だけが異なります）。
以下の判断はそのまま prd にも当てはまります。

### なぜ手動実行なのか（[#92](https://github.com/fumi108-lab/ssm/pull/92)）

以前は `dev` 向け Pull Request をトリガーにしていましたが、PR を編集するたびに Actions が
実行されてしまうため、実行タイミングを人の判断下に置きました。

### なぜ PR 番号入力ではなくブランチ逆引きなのか（[#95](https://github.com/fumi108-lab/ssm/pull/95)）

当初は `workflow_dispatch` の入力で PR 番号を受け取っていましたが、自由入力のため
タイプミスやマージ済みの古い番号でも実行できてしまいました。「番号を打つ」行為自体を無くし、
選択したブランチから `gh pr list --head <branch> --base dev --state open` で逆引きする形にしています。

**却下した案**: 番号入力を残したまま state / draft のガードを足す。誤入力の余地が残るため見送りました。

### なぜ concurrency がブランチ単位なのか（[#100](https://github.com/fumi108-lab/ssm/pull/100) → [#107](https://github.com/fumi108-lab/ssm/pull/107)）

最初は全 run を 1 つのグループで直列化していました。deploy ジョブは承認待ちで長時間
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

plan summary は `plan` ジョブが deploy ジョブの**実行前**に生成するため、フォールバックのような
deploy 時の出来事を後から plan summary の Note 列へ書き込むことは構造上できません。
そのため deploy ジョブから独立したテーブルを出力しています。

### なぜ命名チェックが変更ファイルのみなのか（[#122](https://github.com/fumi108-lab/ssm/pull/122)）

既存ドキュメントには規約導入前の名前が残っているため、`DOC_DIR` 全体を対象にすると
すべてリネームするまで常に失敗します。変更分から段階的に規約を適用する方針です。

命名の導出は `validate` の `Collect changed documents` の 1 箇所だけで行い、`plan` 以降は
その結果（`targets_json`）をそのまま使います。チェックした名前と実際にデプロイされる名前が
必ず一致し、命名規則を変える際の修正箇所も 1 つで済みます。

### なぜ base ブランチを env で持つのか

`prd-ssm-cmd-deploy` を `main` / `master` のどちらの構成でも動くようにするためです。
`gh pr list --base` は値を 1 つしか取れないため、base で絞らずに取得してから
`env.BASE_BRANCHES`（スペース区切り）で絞り込んでいます。

差分の基準も解決した PR の `baseRefName` から導出しており、`origin/main` のような
ハードコードはありません。`dev-ssm-cmd-deploy` も同じ仕組みに揃えてあります
（`BASE_BRANCHES: "dev"`。値が 1 つなので挙動は従来と同じです）。

これにより 2 つのワークフローのロジックが完全に一致し、環境依存の差分が `env:` ブロックだけに
閉じ込められています。将来、再利用可能ワークフロー（`workflow_call`）へまとめる際の下地にもなります。

### なぜ `prd-ssm-deploy-manual` を削除したのか

`prd-ssm-cmd-deploy` が手動実行になったことで役割が重複したためです。加えて、削除した
ワークフローには本番向けとして看過できない不整合がありました。

- plan はドキュメント名を `prd-<name>` で算出するのに、deploy は `<name>` とプレフィックス無しで
  算出していた。**承認画面に表示される対象と実際の反映先が別物**だった
- deploy が `plan.tsv` を使わず `DOC_DIR` 配下の**全件**を再走査して本番へ反映していた

### なぜ workflow_call で共通化したのか（[#125](https://github.com/fumi108-lab/ssm/pull/125) の反省）

デプロイ系 4 本は同一ロジックでしたが、コピー元とコピー先が別々に育った結果、
`prd-ssm-cmd-deploy` には以下の乖離が溜まっていました。**いずれも本番向けのワークフローです。**

- `deploy-prd` が `plan.tsv` を使わず再走査していた（承認画面で見た内容と実際の反映が別物）
- summary の見出しが `prd_` / `prd___`
- `Render __ENV__ placeholder` の欠落
- 削除した `prd-ssm-deploy-manual` は plan と deploy でドキュメント名が食い違っていた

#125 / #128 で 4 本を揃えましたが、**次に 1 本だけ直せば同じことが再発します**。
処理を `ssm-deploy.yml` に 1 本化し、構造的に防ぐことにしました。

共通化にあたり JSON / YAML の条件分岐が必要かを調べましたが、**不要でした**。

- `yaml.safe_load` は JSON も読める（JSON は YAML のサブセット）
- 管理対象の全ドキュメントに `schemaVersion` / `mainSteps` が存在する

そのため構文チェックと正規化を 1 本化でき、`if:` による分岐はありません。副次的に、
command 系にも automation 側の必須フィールド検査が入るようになりました。

**却下した案**: 4 本を揃えたまま維持する。乖離が実際に起きた実績があるため見送りました。

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
