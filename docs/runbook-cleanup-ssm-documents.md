# Runbook: 命名規約に合わない SSM ドキュメントの棚卸しと削除

デプロイワークフローは、リポジトリから削除された JSON / YAML を AWS 側から**削除しません**
（意図的な設計。README の Notes 参照）。そのため命名規約導入前に作られたドキュメントは
AWS 上に残り続けます。この手順で棚卸しし、不要なものを手作業で削除します。

## この手順で残すもの・消すもの

| 名前のパターン | 扱い | 例 |
| --- | --- | --- |
| `<env>-cmd-*` | **残す**（Command ドキュメントの規約） | `dev-cmd-20260627.sh` |
| `<env>-automation-*` | **残す**（Automation ドキュメントの規約） | `dev-automation-ec2HealthCheck` |
| 上記以外 | **削除候補** | `dev-httpd.sh`, `dev-noarg`, `dev-test2` |

> **注意: 「`cmd-` を含まないもの」だけを条件にしてはいけません。**
> その条件だと `dev-automation-*` も削除候補に入ってしまいます。Automation ドキュメントは
> `automation-` 規約で管理している正規のものです。必ず `cmd-` と `automation-` の**両方**を残す
> 条件にしてください（手順 2 のコマンドはそうなっています）。

## 0. 前提

- `aws` CLI が使え、対象アカウントの認証情報が設定されていること
- 実行者に `ssm:ListDocuments` と `ssm:DeleteDocument` の権限があること
  - ワークフロー用ロール（`ASSUME_ROLE_ARN_CICD`）には `DeleteDocument` が**ありません**。
    運用者自身の認証情報（`--profile`）で実行してください
- dev と prd が別アカウント / 別プロファイルの場合は、それぞれで手順を実施してください

以降のコマンドは `--region ap-northeast-1` を明示しています。プロファイルを使う場合は
`--profile <name>` を各コマンドに追加してください。

## 1. カスタムドキュメントを全件表示する(履歴確認)

`--filters Key=Owner,Values=Self` で、AWS 提供のドキュメント（`AWS-RunShellScript` など）を除外します。

```bash
aws ssm list-documents \
  --region ap-northeast-1 \
  --filters Key=Owner,Values=Self \
  --query 'DocumentIdentifiers[].[Name,DocumentType,DocumentFormat,DocumentVersion]' \
  --output table
```

出力例（環境により異なります）:

```
--------------------------------------------------------------------------
|                             ListDocuments                              |
+------------------------------------------+--------------+--------+-----+
|  dev-automation-Ec2ServiceCheck          |  Automation  |  YAML  |  1  |
|  dev-automation-ec2HealthCheck           |  Automation  |  YAML  |  2  |
|  dev-automation-ec2HealthCheck_20260831  |  Automation  |  YAML  |  1  |
|  dev-cmd-20260627.sh                     |  Command     |  JSON  |  3  |
|  dev-cmd-20260830.sh                     |  Command     |  JSON  |  1  |
|  dev-cmd-20260831.sh                     |  Command     |  JSON  |  1  |
|  dev-httpd.sh                            |  Command     |  JSON  |  1  |
|  dev-noarg                               |  Command     |  JSON  |  1  |
|  dev-sshd.sh                             |  Command     |  JSON  |  2  |
|  dev-test-20260609.sh                    |  Command     |  JSON  |  1  |
|  dev-test2                               |  Command     |  JSON  |  1  |
|  ...                                     |              |        |     |
+------------------------------------------+--------------+--------+-----+
```

`list-documents` はページングされますが、AWS CLI が自動で全ページを取得します。

## 2. 命名規約に合わないドキュメントを抽出する

`Name` だけを 1 行ずつ出し、規約に**合致するもの**を `grep -v` で除外します。
JMESPath（`--query`）には正規表現が無いため、フィルタは shell 側で行います。

結果はファイルに保存します。削除前に目視で確認し、手順 3 でも同じリストを使うためです。

```bash
aws ssm list-documents \
  --region ap-northeast-1 \
  --filters Key=Owner,Values=Self \
  --query 'DocumentIdentifiers[].Name' \
  --output text | tr '\t' '\n' \
  | grep -vE '^(dev|prd)-(cmd|automation)-' \
  | sort > /tmp/ssm-docs-to-delete.txt

cat /tmp/ssm-docs-to-delete.txt
```

出力例（環境により異なります）:

```
dev-httpd.sh
dev-noarg
dev-sshd.sh
dev-test-20260609.sh
dev-test-20260620-1.sh
dev-test-20260620-2.sh
dev-test-20260620-3.sh
dev-test-20260620-4.sh
dev-test2
dev-test3
dev-test4
dev-test5
dev-test6
dev-test7
dev-test8
dev-test9
```

**必ずこの一覧を目視で確認してください。** `cmd-` / `automation-` のものが混ざっていたら、
フィルタが期待どおり動いていません。削除に進まないでください。

## 3. 削除リストからコマンドを生成

```bash
grep -v '^$' /tmp/ssm-docs-to-delete.txt \
  | xargs -I{} echo "aws ssm delete-document --region ap-northeast-1 --name '{}'" \
  > /tmp/ssm-delete-commands.sh
```

## 4. 削除リストの確認

```bash
cat /tmp/ssm-delete-commands.sh
```

## 5. ドキュメントの削除
4.のコマンドを使用してドキュメントを削除
1 行ずつコピーして実行

## 6. 事後確認

```bash
aws ssm list-documents \
  --region ap-northeast-1 \
  --filters Key=Owner,Values=Self \
  --query 'DocumentIdentifiers[].Name' \
  --output text | tr '\t' '\n' \
  | grep -vE '^(dev|prd)-(cmd|automation)-'
```

## 7. 事後確認:カスタムドキュメントを全件表示する(履歴確認)

`--filters Key=Owner,Values=Self` で、AWS 提供のドキュメント（`AWS-RunShellScript` など）を除外します。

```bash
aws ssm list-documents \
  --region ap-northeast-1 \
  --filters Key=Owner,Values=Self \
  --query 'DocumentIdentifiers[].[Name,DocumentType,DocumentFormat,DocumentVersion]' \
  --output table
```

## 補足: リポジトリ側のファイル

この手順は AWS 側の掃除のみを扱います。`command_documents/healthcheck` に残っている
規約外のファイル（`httpd.sh.json`, `noarg.json`, `test2.json` など）は別途整理してください。
それらを変更する PR を作ると `validate` の命名チェックでリネームを求められます。
