# Probes behind the review

Each claim in `../movements-core-review.md` that says "lab" comes from one of these. They ran on
PostgreSQL 18.6 (ICU), PHP 8.3 with `pdo_pgsql`, and Atlas Query 2.0.0. Run them on a scratch
database. Each one creates its own schema and drops it again.

| file | shows | review |
|---|---|---|
| `ci_ai.sql` | the search operators on ci_ai; how a view keeps or loses ci_ai between steps A and C; ci_ai inside a function; the trigram index missing "Ação" | 1, 2, 14 |
| `ledger.sql` | a unit's chain, the balances and the time axis as constraints; RLS through plain and `security_invoker` views; EXECUTE for PUBLIC | 3, 8, 13, 15 |
| `race.sh` | two tills selling the same bike | 8 |
| `errors.php` | a coded refusal through PDO; the poisoned transaction and the savepoint; list arguments; `count()` and `asOf()` through Atlas | 4, 6, 9, 11 |

```bash
psql -d scratch -f ci_ai.sql
```

```bash
psql -d scratch -f ledger.sql
```

```bash
PGDATABASE=scratch bash race.sh
```

```bash
PGHOST=localhost PGDATABASE=scratch PGUSER=postgres php errors.php path/to/vendor/autoload.php
```

- `ci_ai.sql` defines `ci_ai` as `CREATE COLLATION ci_ai (provider = icu, locale = 'und-u-ks-level1', deterministic = false)`. If the house's definition differs, put it in its place.
- `ledger.sql` creates and drops two roles, so it needs a superuser. It needs `btree_gist`, and `ci_ai.sql` part 5 needs `pg_trgm`.
- Not covered here: PostgreSQL's labels in Portuguese (`ERRO:`, `DETALHE:`). This container had no translations installed. To see them on your own servers, add `setlocale(LC_ALL, 'pt_BR.UTF-8');` at the top of `errors.php`, as an app that formats dates in Portuguese may already do (that sets libpq's labels). Then run it against a server whose `lc_messages` is `pt_BR` (that sets the severity).
