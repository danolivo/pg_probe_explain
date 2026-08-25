# pg_probe_explain

XXX: For DEBUG and query analysis use only!

Dump `EXPLAIN ANALYZE` of a query into the server log — but only when the
planner reported that something you care about happened while planning that
query.

`auto_explain` filters by execution time. This module filters by a *planning
event*: a flag raised somewhere inside the planner by a throwaway core patch.
That lets you catch things `EXPLAIN` cannot show you, because they are
invisible in the finished plan: a path that was built and then lost the cost
comparison, an estimate that was clamped, a code branch that was taken once in
ten thousand queries.

## How the two pieces fit together

The core exports one boolean:

```c
extern PGDLLIMPORT bool planner_probe_hit;	/* src/include/optimizer/pathnode.h */
```

Ownership is split, and this is the whole design:

* the **core patch** only ever *raises* the flag, from wherever the event of
  interest happens;
* the **module** *clears* it before planning a top-level statement, reads it
  afterwards, and turns a raised flag into instrumentation plus a log entry.

So the question you ask lives in two lines of a patch you throw away after the
investigation, and the plumbing — instrumentation, nesting, formatting,
GUCs — stays put.

## The probes that ship with it

Two demo patches, and they export the same boolean — **apply one or the other,
never both**:

| patch | the question it asks | where it raises the flag |
| --- | --- | --- |
| `patches/0001-planner-probe-JOIN_SEMI.patch` | was a `JOIN_SEMI` path built? | `create_nestloop_path()`, `create_mergejoin_path()`, `create_hashjoin_path()` when `jointype == JOIN_SEMI` |
| `patches/0002-planner-probe-parameterized-nestloop.patch` | was a **parameterized nestloop** built — the inner path drawing its parameters from the outer relation? | `create_nestloop_path()`, when `bms_overlap(inner_req_outer, outerrelids)` |

`...-master.patch` is 0001 rebased onto master. Both raise the flag regardless
of what the cost comparison decides afterwards, so a query gets logged even when
the final plan shows no trace of the path — which is the entire point.

A note on what 0002 does *not* test: a nestloop can also be parameterized from
above, meaning the join as a whole needs parameters from an outer relation.
That is `required_outer` being non-empty, and swapping the test is a one-line
change if that is the question you want.

To ask something else again, move the hunks. Nothing in the module changes.

## Build

The module needs a patched server: without `planner_probe_hit` the library
will not load ("undefined symbol").

```sh
cd postgresql                                   # a REL_18_STABLE tree
patch -p1 < contrib/pg_probe_explain/patches/0001-planner-probe-JOIN_SEMI.patch
./configure --prefix=... --enable-debug --enable-tap-tests
make -j && make install
make -C contrib/pg_probe_explain && make -C contrib/pg_probe_explain install
```

Then load it, as any other logging module:

```
shared_preload_libraries = 'pg_probe_explain'
```

`session_preload_libraries` or a plain `LOAD 'pg_probe_explain'` work too,
which is convenient when you only want the probe in one session.

## Configuration

| GUC | Default | Meaning |
| --- | --- | --- |
| `pg_probe_explain.enabled` | `on` | Watch the flag at all |
| `pg_probe_explain.analyze` | `on` | Instrument execution (`EXPLAIN ANALYZE`) |
| `pg_probe_explain.timing` | `on` | Collect timings, not just row counts |
| `pg_probe_explain.verbose` | `off` | `EXPLAIN VERBOSE` |
| `pg_probe_explain.buffers` | `off` | Buffer usage |
| `pg_probe_explain.wal` | `off` | WAL usage |
| `pg_probe_explain.triggers` | `off` | Trigger statistics |
| `pg_probe_explain.settings` | `off` | Modified planner settings |
| `pg_probe_explain.format` | `text` | `text`, `xml`, `json`, `yaml` |
| `pg_probe_explain.log_level` | `log` | Level of the log entry |
| `pg_probe_explain.log_parameter_max_length` | `-1` | Bind parameters, `-1` = none |

All of them are `SUSET`: a superuser can flip them per session.

## What it looks like

