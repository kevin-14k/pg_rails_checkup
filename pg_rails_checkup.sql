\set QUIET on
\pset pager off
\pset null '-'
\pset border 2
\set ON_ERROR_STOP off

\echo '=================================================================='
\echo ' pg_rails_checkup — read-only Postgres health report for Rails apps'
\echo ' Runs only SELECTs on system catalogs/statistics. No table data read.'
\echo '=================================================================='

\echo ''
\echo '## 1. Server'
SELECT version() AS version,
       pg_size_pretty(pg_database_size(current_database())) AS db_size,
       now() - pg_postmaster_start_time() AS uptime,
       (SELECT stats_reset FROM pg_stat_database WHERE datname = current_database()) AS stats_since;

SELECT (rolsuper OR pg_has_role(current_user, 'pg_read_all_stats', 'MEMBER')) AS can_read_all_stats
FROM pg_roles WHERE rolname = current_user \gset
\if :can_read_all_stats
\else
\echo ''
\echo 'NOTE: this role cannot see other roles'' queries and sessions, so sections 13 and 14'
\echo '      may show <insufficient privilege>. For a complete report, run as the app''s own'
\echo '      database user, or have an admin run: GRANT pg_read_all_stats TO <this role>;'
\endif

\echo ''
\echo '## 2. Key settings'
SELECT name, setting, unit, source
FROM pg_settings
WHERE name IN ('shared_buffers','effective_cache_size','work_mem','maintenance_work_mem',
               'max_connections','random_page_cost','effective_io_concurrency',
               'autovacuum_vacuum_scale_factor','autovacuum_analyze_scale_factor',
               'autovacuum_max_workers','statement_timeout','idle_in_transaction_session_timeout',
               'log_min_duration_statement','default_statistics_target','jit')
ORDER BY name;

\echo ''
\echo '## 3. Cache hit ratio (aim > 99% for OLTP)'
SELECT round(100.0 * sum(heap_blks_hit) / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0), 2) AS table_hit_pct,
       round(100.0 * sum(idx_blks_hit) / nullif(sum(idx_blks_hit) + sum(idx_blks_read), 0), 2) AS index_hit_pct
FROM pg_statio_user_tables;

\echo ''
\echo '## 4. Primary keys / sequences close to integer overflow (column or sequence type, whichever is smaller)'
SELECT s.schemaname || '.' || s.sequencename AS sequence,
       coalesce(d.refobjid::regclass::text || '.' || a.attname, '-') AS column_name,
       coalesce(format_type(a.atttypid, NULL), '-') AS column_type,
       s.data_type AS sequence_type,
       s.last_value,
       round(100.0 * s.last_value / least(
         CASE s.data_type::text WHEN 'integer' THEN 2147483647 WHEN 'smallint' THEN 32767 ELSE 9223372036854775807 END,
         CASE a.atttypid WHEN 'int4'::regtype THEN 2147483647 WHEN 'int2'::regtype THEN 32767 ELSE 9223372036854775807 END), 2) AS pct_used
FROM pg_sequences s
LEFT JOIN pg_depend d ON d.classid = 'pg_class'::regclass AND d.objid = format('%I.%I', s.schemaname, s.sequencename)::regclass
                     AND d.refclassid = 'pg_class'::regclass AND d.deptype IN ('a', 'i')
LEFT JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
WHERE s.last_value IS NOT NULL
ORDER BY pct_used DESC
LIMIT 15;

SELECT count(*) AS hidden_sequences,
       coalesce(string_agg(schemaname || '.' || sequencename, ', ' ORDER BY sequencename) FILTER (WHERE rn <= 5), '') AS hidden_examples
FROM (SELECT schemaname, sequencename, row_number() OVER (ORDER BY sequencename) AS rn
      FROM pg_sequences
      WHERE NOT has_sequence_privilege(format('%I.%I', schemaname, sequencename), 'SELECT,USAGE')) h \gset
SELECT :hidden_sequences > 0 AS has_hidden_sequences \gset
\if :has_hidden_sequences
\echo ''
\echo 'WARNING: this role cannot read' :hidden_sequences 'sequence(s), so they are missing above.'
\echo '         First ones:' :hidden_examples
\echo '         An id close to overflow would not show. Run as the app''s own database user, or have an admin run:'
\echo '         GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO <this role>;'
\endif

\echo ''
\echo '## 5. Integer columns referencing bigint keys (type mismatch, overflow risk)'
SELECT c.conrelid::regclass AS table_name,
       a.attname AS column_name,
       format_type(a.atttypid, a.atttypmod) AS column_type,
       c.confrelid::regclass AS references_table,
       format_type(fa.atttypid, fa.atttypmod) AS referenced_type
FROM pg_constraint c
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
JOIN pg_attribute fa ON fa.attrelid = c.confrelid AND fa.attnum = c.confkey[1]
WHERE c.contype = 'f' AND array_length(c.conkey, 1) = 1
  AND a.atttypid <> fa.atttypid;

\echo ''
\echo '## 6. Foreign keys without a supporting index (slow deletes, slow joins)'
SELECT c.conrelid::regclass AS table_name,
       string_agg(a.attname, ', ' ORDER BY x.n) AS columns,
       c.confrelid::regclass AS references_table,
       pg_size_pretty(pg_relation_size(c.conrelid)) AS table_size
FROM pg_constraint c
CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS x(attnum, n)
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = x.attnum
WHERE c.contype = 'f'
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    WHERE i.indrelid = c.conrelid
      AND (i.indkey::int2[])[0:array_length(c.conkey, 1) - 1] @> c.conkey
  )
