# Sample review: demo database

This is what a 390 € review looks like. It is written against the synthetic database in [`test/fixture.sql`](test/fixture.sql) with the small app-like workload in [`test/workload/`](test/workload/), not against a client. The report it is based on is [`sample_report.txt`](sample_report.txt). Every fix below was applied to that database as SQL and the report and workload were run again; the before/after numbers are from that run (Postgres 16, a small cloud VM).

Date: 13 October 2026
Reviewed: `sample_report.txt` (Postgres 16.15, self-hosted)
Reviewer: Kevin Fraissine

## Summary

The database is healthy on the surface (100% cache hit, no vacuum lag, no wraparound risk) but has two time bombs and three cheap performance wins. The urgent item is `comments.id`: its sequence is 88% of the way to the `integer` limit, and when it gets there every new comment fails to insert. The obvious fix (`change_column :comments, :id, :bigint`) is not enough on its own, because the sequence keeps its `integer` type and stops at the same number. The three missing indexes cost most of this workload's database time: after adding them, the three slowest queries went from 10.8 ms, 19.5 ms and 99.3 ms on average to 0.02 ms, 0.01 ms and 0.17 ms.

| Priority | Finding | Impact | Effort | Risk of the fix |
|---|---|---|---|---|
| P1 | `comments.id` sequence at 88% of `integer` | Inserts into `comments` fail at 2,147,483,647 | 1 migration | Table rewrite; plan the lock (see below) |
| P1 | `legacy_events.id` is `integer` behind a `bigint` sequence, 93% used | Same failure, and naive checks miss it | 1 migration | Table rewrite |
| P2 | Feed query reads all of `posts` on every call | 81 s of DB time in 40 s of traffic | 1 index | Low, built concurrently |
| P2 | `comments.user_id` unindexed | 34 s of DB time; slow user deletes | 1 index | Low |
| P2 | `ILIKE '%…%'` search scans `comments` | 99 ms per search | Extension + index | Low |
| P2 | `likes.post_id` is `integer`, `posts.id` is `bigint` | Likes break once `posts.id` passes 2^31 | 1 migration | Empty table today, so free now |
| P3 | Redundant and unused indexes (8.7 MB) | Slower writes, wasted memory | 1 migration | Low |
| P3 | Default settings, no timeouts | No protection from runaway queries | Config change | Low |

P1 = fix this sprint (outage or data risk). P2 = fix this quarter (performance, cost). P3 = good hygiene.

## Findings

### P1. `comments.id` is close to the integer limit

What the report shows: section 4, `comments_id_seq`, column `integer`, sequence `integer`, `last_value` 1,900,000,000, 88.48% used.

Why it matters: at 2,147,483,647 every `INSERT INTO comments` fails with `nextval: reached maximum value of sequence`. At the current rate you have headroom, but the fix takes a table rewrite, which you want to schedule, not do during an outage.

The trap: `ALTER COLUMN id TYPE bigint` changes the column and leaves the sequence as `integer`. I checked this on the test database: after the column change, `pg_sequences` still reports `data_type integer, max_value 2147483647`. You need both statements.

Fix (table under a few million rows, or a maintenance window is acceptable):

```ruby
class ChangeCommentsIdToBigint < ActiveRecord::Migration[7.1]
  def up
    change_column :comments, :id, :bigint
    execute "ALTER SEQUENCE comments_id_seq AS bigint"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
```

Also change every column that references `comments.id` (none in this schema; check `db/schema.rb` for `comment_id` columns and `t.references :comment`).

How to roll it out safely: the `ALTER TABLE` takes an `ACCESS EXCLUSIVE` lock and rewrites the table and its indexes. On the test database it took 0.53 s for 200,000 rows; time grows with table and index size, so on tens of millions of rows reads and writes to `comments` stop for minutes. Run it in a low-traffic window with `SET lock_timeout = '5s'` so it gives up rather than queueing behind a long transaction and blocking everything after it. For a large table, use the online path instead: add a `bigint` column, fill new rows with a trigger, backfill in batches, build a unique index concurrently, then swap the primary key in one short transaction. That is a half-day of work I can write out step by step for your table.

### P1. `legacy_events.id`: integer column behind a bigint sequence

What the report shows: section 4, `legacy_events_id_seq`, column `integer`, sequence `bigint`, 93.13% used.

Why it matters: this is typical of tables created before Postgres 10, when every sequence was `bigint`, or of a sequence changed by hand. A check that only looks at the sequence type reports 0.00% used here. The column is what limits you, and it is at 93%.

Fix:

```ruby
class ChangeLegacyEventsIdToBigint < ActiveRecord::Migration[7.1]
  def up
    change_column :legacy_events, :id, :bigint
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
```

Same lock considerations as above. This one comes first: it is closer to the limit.

### P2. The feed query scans all of `posts`

What the report shows: section 14, `SELECT id, title, created_at FROM posts WHERE user_id = $1 ORDER BY created_at DESC LIMIT $2`, 7,512 calls, 10.75 ms average, 80.7 s total, the top query by far. Section 10: `posts` has 7,514 sequential scans of ~95,600 rows each. Section 6: `posts.user_id` has a foreign key and no index.

Why it matters: each call reads the whole table to return 20 rows. Its cost grows with the table, so it gets slower every month.

Fix: one composite index serves the query, including its sort, and also covers the foreign key.

