# Review of movements-core.md — second pass

**2026-10-30.** This reviews **revision 1** of `movements-core.md`, the proposal, which is back in this folder.
- It replaces my first review (commit 76ee902), which was written without the house's documents. §6 lists what that review got wrong.
- My revision 2 of the proposal (commit 5875d57) is withdrawn for the same reason. Parts of it break Johan's rules.

**Read against:**
- **The draft's design ideas:** `DESIGN_PRINCIPLES.md`, the ER diagram, `MovementService.php`, `ReceiveLine.php`.
- **The house's own documents:**
  - the model: `movements.md`
  - the plan: `movements-plan.md`
  - the approved coding instruction: `movements-code.md`, with Johan's rules (§0) and the order (§1)
- **Today's schema:** `impublic.sql`, the PostgreSQL 18.6 dump of `imobee`.
- **The lab:** PostgreSQL 18.6, a `ci_ai` collation, PHP 8.3 `pdo_pgsql` and Atlas Query 2.0.0. The scripts are in `probes/`. Each claim marked "lab" comes from one of them.

## Verdict

- **The business rules are right.** The proposal follows each of rules §0.3–0.7:
  - the sale and its unit
  - the late attach
  - the POS selling the unit it selects
  - an order never takes a bike that is still in assembly (S10)
  - a bike with a person being a customer's
  - materials never in the layer
- **The database side is the plan's:**
  - one SECURITY DEFINER function per event, with its guards inside
  - coded refusals with their facts
  - claims as functions of their documents
  - the user from the session
- **The PHP side departs from the approved instruction without saying so**, and it drops parts of the approved plan (M1–M6).
- **Several of the code sketches do not work as written** (M7–M11, each verified in the lab).
- **One security finding concerns today's SECURITY DEFINER functions, and the new posting functions would inherit it** (M12, verified). Its details went to Johan directly, not into this public repository.

**Not approvable as written.** With the twelve must-fixes below, it is.

## 1. Against the design ideas

The model keeps the draft's ideas, changing some of them on purpose (movements.md §12).

| idea | the model | movements-core.md | |
|---|---|---|---|
| facts once, state derived | kept; balances stored in `positions` by a trigger, written by nobody (plan §1.1) | "state is a query (views), never a column" | contradicts the plan: M2 |
| documents capture intent, movements capture fact | kept | kept | ✓ |
| double entry | kept; each event balances per (variant, unit) | "balanced rows" | ✓ |
| corrections are never edits | kept; `corrects_id`, and only a correction may be dated before a unit's latest leg (plan §1.3.5) | `correct()`, `notSent()`, `swap()` | ✓; the time rule is not stated: S4 |
| one call per event | kept | one method per event | ✓ |
| business words in one place | kept: `unitWord()` in serialState.php (plan §1.5) | a `word` column in unit_positions, and no unitWord() | two places: M5 |
| new situations are new kinds of movement | kept | rent, loan and flip are events of their own | ✓ |
| the health check is empty | kept | `movement_checks_*` | ✓ |
| never in two places at once, enforced by the database | kept as an idea (movements.md §12) | "a unit's chain is unbroken", with no mechanism | S3: on 18 a temporal key does it natively |
| point in time | kept | stock_at, unit_at, `asOf()` | asOf() is broken: M9 |
| business time beside system time | kept: occurred_at, recorded_at, timestamp(0), the database's clock | occurred_at on `correct()` | ✓ |
| one "location", with virtual places | changed to where · owner · state | cells | ✓ |
| refusals told apart by their English text | — | SQLSTATE codes with their facts | better than the draft ✓ |

**What not to port from the draft.** movements.md §12 says the same.
- **`translate()`:** 27 English phrases decide the exception's type. Reword one message and that refusal silently becomes a generic error.
- **`serialTrajectory()`:** `LEFT JOIN public.locations lt ON lf.id = tr.transfer_to_location` joins `lt` on `lf`'s id. The destination's name comes out empty.
- **The constructor** changes the error mode, the default fetch mode and the emulated prepares of the PDO it is given. That affects every caller sharing it.
- **`earmarkForTransfer()`** updates `serials.transfers_id` from PHP, a write outside the posting functions. The instruction replaces it with `transfer_units` and claim_hold.

## 2. Against the approved plan and instruction

