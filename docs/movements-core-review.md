# Review of movements-core.md (revision 1)

**Verdict: approve the direction, and approve the six points with the changes below.** The architecture is right. What needs changing is mostly in the contracts that modules will be written against:
- what a view column promises
- what a refusal does to the caller's transaction
- what a retry does
- how the facts reach PHP

These are cheap to change now and expensive once step A ships. Step A starts on approval, so findings 1–5 come first.

**How this was checked.** I had the plan, the design principles, the ER diagram, `MovementService.php` and `ReceiveLine.php`. I did not have `movements.md`, `movements-code.md`, `atlas-manual.txt`, the modules or core's `SerialUnavailable`. Findings about the layer's tables are therefore marked *check against movements.md*.

Every technical claim marked "lab" was run on PostgreSQL 18.6 (ICU), PHP 8.3 `pdo_pgsql` and Atlas Query 2.0.0, with `ci_ai` defined as a nondeterministic ICU collation (`und-u-ks-level1`). The scripts are in `probes/`; re-run them with the house's own `ci_ai` if its definition differs.

## What to keep

- **The database posts.** PHP, cron and psql all write, so the guards have to live with the data. One function per event, one transaction.
- **Coded refusals.** The draft's `translate()` matches about thirty English phrases. If one message is reworded, its refusal silently becomes a generic error. A SQLSTATE doesn't drift: in the lab, `getCode()` returns `'MVR07'` exactly as raised.
- **Cells, not virtual locations.** Where a unit is and who owns it really do diverge: a bike sold but not yet delivered, a rental, a unit one store owns while another holds it. A negative location id can't express "here, but the customer's".
- **Selects over views.** They fit how modules already build queries, and they avoid a fixed-question API that grows with every screen.
- **The read side first.** Step A puts a stable interface in place before anything underneath it moves.

## Findings

Each finding says when it has to be settled: before step A (the reading contract), before step B (the writing contract) or before step C (the switch).

### Before step A: the reading contract

#### 1. Collation is part of a view's contract, and the switch can change it silently

**The plan says** "the views' columns are the contract, so nothing a module writes changes at the switch."

**What happens.** With `ci_ai`, a column's behaviour depends on its collation as well as its name and type. In the lab:
- A step-A view over `serials.serial_number` (ci_ai) finds a chassis typed in lower case.
- The same view redefined in step C over a layer column declared plain `text` returns 0 rows for the same filter.
- Columns the view computes (a CASE over literals, `->>`, `||`) come out in the default collation, so `state = 'Available'` finds nothing.

```
 view             | column        | type                   | collation
 unit_positions_a | serial_number | character varying(100) | ci_ai     ← step A, over serials
 unit_positions_a | state         | text                   | default   ← computed by CASE
 unit_positions_c | serial_number | text                   | default   ← step C, over a layer column without COLLATE
```

**Change.**
- Every text column a module may filter, sort or join on is `ci_ai` in the view, inherited or set with an explicit `COLLATE ci_ai`.
- The layer's text columns are declared `COLLATE ci_ai`, as every migrated table's are.
- A view contract test pins the name, type and collation (`pg_attribute.attcollation`) of every column, for both the A and the C definitions.

#### 2. On ci_ai columns, search with LIKE, and never put a trigram index on one

**What happens** on 18.6 (lab):

| | result |
|---|---|
| ci_ai: `LIKE '%acao%'`, `NOT LIKE` | work; ignore case and accents (finds "Ação"), as MySQL did |
| ci_ai: `ILIKE`, `NOT ILIKE` | `ERROR: nondeterministic collations are not supported for ILIKE` |
| ci_ai: `~`, `~*` | `ERROR: … not supported for regular expressions` |
| ci_ai: `starts_with()` | `ERROR: … not supported for substring searches` |
| ci_ai: `strpos()`, `replace()` | work |
| plain column: `ILIKE '%acao%'` | ignores case but **not accents**: doesn't find "Ação" |

