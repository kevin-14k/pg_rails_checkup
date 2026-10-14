# pg_rails_checkup

A single read-only SQL script that gives you a health report of the Postgres database behind your Rails app in under a minute.

It only runs `SELECT`s on Postgres system catalogs and statistics views. It never reads your table data and changes nothing.

## What it checks

1. Server version, database size, stats age
2. Key settings (memory, autovacuum, timeouts, planner costs)
3. Cache hit ratio
4. Primary keys close to integer overflow, using whichever is smaller of the column type and the sequence type (the classic `integer` id from Rails < 5.1, and `integer` columns behind `bigint` sequences from pre-Postgres-10 databases)
5. Foreign key columns whose type does not match the referenced key (`integer` pointing at `bigint`)
6. Foreign keys without a supporting index
7. Unused indexes
8. Duplicate and redundant indexes
9. Largest tables, heap vs. index size
10. Tables read mostly by sequential scans
11. Dead tuples and autovacuum lag
12. Transaction ID wraparound headroom
13. Connections by state, including `idle in transaction`
14. Top 20 queries by total time (if `pg_stat_statements` is enabled)

## Run it

```sh
curl -sO https://raw.githubusercontent.com/kevin-14k/pg_rails_checkup/main/pg_rails_checkup.sql
psql "$DATABASE_URL" -X -f pg_rails_checkup.sql > report.txt
```

Heroku:

```sh
heroku pg:psql -a your-app < pg_rails_checkup.sql > report.txt
```

Inside a Rails container:

```sh
bin/rails dbconsole -p < pg_rails_checkup.sql > report.txt
```

Run it against production (or a replica) after the app has been up for a while: the statistics are what make the report useful. Tested on Postgres 13, 14, 15, 16, 17 and 18. Run it as the app's own database user (or a role with `pg_read_all_stats`) so the query and connection sections are complete. The script never fails silently: it warns when the role can't read some sequences (so an id near overflow could be hidden), when it can't see other roles' queries, when `pg_stat_statements` is installed but not loaded, and it adapts to old `pg_stat_statements` versions and to the extension living outside `public`. Each of these cases has a test in `test/run.sh`.

Section 14 shows normalized query text (literal values replaced by `$1`, `$2`). Skim the report before sharing it anyway.

## Want an expert to read it?

I'm Kevin Fraissine, a senior Rails / Postgres / infrastructure engineer based in Paris. If you send me your `report.txt` and your `db/schema.rb`, I'll send back within 5 business days:

- a prioritized list of what to fix, ranked by impact and risk
- ready-to-merge Rails migrations for the index and type fixes (with `algorithm: :concurrently` where it matters)
- the specific settings I would change for your instance size and workload
- notes on the 5 heaviest queries and how to make them cheaper

See [SAMPLE_REVIEW.md](SAMPLE_REVIEW.md) for a complete example, written against the test database in this repo.

Fixed price: **390 € excl. VAT**. No access to your servers needed. If the report shows nothing worth fixing, I'll tell you so and you don't pay.

Contact: "k.fraissine@gmail.com"

## License

MIT