### M1. The PHP shape departs from the approved instruction
**What was approved:**
- `core/positions.php` in step A and `core/movements.php` in step C (plan §0; code §2, §4, §5)
- "functions, not classes", "built like core/serials.php"
- `$pdo` as the first argument: `unitPosition($pdo, $id)`, `movementReceive($pdo, …)`

**What is proposed:** a new directory, `/var/sys/core/movements/`, under the namespace `Movements`, with thirteen classes and enums: Ledger, Claims, Positions, three value objects, three enums and an exception tree. It is offered as point 2 for approval, but never as a change to what was approved.

**Must:** align with the instruction, or put the change to Johan as a change, with its reason. **I recommend aligning.**
- Nothing in the design needs classes, and core would gain a second convention.
- Functions can return Atlas Selects just as well, e.g. `positionsUnits($pdo, ?Select $parent = null): Select`. That keeps the proposal's one real gain on the reading side.

### M2. "Never a column" contradicts `positions`
**What was approved** (code §3.1; plan §1.1, §6): `positions`, the balance per model and cell, kept by a trigger on movement_legs and read by the readings. It was chosen so the screens stay fast.

**What is proposed:** "State is a query (views), never a column". `positions` appears only in the README's list of things never to write.

**Must:** say what the plan says. Balances are stored and derived, and never written by hand:
- the stock views read `positions`
- unit_positions reads each unit's latest +1 leg

The stored balance is also what makes "nothing negative at a place" a CHECK on `positions`, except for the books and a provider's side (plan §1.3.4). The lab shows such a CHECK refusing an arrival larger than what is on the road.

Today's `stock_balances` shows the alternative: a `DISTINCT ON` over every `stock` row ever written.

### M3. Step A lost its readers and its proof
**What was approved** (code §1, §2, §6):
- Step A is the read interface **and** the 41 reader files moved onto it, module by module.
- Each module is proven by identical screens and answers before and after: its tests, plus a comparison of its read actions on _testpg and on a move of the live data.
- Each module is deployed when it's done.
- An old reader is removed when its last caller has moved, never left as a wrapper.

**What is proposed** (§9): Positions, the README and the views, and nothing else. There is no before-and-after comparison, and nothing about removing the old readers.

**Must:** restore step A as approved.

### M4. The switch lost its guard and its proof
**What was approved** (code §3.4):
- **The guard:** the switch refuses while any class of discrepancy has a row.
- **The opening:** it ports every unit's story as legs, and stops on a broken chain.
- **The proof, inside the migration:** the views redefined on the layer answer exactly what the step-A views answered, and every trajectory tells the story unitTimeline told. Otherwise the migration rolls back.

**What is proposed** (§9): "the views redefined on the layer, the opening (the history ported), the old state retired".

**Must:** restore the guard and the proof. They are what make "no consumer changes at the switch" true.

### M5. The read interface is incomplete, and the word has two homes
Approved in code §2, and missing from Positions:
- **`stockTotal()`:** the organisation's total per model. itemsedit reads `variants.stock` for it today, and that column goes at the switch.
- **`transferProgress($pdo, $id)` over `road_by_transfer`:** per remessa, line and unit, with the remessa's state. `transfers.status` loses `received` at the switch (code §3.4.4), so the state has to come from here.
- **`unitWord($pos)`** in serialState.php, keeping today's keys and labels. The proposal puts a `word` column in unit_positions instead, so the business words would live in two places.

**Must:**
- Add `stockTotal()` and `transferProgress()`.
- Choose one home for the word. The plan's is serialState.php; if that stands, drop the column.

### M6. Event contracts dropped what the plan needs

| event | approved (code §4) | proposed | why it matters |
|---|---|---|---|
| receive | `$newReceived`, the line's new total | `received integer`: a total, or a delta? | A correction down (event 2) is a lower total, and a resent receipt carrying the same total posts nothing. `purchase_items.qty_received` is a total today. |
| arrive | `$newReceived` per line, with its units | ReceiveLine, "units by id, or a quantity" | Today's `stock_transfer_receive` takes a delta, so a resent scan receives twice. It can never exceed what is on the road, but it can exceed what arrived. A new total fixes that. |
| sell | "stamps the cost" | nothing | saleUnitCost reads it, and `sales.unit_cost` is where it goes. |
| toProvider | `$supplierId` | no supplier | Event 21 posts (L·L) → (p·p). Without the supplier there is no cell. |

**Must:** restore each of the four. Because receive and arrive post absolute totals, both can be resent safely without an idempotency key.

## 3. Is the code valid?