There is also a trap. With a `pg_trgm` GIN index on a ci_ai column, the planner uses the index for `LIKE '%acao%'` under default settings and returns **0 rows**; a sequential scan of the same table returns **1**. The trigram index folds case but not accents, so the row never reaches the recheck. The same query gives a different answer depending on the plan.

**Change.**
- The plan states **PostgreSQL 18 minimum**, for `_testpg` and any CI image too: before 18, LIKE on a nondeterministic collation is an error.
- The README's rule: on ci_ai columns, LIKE and NOT LIKE (the plan's own example already uses LIKE); never ILIKE, regular expressions or `starts_with()`.
- No trigram index on a ci_ai column. If a search gets slow, add a separate search column, folded for case and accents in a deterministic collation, with its own index, and search that column.

#### 3. The views must run with the reader's rights (`security_invoker`)

**What happens.** A plain view runs with its owner's rights. When the owner also owns the tables, RLS doesn't apply. In the lab, a seat at location 1 reads **2** rows from the table, **4** through a plain view and **2** through a `security_invoker` view. Without the option, Positions would hand every module the other stores' units.

**Change.**
- Every Positions view is created `WITH (security_invoker = true)`.
- The contract test asserts the option (`pg_class.reloptions`).
- One test reads each view as a seat of another location.

#### 4. `count()` and `asOf()` as sketched give wrong results

**count()**, "clone, resetColumns/OrderBy/Limit, COUNT(*)": on a grouped or DISTINCT select, the lab returns `[{"count":5},{"count":5}]` for a result of 2 rows, so `fetchValue()` gives 5. Counting the stripped clone as a derived table gives 2:

```php
Select::new($db)->columns('COUNT(*)')->from((clone $q)->resetOrderBy()->resetLimit()->as('c'))->fetchValue();
```

The README's "or clone and reset" goes.

**asOf(Select, t)** would have to swap the FROM to turn `onHand()` into `stock_at(t)`. In Atlas the joins live in the From component, so `resetFrom()` drops the consumer's joins; in the lab the `LEFT JOIN` vanished from the SQL. `units()` has no time twin to swap to anyway, because `unit_at(id, t)` answers for one unit. **Change:** choose the point in time when the Select is born. `onHandAt(DateTimeImmutable $at, ?Select $parent = null)` and `unitsAt(…)` go over set-returning functions with the same columns as their present-tense twins.

**Two smaller API points.**
- Take `?Select $parent` and call `$parent->subSelect()` inside Positions. A `?Select $on` parameter accepts any Select, and a Select that isn't a sub-select gets a second FROM.
- Accept an optional alias, for a query that uses the same view twice.

#### 5. Step A must move the readers, and it can produce the proof for the switch

**What happens.** Step A lists Positions, the README and the views, but not moving the modules' reads. Any reader left for step C makes "no consumer changes at the switch" untrue.

**Change.**
- **Step A ends when no module reads legacy state.** A read tripwire fails the build: a CI grep for `serials.status`, `serials.location_id`, `serials.transfers_id`, `stock`, `stock_balances`, `variants.stock`, `stock_after` and `serial_events` outside `/var/sys/core/movements/`.
- **Each step-A view documents how it derives the new columns from today's tables, and where that is approximate** (owner, claims, `since`, `word`). A module written against degenerate values, such as an owner that always equals the location, breaks at C.
- **Step A's definitions stay as `legacy_*` views.** On the ported data, `legacy_x EXCEPT x` must be empty, or match a written list of expected differences. That diff is the proof of "nothing a module writes changes at the switch", and the plan's own structure provides it for free.

### Before step B: the writing contract

#### 6. A refusal poisons the caller's transaction

**What happens.** Inside an open transaction, the next statement after a coded refusal fails with `25P02 current transaction is aborted` (lab). "Let a Refused reach the dispatcher" only works if every caller rolls back the whole request. Any "try, else …" flow dies on its next statement: a POS fallback, a batch closing several counts, a refusal written to a log table. With a `SAVEPOINT` around the call, the event alone is undone and the next statement runs (lab).

