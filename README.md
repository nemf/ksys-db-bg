# Blue/Green Read-only Connection Tracker

`bg_readonly_connection_tracker.sh` は、Aurora PostgreSQL の Blue/Green switchover 中に、クラスターエンドポイントへの接続断と復旧を観測するための read-only スクリプトです。

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

出力サンプル:

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