**As sketches.** The API blocks are signatures, not runnable PHP: a `final class` cannot declare methods without bodies. That's fine for a proposal. A few slips should still go:
- `Claims` has no constructor, though the examples call `new Claims($pdo)`.
- `post()` reads `$this->pdo`, while the constructor takes `$db`.
- The enums need PHP 8.1 or later; check the servers.

**Valid as written** (lab):
- `whereEquals(['up.variants_id' => []])` → `FALSE`
- a Select nested with `where('v.id IN ', $sub)`
- additive `columns()`
- `page()->perPage()`
- a custom SQLSTATE arriving whole through `getCode()` (`'MVR07'`)
- a PHP `false` bound as a boolean

**Must fix** (each verified on PostgreSQL 18.6 with Atlas Query 2.0.0):

### M7. The call path
- **Lists.** `bindInline(['a', 'b'])` becomes `(:a, :b)`, which is a row, and `CAST(… AS text[])` fails with *cannot cast type record to text[]*. That breaks `movement_receive(… chassis text[])` and `claim_hold`/`claim_release(… serials_id integer[])`. Pass lists as `jsonb`.
- **A table answer.** `movement_count_close` returns a table, and `SELECT fn(…) AS result` turns its rows into strings like `"(1,9C2KC1650PR000001)"`. Have it answer `jsonb`, as the other functions do.
- **Translation.** Atlas runs the query only on `fetch*()`. If `post()` returns a Select, it can't translate the refusal, and refusals escape as raw `PDOException`s. Execute, translate and decode in one place.
- **The caller's transaction.** After a refusal, every later statement in that transaction fails with `25P02 current transaction is aborted`. When a call joins a transaction, run it inside a savepoint: a refusal then undoes only its event, and rolling back the request stays the caller's decision. The approved "in the caller's transaction or one of its own" (code §4) has the same gap.

### M8. Refusals must reach the screen
- **Unit refusals.** Here the approved approach is right: a refusal about a unit becomes the existing `SerialUnavailable` (code §4), which every dispatcher already handles. The proposal's `Refused::unit()` doesn't reach the toasts. Its dispatcher snippet in §6 emits a `movement` key, and nothing emits the `serial` key the toasts read.
- **The facts.** They arrive only inside the message text, between labels PostgreSQL may translate (`DETAIL:` or `DETALHE:`). `getMessage()` itself reads `SQLSTATE[MVR07]: <<Unknown error>>: 7 ERROR:  …`.
  - Raise one fixed line from one SQL helper: `DETAIL = 'mv:' || {"message", "facts"}`.
  - Read only that line in PHP. jsonb escapes newlines, so the line is always whole.
- **Anything else is a bug.** That means a constraint firing without a coded refusal, or any unmapped error. Log it, and show a generic message, never PostgreSQL's own text.

### M9. Reads that give wrong answers
- **count().** Its "clone, resetColumns, COUNT(*)" returns one group's count on a grouped or DISTINCT select: 5 for a result of 2 rows. Count over a derived table instead.
- **asOf()** has to swap the FROM clause. Atlas keeps joins inside the FROM, so `resetFrom()` drops the module's joins. And `units()` has no time twin to swap to. Choose the point in time when the Select is created instead: `onHandAt($at)`, `unitsAt($at)`.
- **The views must be `security_invoker`.** A plain view runs as its owner, and RLS doesn't apply to a table's owner. In the lab, a seat at location 1 read 2 rows from the table but 4 through a plain view. Today's `stock_balances` is exactly that: a plain view, owned by `sys_owner`. If `stock` has RLS, that view already reads past it.

### M10. ci_ai must hold through the switch
- **A column's collation is part of the contract.**
  - A step-A view over `serials.serial_number` (`ci_ai`) finds a chassis typed in lower case. The same view over a layer column declared plain `text` finds nothing.
  - Computed columns (CASE, `->>`) come out in the default collation.
  - Declare the layer's text columns `COLLATE ci_ai`, as every migrated table's are.
  - Give a computed column `COLLATE ci_ai` whenever a module filters on it.
  - The view contract test pins each column's collation, along with its name and type.
  - The schema keeps `locations` in the default collation; the contract keeps whatever today's column has.