**Change.**
- When Ledger and Claims join a transaction, each call runs in its own savepoint: released on success, rolled back on a refusal. The README says: *a Refused undoes only its event; your transaction stays usable*.
- Events whose documents the module writes (`arrive`, `dispatch`, `sell`, `handOver`, `closeCount`) **require** the caller's transaction and throw a `LogicException` without one. Silently owning a transaction would commit the event apart from the module's own writes.

#### 7. Retries and double submits post twice

**What happens.** Scanners and forms resend after a timeout. A retried partial `arrive()` receives the same lines again while they are still on the road. A retried `dispatch()` reports "refused" for something that succeeded. Nothing in the plan recognises a repeat.

**Change.**
- Every event gets a header row with a `UNIQUE` key. A repeat with the same key and the same arguments returns the first answer and posts nothing; the same key with different arguments is refused.
- In PHP, Ledger and Claims are built with the request's key (the form's or the scanner's token), and each call's key is that key plus the call's ordinal.
- The module's documents and its postings commit together, so a posting under the request's key means the whole request committed. `$ledger->replayed()` answers that at the start of a request, before the module writes its documents a second time.
- The functions' signatures are the contract: add the key now, rather than to 25 functions later.

#### 8. "Every invariant a constraint": two of the four need a structure, and that structure is also the lock

*Check against movements.md.*

**What happens.** "A unit's chain is unbroken" and "nothing negative at a place" are rules across rows. A CHECK can't see other rows, and a trigger that sums the ledger is slow and racy. Plain constraints can enforce both (lab, `probes/ledger.sql`):

- **The chain.** One row per hop of a unit, `PRIMARY KEY (serials_id, seq)`, with a composite FOREIGN KEY from `(serials_id, prev_seq, from-cell)` to `(serials_id, seq, to-cell)`. A fork, a skipped step and a hop from a road the unit isn't on are all refused.
- **Two tills selling the same bike** (`probes/race.sh`): the second waited about 2 s for the first to commit, then got a unique violation. One sale exists, without an advisory lock.
- **The cell columns are `NOT NULL` (kind + id).** A foreign key skips its check when any of its columns is NULL. The typed foreign keys to `locations` and `transfers` hang on `STORED` generated columns (lab; 18's default VIRTUAL kind can't carry one).
- **The balances.** A balance row per cell × variant with `CHECK (qty >= 0)`, written by the posting functions, refuses going negative, and its row lock serialises racing tills. The road is a cell too, so arriving more than was dispatched is refused by the same CHECK (lab).
- **Two PostgreSQL 18 features.** `PRIMARY KEY (serials_id, during WITHOUT OVERLAPS)` (with `btree_gist`) refuses a backdated residence that overlaps an existing one (lab). `RETURNING old.qty, new.qty` gives `adjust()` its answer in one statement (lab).

**Consequence for the wording.** "State is a query, never a column" becomes **"state is derived, never hand-written."** A current-position row and a balance row are written only by the posting functions, in the event's own transaction, and a view proves they equal the ledger. That is not the four-writers problem. It also keeps the hot reads (the POS picker, the Seriais list) proportional to what is on the shelf. Answered from the ledger alone, "what is here now?" has to look at every hop that ever reached this place, so each read grows with the history.

**Also.**
- The layer gets an **event header** (kind, occurred_at, created_at, users_id, document, key, the event it reverses), with its moves under it. Movimentações lists events, not legs.
- **One lock order.** Every function that touches units first locks their `serials` rows, `ORDER BY id FOR NO KEY UPDATE`. Claims and moves then serialise on the same row, and foreign-key checks from other tables don't wait behind it.
- **Check under that lock, then refuse with a code.** A constraint that fires anyway means a race or a bug. A `unique_violation` on the hop key is caught inside the function and raised again as a coded refusal.

