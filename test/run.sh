#!/usr/bin/env bash
set -euo pipefail
psql -X -q -v ON_ERROR_STOP=1 -f test/fixture.sql >/dev/null
psql -X -q -c "SELECT pg_stat_reset()" >/dev/null
for i in $(seq 1 20); do echo "SELECT id FROM posts WHERE user_id = $i ORDER BY created_at DESC LIMIT 20;"; done | psql -X -q >/dev/null
sleep 2
out=$(psql -X -f pg_rails_checkup.sql 2>&1)
echo "$out"
fail=0
expect() { grep -q -- "$1" <<<"$out" || { echo "MISSING: $2"; fail=1; }; }
if grep -q "ERROR" <<<"$out"; then echo "FOUND ERROR in report"; fail=1; fi
expect "comments_id_seq.*88\.48" "integer sequence near overflow"
expect "legacy_events_id_seq.*integer.*bigint.*93\.13" "integer column behind a bigint sequence"
expect "likes.*post_id.*integer.*posts.*bigint" "int/bigint foreign key mismatch"
expect "posts.*user_id.*users" "unindexed foreign key"
expect "index_users_on_email_dup.*index_users_on_email" "redundant index"
expect "## 14" "pg_stat_statements section"
sec10=$(sed -n '/^## 10/,/^## 11/p' <<<"$out")
grep -q "| posts " <<<"$sec10" || { echo "MISSING: seq scans on posts after a stats reset"; fail=1; }
[ "$(grep -c '^## ' <<<"$out")" -eq 14 ] || { echo "MISSING: some sections"; fail=1; }
check() { grep -qE -- "$2" <<<"$1" || { echo "MISSING: $3"; fail=1; }; }
noerror() { if grep -q "ERROR" <<<"$1"; then echo "FOUND ERROR: $2"; grep "ERROR" <<<"$1"; fail=1; fi; }

psql -X -q -c "DROP ROLE IF EXISTS checkup_reader" -c "CREATE ROLE checkup_reader LOGIN PASSWORD '${PGPASSWORD:-postgres}'"
ro=$(PGUSER=checkup_reader psql -X -f pg_rails_checkup.sql 2>&1)
noerror "$ro" "restricted role"
check "$ro" "cannot read [0-9]+ sequence" "warning when sequences are hidden from the role"
check "$ro" "comments_id_seq" "hidden sequence names listed"
psql -X -q -c "DROP ROLE checkup_reader"

psql -X -q -c "DROP EXTENSION pg_stat_statements" -c "CREATE SCHEMA IF NOT EXISTS checkup_ext" -c "CREATE EXTENSION pg_stat_statements SCHEMA checkup_ext"
other=$(psql -X -f pg_rails_checkup.sql 2>&1)
noerror "$other" "pg_stat_statements in another schema"
check "$other" "total_s" "query list with pg_stat_statements in another schema"

if [ "$(psql -X -tAc "SELECT count(*) FROM pg_available_extension_versions WHERE name = 'pg_stat_statements' AND version = '1.7'")" = 1 ]; then
  psql -X -q -c "DROP EXTENSION pg_stat_statements" -c "CREATE EXTENSION pg_stat_statements VERSION '1.7'"
  old=$(psql -X -f pg_rails_checkup.sql 2>&1)
  noerror "$old" "pg_stat_statements 1.7"
  check "$old" "old version" "note about old pg_stat_statements"
  check "$old" "total_s" "query list with pg_stat_statements 1.7"
fi

psql -X -q -c "DROP EXTENSION pg_stat_statements" -c "DROP SCHEMA checkup_ext" -c "CREATE EXTENSION pg_stat_statements"
exit $fail
