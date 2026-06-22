# Blue/Green Read-only Connection Tracker

`bg_readonly_connection_tracker.sh` は、Aurora PostgreSQL の Blue/Green switchover 中に、クラスターエンドポイントへの接続断と復旧を観測するための read-only 代替スクリプトです。

標準の `bg_switchover_tracker.sh` が前提とする `pgworkshop` ユーザー、`pgworkshop` データベース、検証用テーブルが存在しない環境でも使えるようにしています。DB、ユーザー、テーブルは作成しません。

## 目的

このスクリプトで確認できることは以下です。

- switchover 中に接続失敗が始まった時刻
- 接続が復旧した時刻
- 復旧までの概算接続断時間
- switchover 前後の writer IP
- switchover 前後の Aurora PostgreSQL version

このスクリプトは接続影響の観測用です。アプリケーションの write workload、トランザクション再試行、データ更新の継続性までは検証しません。

## 実行クエリ

1 秒間隔で、既存 DB に対して以下の read-only query を実行します。

```sql
select now(), inet_server_addr(), aurora_version();
```

デフォルト接続先は以下です。

```text
database: postgres
user:     adminuser
port:     5432
```

デフォルトでは、AWS CLI で以下の RDS DB cluster identifier から writer endpoint を自動取得します。

```text
apg-maintenance-workshop-ten-tables-cluster2-cluster
```

別のクラスターを対象にする場合は、`DB_CLUSTER_IDENTIFIER` または `CLUSTER_ENDPOINT` を指定します。

認証は PostgreSQL/libpq 標準の仕組みを使います。たとえば `~/.pgpass` または `PGPASSWORD` を利用してください。

## 使い方

Bastion host など、Aurora に接続できる環境で実行します。
実行環境には `psql` が必要です。

### SSM Session Manager から取得する場合

AWS Systems Manager Session Manager で Bastion host に接続し、以下を実行します。

```bash
cd /home/ec2-user

curl -L \
  https://raw.githubusercontent.com/nemf/ksys-db-bg/main/bg_readonly_connection_tracker.sh \
  -o bg_readonly_connection_tracker.sh

chmod +x bg_readonly_connection_tracker.sh
```

取得元の GitHub ページは以下です。

```text
https://github.com/nemf/ksys-db-bg/blob/main/bg_readonly_connection_tracker.sh
```

コマンドラインから直接ダウンロードする場合は、`github.com/.../blob/...` ではなく `raw.githubusercontent.com/...` の URL を使います。

必要に応じて構文確認を行います。

```bash
bash -n bg_readonly_connection_tracker.sh
```

取得できているファイルが Bash script であることも確認します。

```bash
head -n 1 bg_readonly_connection_tracker.sh
```

期待値:

```text
#!/usr/bin/env bash
```

`bash -n` で以下のように Markdown の表を指すエラーが出る場合、GitHub 上の `.sh` ファイルに Markdown 文書が入っています。

```text
syntax error near unexpected token `|'
| 観点 | bg_switchover_tracker.sh | bg_readonly_connection_tracker.sh |
```

この場合は、GitHub の `bg_readonly_connection_tracker.sh` を Bash script 本体に差し替えてください。説明文書は `README.md` または `bg-readonly-connection-tracker.md` として別ファイルにします。

### 実行

```bash
./bg_readonly_connection_tracker.sh
```

環境変数で接続先や実行間隔を変更できます。

```bash
DB_CLUSTER_IDENTIFIER=apg-maintenance-workshop-ten-tables-cluster2-cluster
CLUSTER_ENDPOINT=apg-maintenance-workshop-ten-tables-cluster2-cluster.cluster-xxxxxxxxxxxx.us-west-2.rds.amazonaws.com
PGDATABASE=postgres
PGUSER=adminuser
PGPORT=5432
CONNECT_TIMEOUT=2
INTERVAL_SECONDS=1
LOG_FILE=bg_readonly_connection_tracker.log
STOP_AFTER_SECONDS=600
```

例:

```bash
INTERVAL_SECONDS=1 CONNECT_TIMEOUT=2 \
./bg_readonly_connection_tracker.sh
```

停止する場合は `Ctrl+C` を押します。停止時にサマリが出力されます。

## ログ出力

標準出力とログファイルの両方に同じ内容を出力します。ログファイル名のデフォルトは以下です。
`latency_ms` は実行環境が対応している場合はミリ秒精度で出力します。未対応環境では秒精度からの概算値になります。

```text
bg_readonly_connection_tracker_YYYYMMDD_HHMMSS.log
```

出力例:

```text
--------------------------------------------------------------------------------
Blue/Green read-only connection tracker
--------------------------------------------------------------------------------
started_at_utc       : 2026-06-22T03:56:29Z
target_host          : apg-maintenance-workshop-ten-tables-cluster2-cluster.cluster-xxxxxxxxxxxx.us-west-2.rds.amazonaws.com
database             : postgres
user                 : adminuser
port                 : 5432
connect_timeout_sec  : 2
interval_sec         : 1
log_file             : ./bg_readonly_connection_tracker_20260622_035629.log
--------------------------------------------------------------------------------
Each attempt prints: timestamp | state | readable details
--------------------------------------------------------------------------------
2026-06-22T03:56:29Z | CONNECTED | initial connection succeeded
2026-06-22T03:56:29Z | OK | writer_ip=10.1.10.212; aurora_version=14.22.2; latency_ms=64; db_time=2026-06-22 03:56:29.581018+00
2026-06-22T04:02:25Z | OUTAGE_STARTED | first failed attempt after state=OK
2026-06-22T04:02:25Z | FAIL | failed_attempt=1; rc=2; latency_ms=2008; error=psql: error: connection to server ... failed: timeout expired
2026-06-22T04:02:34Z | FAIL | failed_attempt=4; rc=2; latency_ms=2007; error=psql: error: connection to server ... failed: timeout expired
2026-06-22T04:02:37Z | RECOVERED | connection restored; outage_seconds=12; failed_attempts=4; first_failure_utc=2026-06-22T04:02:25Z
2026-06-22T04:02:37Z | OK | writer_ip=10.1.10.100; aurora_version=17.9.2; latency_ms=58; db_time=2026-06-22 04:02:37.192797+00