```ruby
class AddIndexOnPostsUserIdAndCreatedAt < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_index :posts, [:user_id, :created_at], algorithm: :concurrently
  end
end
```

Result on the test database: 10.75 ms to 0.019 ms per call.

How to roll it out safely: `algorithm: :concurrently` builds without blocking writes. If the build fails it leaves an `INVALID` index behind; drop it and rerun.

### P2. `comments.user_id` has no index

What the report shows: section 6 (`comments.user_id` references `users`, no index) and section 14 (`SELECT count(*) FROM comments WHERE user_id = $1`, 19.5 ms average, 33.7 s total).

Why it matters: the count on profile pages scans the table, and every `DELETE FROM users` also scans `comments` to check the foreign key.

```ruby
class AddIndexOnCommentsUserId < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_index :comments, :user_id, algorithm: :concurrently
  end
end
```

Result: 19.5 ms to 0.010 ms per call. If that count is shown on every profile view, a `counter_cache` would remove the query altogether.

### P2. Comment search with `ILIKE '%…%'`

What the report shows: section 14, `SELECT id, post_id FROM comments WHERE body ILIKE $1 LIMIT $2`, 99.3 ms average. Section 7: `index_comments_on_body` has 0 scans. A B-tree index can't serve a pattern that starts with `%`, so it is never used.

Fix: a trigram index, which can.

```ruby
class AddTrigramIndexOnCommentsBody < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    enable_extension "pg_trgm"
    add_index :comments, :body, using: :gin, opclass: :gin_trgm_ops,
              name: "index_comments_on_body_trgm", algorithm: :concurrently
  end
end
```

Result: 99.3 ms to 0.17 ms per search. On managed Postgres, `pg_trgm` is available on RDS, Cloud SQL, Heroku and most others.

### P2. `likes.post_id` is `integer`, `posts.id` is `bigint`

What the report shows: section 5.

Why it matters: once `posts.id` passes 2,147,483,647, liking those posts fails. The table is empty today, so the fix costs nothing now and a rewrite later.

```ruby
class ChangeLikesPostIdToBigint < ActiveRecord::Migration[7.1]
  def up
    change_column :likes, :post_id, :bigint
  end

  def down
    change_column :likes, :post_id, :integer
  end
end
```

### P3. Redundant and unused indexes

What the report shows: section 8, `index_users_on_email_dup` is fully covered by the unique `index_users_on_email` (1 MB). Section 7, `index_comments_on_body` has 0 scans (7.6 MB) and is replaced by the trigram index above.

```ruby
class RemoveRedundantIndexes < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    remove_index :users, name: "index_users_on_email_dup", algorithm: :concurrently
    remove_index :comments, name: "index_comments_on_body", algorithm: :concurrently
  end
end
```

Before dropping an index for having zero scans, check that statistics weren't reset recently (section 1, `stats_since`) and that no read replica uses it: replica scans don't show up in the primary's statistics.

## Settings

The report shows defaults almost everywhere. Suggested values assume a 4 GB RAM instance on SSD storage; for a real review I ask for the instance type and size these for it.

| Setting | Current | Suggested | Why |
|---|---|---|---|
| `shared_buffers` | 128 MB | 1 GB | ~25% of RAM is the usual starting point |
| `effective_cache_size` | 4 GB | 3 GB | Tells the planner how much the OS caches; ~75% of RAM |
| `random_page_cost` | 4 | 1.1 | 4 models spinning disks; on SSD it makes the planner avoid indexes it should use |
| `effective_io_concurrency` | 1 | 200 | SSDs handle parallel reads |
| `work_mem` | 4 MB | 16 MB | Fewer sorts spilling to disk; per sort, so keep it modest with 100 connections |
| `maintenance_work_mem` | 64 MB | 256 MB | Faster index builds and vacuums, including the migrations above |
| `idle_in_transaction_session_timeout` | 0 | 60s | Kills sessions that hold a transaction open and block vacuum |
| `statement_timeout` | 0 | 30s for the web role | Set per role (`ALTER ROLE web SET statement_timeout = '30s'`) so migrations and jobs keep their own limits |
| `log_min_duration_statement` | off | 500ms | You can't fix slow queries you never see |
| `jit` | on | off | JIT compilation often makes short OLTP queries slower |

## Heaviest queries

Covered in the P2 findings: the top three queries by total time were all missing an index. After the fixes, the same 4-client workload went from about 470 to about 16,000 transactions per second on the test machine. Your gain depends on your traffic mix; the per-query numbers above are the reliable part. The other two frequent queries (`posts` by id, `comments` by `post_id`) already use indexes and average 0.02 ms; nothing to do.

## What I would not touch

- `index_likes_on_post_id` shows 0 scans, but `likes` is empty. It backs a foreign key and will be needed as soon as the table is used.
- `users.id` is `integer` at 0.00%. Moving it to `bigint` means rewriting `users` and every `user_id` column. Not worth it until it passes ~50%.
- Cache hit ratio is 100%. Nothing to gain from more memory today.

## Next steps

1. This week: `legacy_events.id`, then `comments.id` (with the sequence), in a low-traffic window with `lock_timeout` set.
2. Same deploy or the next: the three indexes (concurrently), the `likes.post_id` change and the index removals.
3. Settings, in one restart window (`shared_buffers` needs a restart; the others don't).
4. One week later: run the checkup again. Section 4 should show no row above a few percent, sections 6 and 8 should be empty, and section 14 should have a new top query. That one is the next thing to look at.