```
LOG:  pg_probe_explain: planner probe hit; duration: 2.980 ms  plan:
        Query Text: SELECT count(*) FROM parts p WHERE EXISTS (SELECT 1 FROM sales s WHERE s.part_id = p.id)
        Aggregate  (cost=390.14..390.15 rows=1 width=8) (actual time=2.977..2.978 rows=1.00 loops=1)
          ->  Hash Join  (cost=359.25..387.89 rows=900 width=0) (actual time=2.825..2.953 rows=900.00 loops=1)
                Hash Cond: (p.id = s.part_id)
                ->  Seq Scan on parts p  (cost=0.00..16.00 rows=1000 width=4) (actual time=0.007..0.057 rows=1000.00 loops=1)
                ->  Hash  (cost=348.00..348.00 rows=900 width=4) (actual time=2.813..2.813 rows=900.00 loops=1)
                      ->  HashAggregate  (cost=339.00..348.00 rows=900 width=4) (actual time=2.717..2.760 rows=900.00 loops=1)
                            Group Key: s.part_id
                            ->  Seq Scan on sales s  (cost=0.00..289.00 rows=20000 width=4) (actual time=0.009..1.281 rows=20000.00 loops=1)
```

Look at that plan: there is no semi join in it. The planner built the
`JOIN_SEMI` path, priced it, and then preferred to unique-ify the inner side
and do a plain hash join. That is the point of the module — the query got
logged for something you would never see in its plan.

## Testing

```sh
make -C contrib/pg_probe_explain check          # both TAP tests
contrib/pg_probe_explain/test/demo.sh $(pg_config --bindir)
```

There is one TAP test per probe — `t/001_probe_join_semi.pl` and
`t/002_probe_param_nestloop.pl` — and each starts by asking the server which
probe it carries, then skips itself if the answer is the other one. The
detection queries are chosen so that only their own probe can fire: a semi join
between two tables with no indexes cannot produce a parameterized path, and a
plain inner join cannot produce a semi join. So `make check` is meaningful
whichever patch is applied, and the skip in the output tells you which one it
was.

`test/demo.sh` is written against the `JOIN_SEMI` probe: it runs six queries,
checks which ended up in the log, and prints the entries.

`.github/workflows/pg_probe_explain.yml` runs both against a freshly built
PostgreSQL 18 with the demo patch applied.

## Deploying onto a test stand

`deploy/tantor-1c-probe-deploy.sh` puts all of this onto the 1C load-test stand
without touching the databases: it ships the branch plus the patch and the
module, builds on the stand, swaps the binaries under the existing PGDATA and
rewrites the logging configuration so that probe-triggered plans are the only
thing the log receives — `auto_explain` included in what gets turned off.

```sh
./deploy/tantor-1c-probe-deploy.sh --dry-run     # show the plan
./deploy/tantor-1c-probe-deploy.sh               # do it
./deploy/tantor-1c-probe-deploy.sh --rollback    # binaries and config back
```

Two safety rails worth knowing: the build stage compares `CATALOG_VERSION_NO`
of the new source with the cluster's, and aborts before anything is stopped if
they differ; and the whole old prefix is tarred into
`~/pgdev/rollback/probe-<timestamp>/` together with the config files and the
`ALTER SYSTEM` settings that had to be reset.

## Limitations

Worth knowing before you trust the output:

* **Only top-level statements.** A query planned inside a function, a trigger
  or an RI check does not get logged, and — importantly — does not make its
  caller look interesting. The flag it raised is dropped at the start of the
  next top-level planning.
* **Cached plans are invisible.** The condition is evaluated during planning,
  so a statement served from the plan cache (`PREPARE`/`EXECUTE`, plpgsql
  after five executions) never reports anything. Use
  `plan_cache_mode = force_custom_plan` while investigating.
* **Plain `EXPLAIN` is skipped** (`EXEC_FLAG_EXPLAIN_ONLY`): you already have
  the plan in front of you.
* **Parallel workers are skipped**; the leader reports the whole plan anyway.
* **Utility statements** that never reach the executor produce no log entry,
  even if their planning tripped the probe.
* The flag is a plain global, not tracked per query. A statement that is
  planned and then never executed leaves the module's verdict to be discarded
  at the start of the next statement, not carried into it — but do not build
  anything load-bearing on a debugging aid.