GROUP BY c.conrelid, c.conname, c.confrelid
ORDER BY pg_relation_size(c.conrelid) DESC
LIMIT 30;

\echo ''
\echo '## 7. Unused indexes since stats reset (candidates to drop, check replicas first)'
SELECT s.schemaname || '.' || s.relname AS table_name,
       s.indexrelname AS index_name,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size,
       s.idx_scan
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary
ORDER BY pg_relation_size(s.indexrelid) DESC
LIMIT 30;

\echo ''
\echo '## 8. Duplicate or redundant indexes (same leading columns)'
SELECT a.indrelid::regclass AS table_name,
       a.indexrelid::regclass AS redundant_index,
       b.indexrelid::regclass AS covered_by,
       pg_size_pretty(pg_relation_size(a.indexrelid)) AS wasted
FROM pg_index a
JOIN pg_index b ON a.indrelid = b.indrelid AND a.indexrelid <> b.indexrelid
WHERE a.indpred IS NULL AND b.indpred IS NULL
  AND a.indexprs IS NULL AND b.indexprs IS NULL
  AND NOT a.indisprimary
  AND (b.indkey::int2[])[0:array_length(a.indkey::int2[], 1) - 1] = (a.indkey::int2[])[0:array_length(a.indkey::int2[], 1) - 1]
  AND (array_length(b.indkey::int2[], 1) > array_length(a.indkey::int2[], 1)
       OR (NOT a.indisunique AND b.indisunique)
       OR (a.indisunique = b.indisunique AND a.indexrelid > b.indexrelid))
ORDER BY pg_relation_size(a.indexrelid) DESC;

\echo ''
\echo '## 9. Largest tables'
SELECT c.oid::regclass AS table_name,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total,
       pg_size_pretty(pg_relation_size(c.oid)) AS heap,
       pg_size_pretty(pg_indexes_size(c.oid)) AS indexes,
       c.reltuples::bigint AS est_rows
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r','p') AND n.nspname NOT IN ('pg_catalog','information_schema')
ORDER BY pg_total_relation_size(c.oid) DESC
LIMIT 15;

\echo ''
\echo '## 10. Sequential scans on non-trivial tables (possible missing index)'
SELECT t.relname AS table_name,
       t.seq_scan,
       t.seq_tup_read,
       t.idx_scan,
       greatest(t.n_live_tup, c.reltuples::bigint) AS est_rows,
       round(t.seq_tup_read::numeric / nullif(t.seq_scan, 0)) AS avg_rows_per_seq_scan
FROM pg_stat_user_tables t
JOIN pg_class c ON c.oid = t.relid
WHERE greatest(t.n_live_tup, c.reltuples) > 10000 AND t.seq_scan > 0
ORDER BY t.seq_tup_read DESC
LIMIT 15;

\echo ''
\echo '## 11. Dead tuples and vacuum lag'
SELECT relname AS table_name,
       n_live_tup,
       n_dead_tup,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
       last_autovacuum,
       last_autoanalyze
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 15;

\echo ''
\echo '## 12. Transaction ID wraparound headroom'
SELECT datname,
       age(datfrozenxid) AS xid_age,
       round(100.0 * age(datfrozenxid) / 2000000000, 1) AS pct_to_forced_shutdown
FROM pg_database
ORDER BY age(datfrozenxid) DESC;

\echo ''
\echo '## 13. Connections by state (watch idle in transaction)'
SELECT coalesce(state, 'background') AS state,
       count(*) AS connections,
       max(now() - state_change) AS longest_in_state
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
GROUP BY 1
ORDER BY 2 DESC;

\echo ''
\echo '## 14. Top queries by total time (needs pg_stat_statements)'
SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') AS has_pgss,
       current_setting('pg_stat_statements.max', true) IS NOT NULL AS pgss_loaded \gset
\if :has_pgss
\if :pgss_loaded
SELECT n.nspname AS pgss_schema,
       EXISTS (SELECT 1 FROM pg_attribute a
               WHERE a.attrelid = format('%I.pg_stat_statements', n.nspname)::regclass
                 AND a.attname = 'total_exec_time') AS pgss_has_exec_time
FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
WHERE e.extname = 'pg_stat_statements' \gset
\if :pgss_has_exec_time
SELECT round(total_exec_time::numeric / 1000, 1) AS total_s,
       calls,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       round(100.0 * shared_blks_hit / nullif(shared_blks_hit + shared_blks_read, 0), 1) AS hit_pct,
       rows,
       left(regexp_replace(query, '\s+', ' ', 'g'), 160) AS query
FROM :"pgss_schema".pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY total_exec_time DESC
LIMIT 20;
\else
\echo 'NOTE: pg_stat_statements is an old version (column names from before 1.8). Running'
\echo '      ALTER EXTENSION pg_stat_statements UPDATE; brings it to the version your server ships.'
SELECT round(total_time::numeric / 1000, 1) AS total_s,
       calls,
       round(mean_time::numeric, 2) AS mean_ms,
       round(100.0 * shared_blks_hit / nullif(shared_blks_hit + shared_blks_read, 0), 1) AS hit_pct,
       rows,
       left(regexp_replace(query, '\s+', ' ', 'g'), 160) AS query
FROM :"pgss_schema".pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY total_time DESC
LIMIT 20;
\endif
\else
\echo 'pg_stat_statements is installed but not loaded: add it to shared_preload_libraries'
\echo '(on RDS / Cloud SQL / Azure: the parameter group or database flags) and restart.'
\endif
\else
\echo 'pg_stat_statements is not installed. It is the single most useful thing to enable.'
\endif

\echo ''
\echo '== end of report =='