#### 9. The facts don't arrive by code: they are inside the message text

**What happens.** The code arrives clean. The facts don't, because PDO has no DETAIL field and `errorInfo[2]` is one block of text (lab; the probe already raises the `mv:` line proposed below):

```
ERROR:  a moto não está nesta loja
DETAIL:  mv:{"facts": {"note": "linha 1\nlinha 2", "serials_id": 42}, "message": "a moto não está nesta loja"}
CONTEXT:  PL/pgSQL function guard(bigint) line 3 at RAISE …
```

So getting the facts out means parsing text, and the labels around them get translated. The server's `lc_messages` (a superuser setting) translates the severity. libpq, in the PHP process's locale, translates `DETAIL:` and `CONTEXT:`, so an app that calls `setlocale(LC_ALL, 'pt_BR…')` can see `DETALHE:`. This container had no translations to show it; `probes/README.md` says how to check on your servers. Also, `getMessage()` is `SQLSTATE[MVR07]: <<Unknown error>>: 7 ERROR:  …`, which is not an operator message.

**Change.**
- One SQL helper, `mv_refuse(code, message, facts jsonb)`, raises `MESSAGE = message` and `DETAIL = 'mv:' || jsonb_build_object('message', message, 'facts', facts)`.
- PHP reads that one line with `/mv:(\{.*\})$/m`. It is always one line, because `jsonb::text` escapes the newlines inside strings, so neither the labels nor CONTEXT matter (lab, including Portuguese labels).
- **`Retry`** covers `40001`, `40P01` and `55P03`, with `lock_timeout` set for postings. It tells the operator "tente novamente", and with the keys from finding 7 a retry is safe.
- A raw constraint violation, or any unmapped error, is a bug. It is logged with an incident id and shown as a generic message; PostgreSQL's own text never reaches the operator.
- `Code.php` lists every MV code with its facts' keys. A test greps the SQL for `ERRCODE = 'MV…'` and fails when either side has a code the other lacks.

#### 10. The dispatcher snippet doesn't keep the toasts working

**What happens.** §6 says Refused "builds core's existing SerialUnavailable … so the screens' toasts and their buttons keep working unchanged". The snippet in §6 emits a `movement` key and never calls `unit()`. A Refused is not a SerialUnavailable, so the `serial` key the toasts read never appears.

**Change.**
```php
+ ($e instanceof \Movements\Refused && ($unit = $e->unit()) ? ["serial" => $unit->facts()] : [])
```
Also check the HTTP codes. "→ 404 / 409 / 403" changes the responses if today's screens expect a 200 with an error in the body; keep the current convention unless the front end handles these codes.

#### 11. `post()` as sketched can't call half the functions

**What happens** (lab):
- **`chassis text[]`:** `bindInline(array)` expands to `(:a, :b)`, which is a row, and the call fails with `cannot cast type record to text[]`.
- **`movement_count_close`:** it returns a table, and `SELECT fn(…) AS result` gives strings like `"(1,9C2KC1650PR000001)"`.
- **Errors escape:** Atlas runs the query on `fetch*()`, so when `post()` returns a Select the translation must wrap the fetch. Otherwise refusals escape as raw `PDOException`.

**Change.**
- Lists and lines are passed as `jsonb`, which is also safe for commas, quotes and braces in a chassis.
- Every function answers `jsonb`, never a table: one call shape, and the stored answer of a repeated key (finding 7) is jsonb anyway.
- `post()` executes, translates and decodes in one place.
- Booleans need nothing: Atlas binds `PARAM_BOOL`, and the lab returned `false`.

#### 12. Document words that are facts are still written by modules

**What happens.** In §7's dispatch example, the module sets `transfers.status = 'sent'` and then calls `dispatch()`. The design principles derive sent, received and partial at the gate (governance rule 4). Two writers of "was it sent?" is the original problem in miniature. And because the status flips before `dispatch()` runs, the function can't guard "only a draft may leave": it has to accept 'sent' with no legs. `markDelivered`, "beside the order's own words", has the same shape.