--------------------------------------------------------------------------------
SUMMARY
--------------------------------------------------------------------------------
ended_at_utc          : 2026-06-22T04:04:00Z
successful_attempts  : 360
failed_attempts      : 4
first_failure_utc    : 2026-06-22T04:02:25Z
last_failure_utc     : 2026-06-22T04:02:34Z
first_recovered_utc  : 2026-06-22T04:02:37Z
observed_outage_sec  : 12
last_writer_ip       : 10.1.10.100
last_aurora_version  : 17.9.2
log_file             : ./bg_readonly_connection_tracker_20260622_035629.log
note                 : outage duration is measured from first failed attempt to first recovered attempt.
```

## 状態の意味

```text
CONNECTED       初回接続に成功
OK              query 実行に成功
OUTAGE_STARTED 直前まで成功していた接続が初めて失敗
FAIL            query または接続が失敗
RECOVERED       失敗後、初めて query 実行に成功
SUMMARY         停止時の集計
```

## ドライランでの観測結果

今回のドライランでは、標準の `bg_switchover_tracker.sh` は前提オブジェクト不足で起動できませんでした。

不足していた前提は以下です。

- `pgworkshop` role
- `pgworkshop` database
- `upgrade_testing` / `item_inventory` などの workload table

そのため、既存の `postgres` DB と `adminuser` を使い、この read-only tracker で switchover 中の接続断を確認しました。

観測結果:

```text
first_failure_utc    : 2026-06-22T04:02:25Z
last_failure_utc     : 2026-06-22T04:02:34Z
first_recovered_utc  : 2026-06-22T04:02:37Z
failed_attempts      : 4
observed_outage_sec  : 12
```

switchover 前:

```text
writer_ip       : 10.1.10.212
aurora_version  : 14.22.2
```

switchover 後:

```text
writer_ip       : 10.1.10.100
aurora_version  : 17.9.2
```

この結果から、Blue/Green switchover 後に同じクラスターエンドポイントが新しい writer に復旧したことを確認できました。

## スクリプト単体の動作確認

2026-06-22 に、Bastion host の SSM Session Manager 経由で、このスクリプトを対象クラスターに対して短時間実行しました。

対象 endpoint:

```text
apg-maintenance-workshop-ten-tables-cluster2-cluster.cluster-czug0u8wskp6.us-west-2.rds.amazonaws.com
```

確認結果:

```text
started_at_utc       : 2026-06-22T04:39:05Z
ended_at_utc         : 2026-06-22T04:39:11Z
successful_attempts  : 6
failed_attempts      : 0
last_writer_ip       : 10.1.10.100
last_aurora_version  : 17.9.2
log_file             : /home/ec2-user/bg_readonly_connection_tracker_test.log
```

この確認では switchover 後の安定状態で実行したため、接続断は発生していません。スクリプトの配置、構文、認証、read-only query、ログ出力が Bastion 上で動作することを確認しています。

## 標準スクリプトとの違い

`bg_switchover_tracker.sh` は、ワークロードを流しながら switchover 影響を観測するための補助スクリプトです。一方、このスクリプトは既存 DB への read-only query だけで接続断と復旧を観測します。

| 観点 | bg_switchover_tracker.sh | bg_readonly_connection_tracker.sh |
| --- | --- | --- |
| DB/テーブル作成 | 前提として必要 | 不要 |
| write workload | 実施する | 実施しない |
| 接続断の観測 | 可能 | 可能 |
| writer IP / version 確認 | 実装次第 | 可能 |
| 既存 DB だけで実行 | 前提が合えば可能 | 可能 |

## 注意点

このスクリプトは Blue/Green switchover の必須手順ではありません。標準 tracker が動かない場合でも、Blue/Green deployment の作成、検証、switchover 自体は実施できます。

ただし、研修で「切り替え時の接続断時間を実測して見せる」ことを重視する場合は、標準 tracker を完全にスキップするより、この read-only tracker のような代替手段を使う方が説明しやすくなります。