- **On ci_ai columns, LIKE and NOT LIKE work, and ignore case and accents**, as MySQL's `utf8mb4_0900_ai_ci` did. ILIKE, regular expressions and `starts_with()` raise errors there. The README example's LIKE is right.
- **No trigram index on a ci_ai column.** The planner uses it for `LIKE '%acao%'` and finds 0 rows, where a sequential scan finds "Ação".
- **Inside PL/pgSQL, ci_ai reaches columns but not variables.** Two text variables, or a value tested against an array with `= ANY`, compare in the default collation. A guard like "is the scanned chassis one of this remessa's units?" would then refuse a chassis typed in lower case. Compare through columns, or declare the variables `COLLATE ci_ai`.

### M11. Grants and roles
- **EXECUTE.** PostgreSQL grants EXECUTE on every new function to PUBLIC. "The application has SELECT only" (code §3.1) doesn't stop any other role from running a posting function. Revoke EXECUTE from PUBLIC through the owner's default privileges, and grant it to the application's role.
- **The owner.** In the dump, every object is owned by `sys_owner`. If the application connects as `sys_owner`, neither RLS nor the planned SELECT-only grant applies to it: a table's owner bypasses RLS (unless FORCE ROW LEVEL SECURITY is set) and holds every privilege. Check which role the seats connect as.

## 4. Against the PostgreSQL schema

### M12. A security finding about the SECURITY DEFINER functions
The details and their probe went to Johan directly. They stay out of this repository while it is public. The fix applies to every new posting function and to the existing ones.

**What the schema confirms:**
- the id types behind the proposal's signatures: serials and locations `int4`; variants, transfers, sales, orders, assembly, loans and approvals `int8`
- `purchase_items.qty_received` is a total (M6), and `sales.unit_cost` is where the cost goes (M6)
- `approvals.ref_type`/`ref_id` can name the unit an approval is for (S8)
- `resources.serials_id` is the fleet's unit, and `claim_fleet`'s "resource id" is `resources.id`, an `int4` (S2)
- `loans` has no customer yet (migration 026)
- `app_user_superadmin()` exists and an admin check doesn't, as code §3.3 says
- 009 already takes its advisory locks in one order: the road, then the location, per variant in ascending order. Keep that order in the new functions.
- `stock_transfer_dispatch` requires the remessa to be `sent` already, and refuses one already on the road. So the proposal's example, which writes `sent` and then dispatches, is the house's working pattern.

**What it raises** (§5):
- `stock_count_lines` keeps no time per counted line (S6).
- The legacy vocabularies the opening must map include `serials.status` `warranty` and `transferred`, and `loans.status` `perdida` (S7).
- `app_enter()` allows an empty `app.user` (S9).
- Some references disagree with their key's type: `loans.serials_id` and `resources.serials_id` are `int8` against `serials.id int4`, and `stock_count_lines.variants_id` is `int4` against `variants.id int8`. The layer's foreign keys follow the keys.

**Not in the dump:** Navicat leaves out RLS policies, privileges and the definition of `ci_ai`. The lab assumed `CREATE COLLATION ci_ai (provider = icu, locale = 'und-u-ks-level1', deterministic = false)`.

## 5. Should

- **S1. Names.** The approved names (plan §7.2; code §2, §3.3, §4) are `road_by_transfer`, `claim_sale`/`claim_sale_release`, `MovementRefused` and `MV0nn`. The proposal uses `road`, `claim_attach`/`claim_detach`, `Refused`/`NotFound`/`Forbidden` and `MVN`/`MVR`/`MVF`. Splitting the codes by kind is an improvement. Either use the approved names or list each rename for Johan.
- **S2. Small mismatches.**
  - The function table gives unsell a qty. Code §4 and the PHP signature have none, so the table is what's wrong.
  - The flip belongs to step D, after the switch, and needs the new admin check.
  - `claim_fleet`'s resource id should be typed `integer`.