**Change.** Modules write intent: the lines, the carrier, the costs, the shop purchase. The function writes the fact word while the column still has one (`dispatch` flips draft → sent), and after C the views derive it.

#### 13. Roles: "no module, script or psql session can move stock another way" needs spelling out

**What happens.** In the lab, a new function is executable by `PUBLIC` by default. And RLS doesn't apply to a table's owner, so a view or a function owned by that owner bypasses it.

**Change.**
- The ledger's tables and functions belong to a `NOLOGIN` role, and the app connects as a non-owner.
- Revoke INSERT, UPDATE, DELETE and TRUNCATE on the ledger and its projections. Revoke EXECUTE from PUBLIC and grant it to the app role (`ALTER DEFAULT PRIVILEGES`).
- The functions are `SECURITY DEFINER` with a pinned `search_path`.
- A trigger refuses UPDATE, DELETE and TRUNCATE on the ledger, the owner included.
- RLS doesn't apply inside a SECURITY DEFINER function, so `Forbidden` comes from one helper every function calls, not 25 copies.
- A function refuses when `app.user` is unset. Cron posts as a named system user.
- `app.user` is attribution, not authentication: any session can set a custom setting. Behind pgbouncer in transaction pooling, the seat uses `set_config(…, true)` in each transaction.

#### 14. Inside the functions, ci_ai doesn't reach variables

**What happens** (lab).
- A column compared with a parameter uses ci_ai and matches.
- Two PL/pgSQL variables, or a value against an array with `= ANY`, compare in the default collation: `'9c2kc1…' = '9C2KC1…'` is false. A guard like "is the scanned chassis one of this remessa's units?" would refuse what the screen shows as matching.
- A view that UNIONs a ci_ai column with a `"C"` column fails at `CREATE VIEW`. That matters if `unit_trajectory` unions an archive.

**Change.**
- Compare text through table columns, or declare text variables and arrays `COLLATE ci_ai`.
- Test every guard with lower-case and accented input.

#### 15. Time: chain order is posting order, and backdating needs a floor

**What happens.** `correct()` takes `occurred_at`. A backdated hop posted after later hops makes posting order and business time disagree, so `stock_at(t)` and `unit_at(t)` show the unit in two places, or in none, for the overlap. And `timestamp(0)` can't order two hops in the same second.