- **S3. "Never in two places at once", enforced by the database itself.** The model keeps this idea (§12), but the plan enforces the chain only inside the post functions. On PostgreSQL 18, `PRIMARY KEY (serials_id, during WITHOUT OVERLAPS)` on a residence projection refuses an overlapping residence natively. The projection would be kept by the same trigger as `positions`, and it needs btree_gist. In the lab it refused a backdated overlap. This is the draft's `serial_residence`, without the hand-built EXCLUDE.
- **S4. State the time rule.** Only a correction (`corrects_id`) may be dated before a unit's latest leg (plan §1.3.5), and `correct()` never targets a customer's ownership (event 24: "never a sale").
- **S5. Keep a cell whole.** `num_nonnulls(…) <= 1` per axis allows a place without an owner. Add a CHECK that where and owner are both set, or both "the books".
- **S6. A count's cutoff.** Sales go on while a count is `contando`, and `stock_count_lines` has no counted time. Either keep one per line and compare with `stock_at(counted_at)`, or state that the expected quantities are taken at the close.
- **S7. The opening maps every legacy value**, including `serials.status` `warranty` and `transferred`, and `loans.status` `perdida`.
- **S8. An approval** names its event and its unit (`approvals.ref_type`, `ref_id`), is approved, and is used once.
- **S9. A posting function refuses an empty `app.user`.** `app_enter(…, NULL)` sets it to `''`, and `app_at_master()` alone would still pass. A cron job posts as a named user. `app_enter` sets the session for the whole connection (`set_config(…, false)`); behind a transaction-pooling pgbouncer it would have to be per transaction.
- **S10. Say exactly what §0.5 refuses.** An *order* cannot take a bike that is still in assembly: `claim_sale` refuses a unit in `validating`.
  - Assembly's own link between a job and its unit is assembly's document, not a claim, and no claim or event may refuse it. That link is `assembly.serials_id`, set by assemblyPickRow and assemblySetNumber while the bike is on the bench.
  - `movement_built` even needs that link: it refuses a unit that is not the job's (plan event 3).
  - Related, for Johan: plan event 4 (back to the bench) is refused for a claimed unit, and it posts only (L·L·available) → (L·L·validating). So a bike already attached to an order, or paid and waiting for pickup, that fails its final check could not go back to the bench. The model's "assembly failed (QA)" (movements.md §4) moves only the state, whoever owns the bike.

## 6. Corrections to my first review

The first review was written without the house's documents. With them, these recommendations go or change:

| first review | now | because |
|---|---|---|
| point 2 (the directory and the namespace): approve as is | not as is (M1) | the approved instruction is functions in core/positions.php and core/movements.php |
| C2: keep the legacy columns one release, written from the ledger | withdrawn | rule §0.1: nothing kept alive for an old reader, no bandaids |
| C1: archive the old history instead of porting it | withdrawn | Johan decided to port every unit's story as legs (code §3.4.2) |
| split C into C1–C3, with a soak | withdrawn | the approved switch is one release, with its proof inside the migration and its rehearsal on a move of the live data |
| the chain as a constraint (hops with a composite key) | optional | the approved legs carry nullable cells and enforce the chain in the post functions, under the unit's lock; S3 covers "never in two places at once" |
| a `unit_claims` table | optional | claims stay on their documents, and every claim function locks the unit FOR UPDATE (code §3.3), so one claim at a time is already race-safe |
| idempotency keys on every event | only for events that post a delta | receive and arrive post totals (M6), and the other events are guarded by state |
| a `Retry` exception, one lock order | optional | 009 already locks in one order |
| the fact words belong to the functions; write `sent` after dispatch | withdrawn | 009's dispatch requires `sent` and refuses a remessa already on the road |
| unsell needs a qty | withdrawn | the approved unsell has none (S2) |
| adjust needs an explicit location | withdrawn | the approved adjust takes the seat's location |
| `owned_elsewhere` is ambiguous | withdrawn | code §2 defines it: what a location owns standing elsewhere |
| timestamptz | a note only | the plan chose timestamp(0) and the database's clock; `locations.timezone` is there for display |
| rename built / backToBench | withdrawn | the approved event names are "built" and "back to the bench" |
| an event header, stored balances | already approved | `movements` and `positions` (code §3.1); the proposal only has to stop contradicting them (M2) |
| move the readers in A, and diff A against C | already approved | code §1 and §3.4.3; the proposal dropped them (M3, M4) |

**What still stands from the first review:** M7–M11, S3, and its roles finding, which M12 extends.

## The six points, again

| # | point | verdict |
|---|---|---|
| 1 | the database posts; PHP is a facade plus reading | approve: it is the plan's, with M12 |
| 2 | `/var/sys/core/movements/`, namespace `Movements` | not as written: M1 |
| 3 | Atlas Selects over documented views | approve the views as the contract (code §2), with M9 and M10; the Select helpers become functions |
| 4 | one method per event, claims apart | approve in substance, with M6, M7 and the approved names (S1) |
| 5 | typed errors with their facts | approve with M8 |
| 6 | the README as the consumer guide | approve; it gains the search rule (M10) and the transaction rule (M7) |