**Change.**
- A unit's history is ordered by `seq`.
- A unit's `occurred_at` is never earlier than its last hop's. A guard and a check view enforce it, or the residence key from finding 8.
- A **lock date** (accounting's closed period): nothing posts before it. A correction older than that posts today, with the intended date in its note.
- The ledger's timestamps are `timestamptz`. Brazil spans four time zones, and `created_at` is system time.

#### 16. Claims: "one unit, one claim" needs one place to enforce it

*Check against movements.md.*

**What happens.** The claims live on three documents: `sales.serials_id`, `transfer_units` and the fleet. "At most one active claim per unit" can't be a constraint across three tables. It becomes a check inside each claim function, and each of them has to know every kind of claim.

**Change.**
- Keep each document's word, and add `unit_claims (serials_id, kind, ref, released_at)` with a unique index on `serials_id WHERE released_at IS NULL`. The claim functions write both, and a check view proves they agree.
- Write down which claims may coexist (a fleet unit on a remessa hold?).
- `dispatch` consumes the remessa's holds, and `sell` checks claims under the unit's lock.
- Document that `Claims::attach()` on a paid line sells at once. It is the one place where a claim moves something.

### Before step C: the switch

#### 17. Split C into gated steps, and state the rollback stance

**What happens.** Step C does four things at once: the writers switch, the views are redefined, the history is ported and the old state is retired. The draft had a soak and drift views; this plan dropped both.

**Change**, inside the approved order:
- **C1, rehearsal on a copy of production.**
  - The opening goes into the ledger: one opening hop per unit, one balance per cell × variant.
  - The old history (`serial_events`) becomes a read-only archive that `unit_trajectory` unions in. It is not replayed through the new constraints, which would reject its gaps.
  - Gate: the `legacy_*` vs layer diff from finding 5 is empty.
- **C2, the switch.**
  - The writers move to Ledger and Claims, and the views move to the layer, in one release.
  - The legacy columns are kept for one release, written from the ledger, for any reader the tripwire missed.
  - The drift views run daily.
- **C3, retirement,** after N clean days.

**Rollback.** Once C2 posts, going back loses postings. Say "forward-fix only", and say why that is acceptable: the rehearsal, the diff and the kept columns.

### Smaller corrections

| § | issue | change |
|---|---|---|
| 4 | `unsell(int $saleId, string $why)` has no qty; its function takes one | add `int $qty` |
| 4 | `notSent(int $transferId, ReceiveLine ...$lines)` has no note; its function takes one | add `string $note` |
| 4 | `Claims::replace()` has no function in §3's table; `detach(int $saleId)` vs `claim_detach(sales_id, serials_id)` | add `claim_replace`; one shape for detach |
| 4 | `writeOff(…, string $reason, …)` but `adjust(…, Reason $reason, …)` | `Reason` for both |
| 4 | method names mix commands and facts (`built`, `backToBench`) | methods imperative (`build`, `returnToBench`); `Kind` in the past tense |
| 4 | `adjust()` and `returnFromCustomer()` take no location | explicit `$locationId`, authorised against the seat |
| 4 | `approvals_id` is unbound | the approval names the event and the unit, is approved, and is used once |
| 3 | a count closes while sales go on | each line keeps when it was counted; difference = counted − `stock_at(counted_at)`; a unit read here that the ledger puts elsewhere comes back as `found` |
| 3 | event catalogue to confirm | back from the provider (unless `to_provider` is final); a customer's bike in for service; parts consumed by assembly or the workshop; what `removeUnit` means for the chassis; bulk on a draft remessa |
| 5 | `owned_elsewhere` is ambiguous: ours elsewhere, or others' here? | define it, or make two views |
| 3 | cost | decide now whether movements carry `unit_cost`; porting it later is painful |
| 8 | function bodies spread over numbered migrations | one file per function and per view, re-applied when it changes |
| 8 | tests to add | two-connection races; a repeated key; Portuguese labels; chassis in lower case and names with accents; each view read by another location's seat; random event sequences with every check view empty after each |
| — | the attached diagram shows the rejected model (virtual locations, the earmark column) | ship a diagram of the chosen layer with the plan |
| 3 | JSON line payloads | refuse unknown keys, so a typo isn't silently ignored |
| 3 | fiscal | if `flip` or `dispatch` needs an NF-e first, the function checks it |

## The six points

| # | point | verdict |
|---|---|---|
| 1 | the database posts; PHP is a typed facade plus reading | **approve**, with §3 gaining the roles (13), the constraints and lock order (8), ci_ai inside the functions (14), time (15) and the event key (7) |
| 2 | `/var/sys/core/movements/`, namespace `Movements` | **approve** as is |
| 3 | Atlas Selects over documented views | **approve with** 1–5: collation and `security_invoker` in the contract, count over a derived table, `*At()` constructors, `$parent`, the contract test, the readers moved in A |
| 4 | one method per event, claims apart | **approve with** 6, 7, 12, 16 and the smaller corrections |
| 5 | typed errors with their facts | **approve with** 9 and 10: the `mv:` line, `Retry`, the code catalogue, the `serial` key |
| 6 | the README as the consumer guide | **approve**; it gains the search rule, the transaction semantics, repeats, the code catalogue and the column contract |

Revision 2 of `movements-core.md` applies all of this, and its §11 maps each change to these findings. It also adds a seventh point to approve: the gates of §9.
