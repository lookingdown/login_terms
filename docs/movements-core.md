# The movement domain in system core — strategy and design (for approval)

**Revision 2**, after the review in `movements-core-review.md`. §11 lists what changed and why.

**What this is.** The design of the core that every module talks to about
stock and units:
- where it lives: `/var/sys/core/movements/`
- what it is made of: the database's posting engine and the PHP providers
- its public API, for the consumers that read movement data and the ones that
  set something moving
- how Atlas Query carries both sides
- how it is documented for the modules

Nothing is coded until Johan approves this. The code sketches show the API's
shape. They are not the implementation.

**What it builds on:**
- the model (`movements.md`)
- the rules and the approved order (`movements-code.md` §0–§1)
- the ERP pattern of the draft in `~/movements/`: MovementService, the Ledger
  exceptions, ReceiveLine, the post_* functions, the v_* views and the
  reconciliation views

**What it adapts** is the house's way: Atlas Query throughout, PostgreSQL 18
with RLS, text in `ci_ai`, and the cells where · owner · state.

**PostgreSQL 18 minimum.** The house's text columns use `ci_ai`, a
nondeterministic collation, so that text compares the way it did in MySQL:
without case and without accents. LIKE on such a column works from 18 on. The
production server, `_testpg` and any CI image run 18.

---

## 1. The strategy in one paragraph

The **database posts**: one function per business event, one transaction,
balanced rows, every guard inside, every invariant a constraint. Nothing,
whether a module, a script or psql, can write stock or a unit's position another
way: the app's role may only execute the functions (§3.4). The **PHP core gives
it a face**:
- a writing facade with one method per event, inside the caller's transaction
  and each call in its own savepoint, posting a repeated request once, with
  typed exceptions
- a reading API that hands out **Atlas Select objects** over the derived views,
  which a module narrows, splits, pages and joins as it needs, without ever
  knowing the tables underneath

So the modules hold no stock logic at all. They decide (documents) and announce
(events); they ask (selects). Step A puts the reading API in first, on today's
tables, and moves every reader onto it. The switch (step C) redefines what is
under it, and no consumer changes: a test proves it before the switch runs (§9).

**State is derived, never hand-written.** The views are the contract.
Underneath, the posting functions keep each unit's current position and a
balance per cell, in the event's own transaction. Nothing else writes them, and
a check view proves they equal the ledger (§3.2).

## 2. Where it lives

```
/var/sys/core/movements/
  movements.php        the one require: loads the domain (no Composer autoload for core)
  README.md            the consumer guide (§7): how to read, how to set, the rules
  Ledger.php           the writing facade — one method per event (§4)
  Claims.php           intent on documents — attach, hold, fleet (§4)
  Positions.php        the reading API — Atlas Selects over the views (§5)
  Post.php             internal: the one door to the database — key, savepoint, call, translate, decode (§4)
  Cell.php             value object: where · owner · state (a correction's target)
  ReceiveLine.php      value object: one line of a receipt (units by id, or a quantity)
  FlipLine.php         value object: one unit or a quantity to flip
  Kind.php             enum: the events, as facts (received, built, dispatched, arrived, flipped, sold, …)
  State.php            enum: validating | available | written_off
  Reason.php           enum: an adjustment's or a write-off's reason (found, damaged, loss, expired, count)
  Code.php             enum: every refusal code the database raises, with its facts' keys (§6)
  MovementException.php  the base of the exceptions (§6)
  NotFound.php · Refused.php · Forbidden.php · Retry.php

/var/sys/migrations/sql/NNN-*.sql      tables, constraints, roles and grants (§3), as every schema change is
/var/sys/migrations/sql/movements/     one file per function and per view, re-applied when it changes
```

- **Namespace:** `Movements` (`use Movements\Ledger;`), so the domain's names
  clash with nothing in core's global functions.
- **The one line a module needs:** `require_once '/var/sys/core/movements/movements.php';`
- **No module keeps a copy of anything in it.**
- **One file per function and per view,** so the current body of
  `movement_dispatch` is in one place and a review diffs it. If the migration
  runner cannot re-apply a file, the numbered migration that changes a function
  carries it whole, and the folder still holds the current body.

## 3. The database side: the posting engine

### 3.1 What we take from the draft

What we take from the draft, and why it is the industry's way:
- **Each event is one function, one transaction**, and posts complete double
  entries. The PHP backend never assembles multi-table writes: every client
  (PHP, a cron job, psql) posts the same balanced event.
- **The guards are where the data is:**
  - over-receiving refused, measured at the road's net
  - selling a unit that is not here, refused
  - two tills racing for the last unit: the second waits, then is refused (§3.5)
- **Reconciliation views** (`movement_checks_*`) must return no rows.

### 3.2 The invariants are constraints

To be aligned with the layer in `movements.md`. Each invariant is a constraint
the database keeps, not a check a function must remember. The chain, the cell,
the balances, the residence key and the race were tried on PostgreSQL 18
(`docs/probes/ledger.sql`, `race.sh`).

| invariant | how |
|---|---|
| an event balances | every move is one row from a cell to a cell (−qty there, +qty here), under one header row per event; it balances by construction, and the views unfold moves into legs where a report wants them |
| a unit's legs are ±1 | a unit moves by **hops**: one row per hop, so its −1 and +1 are the same row |
| a unit's chain is unbroken | `PRIMARY KEY (serials_id, seq)` and `FOREIGN KEY (serials_id, prev_seq, from-cell) REFERENCES hops (serials_id, seq, to-cell)`: a fork, a skipped step, or a hop from a cell the unit never reached is refused |
| the cell is real | the cell's columns are `NOT NULL` (kind + id), since a foreign key skips its check when any column is NULL; `location_id`, `transfers_id` and `customers_id` are `STORED` generated columns with their own foreign keys |
| nothing negative at a place | a balance row per cell × variant, `CHECK (qty >= 0)`, written only by the functions; the road is a cell, so arriving more than was dispatched is refused too |
| one place at a time | optional, on 18: `unit_residence (serials_id, cell, during)` with `PRIMARY KEY (serials_id, during WITHOUT OVERLAPS)`, which needs `btree_gist` |
| at most one active claim per unit | `unit_claims`, unique on `serials_id WHERE released_at IS NULL` (§3.3) |
| an event posts once | the header's key is `UNIQUE` (§4) |
| only sellable items | materials refused |

**State is derived, never hand-written.** The unit's current hop and the
balances are written only by the posting functions, in the event's transaction.
The hot views read them, so "what is here now" costs what is on the shelf.
Answered from the ledger alone, it costs everything that ever passed through. A
check view proves the projections equal the fold of the ledger.

**Movements are append-only.** A trigger refuses UPDATE, DELETE and TRUNCATE on
the ledger, the owner's included. Mistakes are compensating events, as in
accounting.

### 3.3 What we change from the draft

- **No virtual locations.** The cell is where · owner · state (movements.md):
  the road is a remessa, the customer is a customers row, the state is a word.
- **Claims are the documents' words** (sales.serials_id, transfer_units, the
  fleet). Each claim function writes the document's word together with a
  `unit_claims` row, which is where "one claim per unit" is a constraint. A
  check view proves the two agree. Which claims may coexist (may a fleet unit
  travel on a remessa hold?) is movements.md's to say (§12).
- **The user is the session's** (`app.user`, set by the seat), not a parameter.
  A function refuses when it is unset; cron posts as a named system user.
- **A refusal carries a code and its facts:** SQLSTATE `MVxnn`, and one line of
  DETAIL, `mv:{"message": …, "facts": {…}}`, raised by one helper,
  `mv_refuse(code, message, facts)`. PHP maps by the code and reads that line.
  It never reads PostgreSQL's labels around it, which are translated (§6).
- **Document words that are facts belong to the functions.** `dispatch` sets
  the remessa's `sent` while the column still has that word. A module never
  writes `sent`, `received` or `delivered`. After the switch, the views derive
  them.

### 3.4 Roles and grants

- The ledger's tables and functions belong to a `NOLOGIN` owner role. The app
  connects as a role that owns nothing.
- The app role has `EXECUTE` on the functions and `SELECT` on the views and
  tables. It has no INSERT, UPDATE, DELETE or TRUNCATE on the ledger, the
  projections or `unit_claims`.
- PostgreSQL grants EXECUTE on every new function to PUBLIC, so the owner
  role's default privileges revoke it.
- The functions are `SECURITY DEFINER`, with `SET search_path` pinned.
- RLS does not apply inside them. So authorisation is one helper every function
  calls first (`mv_authorize(kind, location)` → Forbidden), never repeated by
  hand.
- The views are `WITH (security_invoker = true)`, so RLS scopes what a seat
  reads through them exactly as it scopes the tables.
- `app.user` and `app.location` are attribution and scope, not authentication:
  any session may set them. Behind a transaction-pooling pgbouncer, the seat sets
  them with `set_config(…, true)` in each transaction.

### 3.5 Concurrency

- **One lock order.** Every function that touches units first locks their
  `serials` rows, `ORDER BY id FOR NO KEY UPDATE`, and locks balances in
  (cell, variant) order. Claims and movements then wait on the same row.
  `NO KEY` means foreign-key checks from other tables don't wait on it.
- **Under the lock, check and refuse with a code.** The hop key and the CHECKs
  are the backstop. A `unique_violation` on the hop key is caught inside the
  function and raised again as a refusal ("esta moto acabou de ser movida").
- **Postings set `lock_timeout`.** A wait that runs out, a deadlock or a
  serialisation failure reaches PHP as `Retry`.

### 3.6 Time

- A unit's history is ordered by `seq`, the posting order. `occurred_at` is
  business time and `created_at` is system time, both `timestamptz`.
- A unit's `occurred_at` never goes before its last hop's.
- **The lock date:** nothing posts with an `occurred_at` before it (accounting's
  closed period). A correction older than that posts today, with the intended
  date in its note.

### 3.7 Text

- The layer's text columns are `COLLATE ci_ai`, as every migrated table's are.
  A text column a view computes (a CASE, `->>`, `||`) gets `COLLATE ci_ai`
  whenever a module may filter on it.
- Inside the functions, text is compared through table columns, or the
  variables and arrays are declared `COLLATE ci_ai`. Two plain PL/pgSQL
  variables compare with case and accents.
- On ci_ai columns, LIKE and NOT LIKE work. ILIKE, regular expressions and
  `starts_with()` raise errors.
- No trigram index goes on a ci_ai column. It is blind to accents and loses
  matches.

### 3.8 The functions

The functions are in the migrations of steps B–C, and their names and arguments
are the contract.
- Every function takes the **event key** first (`p_key text`, §4) and answers
  `jsonb`. A repeated key gets the first answer back and posts nothing.
- Every function authorises the seat first.

| function | arguments after p_key | answers |
|---|---|---|
| movement_receive | purchase_items_id bigint, received integer, chassis jsonb (a list) | {minted: ids, received} |
| movement_arrive | transfers_id bigint, lines jsonb (ReceiveLine[]) | {received, on_the_road} |
| movement_build / movement_return_to_bench | serials_id integer, assembly_id bigint | {} |
| movement_dispatch | transfers_id bigint | {legs} |
| movement_not_sent / movement_lost | transfers_id bigint, lines jsonb, note text (lost: bears text) | {moved} |
| movement_swap | transfers_id bigint, named integer, real integer, note text | {} |
| movement_flip | from integer, to integer, lines jsonb (FlipLine[]), note text | {flipped} |
| movement_sell / movement_hand_over | orders_id bigint | {moved: lines, waiting: lines without their unit} |
| movement_unsell | sales_id bigint, qty integer, why text | {} |
| movement_return | sales_id bigint, qty integer, location_id integer, why text | {} |
| movement_rent_out / back, movement_loan_out / back | bookings_id / loans_id bigint | {} |
| movement_write_off / movement_to_provider | serials_id integer, reason text, note text, approvals_id bigint | {} |
| movement_adjust | location_id integer, variants_id bigint, delta integer, reason text, note text | {balance} |
| movement_count_close | stock_counts_id bigint | {not_read: units, found: units} (never guessed) |
| movement_correct | serials_id integer, cell jsonb, note text, occurred_at timestamptz | {} |
| movement_unit_remove | serials_id integer, note text | {} |
| claim_attach / claim_replace | sales_id bigint, serials_id integer | {sold: bool}: sold now on a paid line, otherwise held |
| claim_detach | sales_id bigint | {} |
| claim_hold / claim_release | transfers_id bigint, serials_id jsonb (a list) | {held} |
| claim_fleet / claim_fleet_release | serials_id integer, resource id | {} |

- **Lists go as `jsonb`,** not `text[]`. A PHP list bound inline becomes a row,
  not an array, and jsonb is safe for any chassis.
- **Line payloads refuse unknown keys,** so a misspelt key is an error, not a
  default.
- **An approval** names its event and its unit, is approved, and is used once.
- **Count close** compares each line with `stock_at(the line's counted_at)`, so
  sales during the count are not differences. A unit read here that the ledger
  puts elsewhere comes back as `found`, for a person to decide.

### 3.9 The views

These are the read API's ground (§5). They are all `security_invoker`, and
their text columns are `ci_ai`.
- unit_positions
- stock_on_hand
- stock_sellable
- owned_elsewhere (its column doc fixes whether it is "ours, elsewhere" or
  "others', here")
- road
- unit_trajectory (the archived old history, then the ledger)
- movement_list (one row per event, not per leg)
- the time twins `stock_at(t)` and `units_at(t)`, with the same columns as
  stock_on_hand and unit_positions; and `unit_at(id, t)`
- the checks, `movement_checks_*`:
  - the projections equal the ledger
  - the claims agree with their documents
  - time never runs backwards in a unit's history

In step A the views are defined on today's tables; at the switch, on the layer.
The step-A definitions stay as `legacy_*` until C3. They are the oracle of the
switch (§9).

## 4. The writing side: Ledger and Claims

**One method per event**, named for the business. The methods are commands;
`Kind` names the facts in the past tense. Each method:
- **runs inside the caller's transaction.**
  - The events whose documents the module writes (`arrive`, `dispatch`, `sell`,
    `handOver`, `closeCount`) require one, and throw a LogicException without
    it.
  - The others own a transaction when there is none, as serialInTransaction
    does today.
- **runs in its own savepoint.** A Refused rolls back its event alone. The
  caller's transaction stays usable, and rolling it back is the caller's choice.
  Without the savepoint, PostgreSQL refuses every later statement in the
  transaction (`25P02`).
- **carries the event key.** The key is the request's key (the form's or the
  scanner's token, given to the constructor) plus the call's ordinal in the
  request.
  - A repeated key answers with the first answer.
  - `replayed()` tells a request, before it writes its documents, that it has
    already happened: its documents and its postings committed together.
  - Without a request key (a script), every call gets a fresh key.
- **calls its database function through Atlas**, through the one internal door:

  ```php
  // sketch — Post, the one door to the database
  public function call(string $function, array $args): array   // $function: a constant of Ledger or Claims, never input
  {
      $q = Select::new($this->pdo);                             // the PDO under the caller's connection
      $sql = implode(', ', array_map(
          fn(array $a) => 'CAST(' . $q->bindInline($a[1] === 'jsonb' ? json_encode($a[0], JSON_THROW_ON_ERROR) : $a[0]) . " AS {$a[1]})",
          [[$this->key(), 'text'], ...$args],                   // [value, sql type]
      ));
      $q->columns("{$function}({$sql}) AS answer");

      $own = !$this->pdo->inTransaction();
      $own ? $this->pdo->beginTransaction() : $this->pdo->exec('SAVEPOINT movement');
      try {
          $answer = $q->fetchValue();                          // Atlas runs the query here, so translate here
          $own ? $this->pdo->commit() : $this->pdo->exec('RELEASE SAVEPOINT movement');
      } catch (\PDOException $e) {
          $own ? $this->pdo->rollBack() : $this->pdo->exec('ROLLBACK TO SAVEPOINT movement');
          throw MovementException::from($e);                   // by SQLSTATE; message and facts from the mv: line
      }
      return json_decode((string) $answer, true, flags: JSON_THROW_ON_ERROR);
  }
  ```

  This is `SELECT movement_dispatch(CAST(:_1_1_ AS text), CAST(:_1_2_ AS bigint))`,
  the same shape as core's `Select::new($pdo)->columns('app_location()')`. No
  `:name` arrays, no prepare by hand.
- answers what the function answers.

```php
// sketch — the public API (signatures; the docblocks carry the rules)
namespace Movements;

final class Ledger
{
    public function __construct(PDO|\Atlas\Pdo\Connection $db, ?string $requestKey = null) {}

    public function replayed(): bool;                   // this request already posted: answer from the current state, write nothing

    public function receive(int $purchaseItemId, int $received, array $chassis = []): array;  // ['minted' => int[], 'received' => int]
    public function arrive(int $transferId, ReceiveLine ...$lines): array;   // ['received' => int, 'on_the_road' => int]
    public function build(int $serialId, int $assemblyId): void;
    public function returnToBench(int $serialId, int $assemblyId): void;
    public function dispatch(int $transferId): int;     // legs; the remessa becomes 'sent'
    public function notSent(int $transferId, string $note, ReceiveLine ...$lines): array;
    public function lost(int $transferId, string $bears, string $note, ReceiveLine ...$lines): array;
    public function swap(int $transferId, int $namedSerialId, int $realSerialId, string $note): void;
    public function flip(int $from, int $to, string $note, FlipLine ...$lines): array;
    public function sell(int $orderId): array;          // what moved, what waits for its unit
    public function handOver(int $orderId): array;      // Refused for a bike line without its unit
    public function unsell(int $saleId, int $qty, string $why): void;
    public function returnFromCustomer(int $saleId, int $qty, int $locationId, string $why): void;
    public function rentOut(int $bookingId): void;   public function rentBack(int $bookingId): void;
    public function loanOut(int $loanId): void;      public function loanBack(int $loanId): void;
    public function writeOff(int $serialId, Reason $reason, string $note, ?int $approvalId): void;
    public function toProvider(int $serialId, string $note, ?int $approvalId): void;
    public function adjust(int $locationId, int $variantId, int $delta, Reason $reason, string $note): int;  // the new balance
    public function closeCount(int $countId): array;    // ['not_read' => units, 'found' => units]
    public function correct(int $serialId, Cell $to, string $note, ?DateTimeImmutable $occurredAt = null): void;  // admin; never before the lock date
    public function removeUnit(int $serialId, string $note): void;
}

final class Claims
{
    public function __construct(PDO|\Atlas\Pdo\Connection $db, ?string $requestKey = null) {}

    public function attach(int $saleId, int $serialId): array;   // the late attach; on a paid line it sells at once
    public function detach(int $saleId): void;
    public function replace(int $saleId, int $serialId): array;
    public function hold(int $transferId, int ...$serialIds): int;
    public function release(int $transferId, int ...$serialIds): int;
    public function fleetAdd(int $serialId, int $resourceId): void;
    public function fleetRemove(int $serialId): void;
}
```

**Movements and claims are kept apart on purpose:** a claim is intent (a
document's word), a movement is fact. There is one deliberate, documented
exception: `attach()` on a paid line is the sale, so it posts the sale.

## 5. The reading side: Positions — Atlas Selects, not fixed answers

The core does not guess every question a screen will ask. It hands out a
**Select** already built over the right view: its FROM, its documented alias,
its documented columns. The module narrows it with Atlas's additive syntax,
splits it (a page and its total), joins its own tables, or nests it as a
sub-select of its own query. The columns are the contract: their name, type and
collation. They stay the same through the switch, and a test pins them (§8).

```php
// sketch — the reading API
namespace Movements;

final class Positions
{
    public function __construct(PDO|\Atlas\Pdo\Connection $db) {}

    /** FROM unit_positions AS up — serials_id, serial_number, variants_id, sku, item_name,
     *  place_kind, location_id, transfers_id, customers_id, supplier_id, owner_kind,
     *  owner_location_id, owner_customer_id, state, since, claim_kind, claim_ref, word.
     *  Text columns are ci_ai. Fast filters: serials_id; location_id with state; variants_id. */
    public function units(?Select $parent = null, string $as = 'up'): Select;

    /** FROM stock_sellable AS ss — location_id, variants_id, qty (available, minus claims,
     *  minus paid lines waiting for a unit) */
    public function sellable(?Select $parent = null, string $as = 'ss'): Select;

    public function onHand(?Select $parent = null, string $as = 'oh'): Select;          // FROM stock_on_hand
    public function ownedElsewhere(?Select $parent = null, string $as = 'oe'): Select;  // FROM owned_elsewhere
    public function road(?Select $parent = null, string $as = 'rd'): Select;            // per remessa, line, unit
    public function trajectory(int $serialId, ?Select $parent = null): Select;         // FROM unit_trajectory AS ut, in order
    public function movements(?Select $parent = null, string $as = 'ml'): Select;      // Movimentações: one row per event

    // the time axis: the same columns as their present-tense twins
    public function onHandAt(DateTimeImmutable $at, ?Select $parent = null, string $as = 'oh'): Select;  // FROM stock_at(:at)
    public function unitsAt(DateTimeImmutable $at, ?Select $parent = null, string $as = 'up'): Select;   // FROM units_at(:at)

    // conveniences for the commonest single answers
    public function unit(int $serialId): ?array;               // units()->where('up.serials_id = ', $id)->fetchOne()
    public function sellableUnits(int $variantId, int $locationId): array;  // the pickers
    public function count(Select $q): int;                     // COUNT(*) FROM (the select, without order and limit) AS c
}
```

**`?Select $parent`:** a sub-select must be born of its parent (atlas-manual §8:
"Always create a subselect from its parent"). So a consumer passes its own
query, and Positions builds the view onto `$parent->subSelect()`, its bound
values belonging to the consumer's query. The alias is there for a query that
uses the same view twice.

**`count()`** counts the select as a derived table. Resetting its columns
instead would answer one count per group on a grouped or DISTINCT select.

**A point in time is chosen when the Select is born** (`onHandAt`, `unitsAt`),
never by rewriting an existing Select's FROM. Atlas keeps the joins inside the
FROM, and a rewrite would drop the module's joins.

**How a module reads** (sketches of real screens):

```php
use Movements\Positions;

$pos = new Positions($pdo);

// inventory-master's Seriais list — filtered, searched, paged, counted (one Select, split in two)
$units = $pos->units()
    ->where('up.location_id = ', $here)
    ->whereEquals(['up.variants_id' => $variantIds]);           // [] → FALSE, as documented
if ($state !== '') {
    $units->where('up.state = ', $state);
}
if ($q !== '') {                                                 // LIKE: in ci_ai it ignores case and accents; ILIKE is an error there
    $units->whereSprintf('(up.serial_number LIKE %s OR up.sku LIKE %s)', "%{$q}%", "%{$q}%");
}
$total = $pos->count($units);
$rows  = $units->orderBy('up.serial_number')->page($page)->perPage(50)->fetchAll();

// joining the module's own table onto a position
$bench = $pos->units()
    ->join('LEFT', 'assembly AS a', 'a.serials_id = up.serials_id')
    ->columns('a.stage')
    ->where("up.state = 'validating'")
    ->fetchAll();

// nesting: the models this till can sell, inside the module's own catalogue query
$select = Select::new($pdo)->columns('v.id', 'v.sku', 'i.name')->from('variants AS v')
    ->join('INNER', 'items AS i', 'i.id = v.items_id');
$select->where('v.id IN ', $pos->sellable($select)
    ->resetColumns()->columns('ss.variants_id')
    ->where('ss.location_id = ', $here)->where('ss.qty > 0'));

// the passport / Rastrear: a unit's story, or the shelf as it stood on a date
$story = $pos->trajectory($serialId)->fetchAll();
$then  = $pos->onHandAt($countDate)->where('oh.location_id = ', $here)->fetchAll();
```

## 6. Errors: typed, coded, with their facts

```
MovementException  (RuntimeException)    a bug or anything unmapped: logged with an incident id; the operator sees a generic message
 ├── NotFound      SQLSTATE MVN..        the document or unit does not exist
 ├── Refused       SQLSTATE MVR..        the state refuses the event (nothing written); its message is for the operator
 ├── Forbidden     SQLSTATE MVF..        not this location's, not the master's, not an admin
 └── Retry         SQLSTATE 40001 · 40P01 · 55P03   a race lost or a lock wait ran out: "tente novamente"; safe to repeat with the same request key
```

- **The code is the SQLSTATE.** `$e->getCode()` is `'MVR07'` exactly as raised.
  `Code.php` lists every code and its facts' keys. A test fails when a code is
  raised in SQL and missing in PHP, or the other way round.
- **The message and the facts come from one line,** the `mv:` line of DETAIL,
  written by `mv_refuse()`.
  - PostgreSQL's own labels around it (`ERROR:`, `DETAIL:`, `CONTEXT:`) are
    translated by the server's locale and the PHP process's, so PHP never reads
    them.
  - jsonb's text is always one line.
  - `getMessage()` is always for the operator: the database's Portuguese, or
    the generic message.
- **Every exception carries `facts()`:** the serials_id, variants_id and place
  it is about.
- **`Refused::unit()`** builds core's existing `SerialUnavailable` from the
  facts (its whereabouts and its way out), so the screens' toasts and their
  buttons keep working unchanged.
- **The message is written in the database in Portuguese,** where the rule is.
- **A constraint that fires without a coded refusal is a bug.** It is reported
  as one and never shown as PostgreSQL wrote it.
- **The draft's string matching** ("not found", "only draft") is replaced by
  the code.

**In a module's lib.php dispatcher**, beside the existing SerialUnavailable
line:

```php
$result = ["error" => $e->getMessage()]
    + ($e instanceof SerialUnavailable ? ["serial" => $e->facts()] : [])
    + ($e instanceof \Movements\Refused && ($unit = $e->unit()) ? ["serial" => $unit->facts()] : [])
    + ($e instanceof \Movements\MovementException ? ["movement" => $e->facts()] : []);
```

The responses keep today's convention for status and shape. The exception
classes map to HTTP codes only where a screen already handles those codes.

## 7. The consumer guide (README.md in the domain) — what it will say

**Reading (any module):**
- Ask `Positions`. Never read serials.status, location_id or transfers_id,
  `stock`, `stock_balances`, `variants.stock` or `serial_events`. From step A the
  read tripwire fails the build on them; after the switch they no longer exist.
- Narrow the Select; never re-derive. "Sellable" is `sellable()`: do not
  subtract claims yourself.
- Count with `count()`. Never run the query twice, and never count by resetting
  its columns.
- A sub-select comes from your own query: `$pos->units($select)`.
- A date in the past: `onHandAt()`, `unitsAt()`.
- **Searching text:**
  - The text columns are `ci_ai`, so `=` and LIKE ignore case and accents, as
    MySQL did.
  - ILIKE, regular expressions and `starts_with()` raise errors on them.
  - Never put a trigram index on a ci_ai column.

**Setting (a module's functions.php):**
- **Decide in your documents, then announce the fact.** Write the remessa, the
  order or the count with Atlas Insert and Update as today; then one call:
  `$ledger->dispatch($id)`.
- **Never write a document word that is a fact** (`sent`, `received`,
  `delivered`): the event writes it.
- **Inside your transaction.** Ledger and Claims join it, each call in its own
  savepoint. Your commit is the event's commit, and your rollback undoes both.
  The events that go with your documents refuse to run outside your transaction.
- **A Refused undoes only its event**, and your transaction stays usable. Catch
  nothing you cannot handle: let it reach your dispatcher, which rolls the
  request back.
- **A Retry** means the whole request may be tried again. With the same request
  key it cannot post twice.
- **Repeats:** build Ledger and Claims with the request's key. A request that
  posts starts with `if ($ledger->replayed()) …`, answers from the current
  state, and writes nothing.
- **Never write a unit's state, `stock`, `movements` or `positions`** yourself.
  The database refuses it; the tripwire test fails on it.
- **A sale and its unit:**
  - attach with `Claims::attach()` (the late attach)
  - sell with `Ledger::sell()` when paid
  - hand over with `Ledger::handOver()`, which refuses a bike line without its
    unit
  - the POS passes its selected units with the sale and calls sell and
    handOver at once
- **Corrections are movements:** `correct()`, `notSent()`, `swap()`. Never an
  edit.

**For each event, the guide says:**
- who may call it
- what it refuses: its codes and their facts
- what it answers
- an example taken from the module that uses it

**For each view, the guide says:**
- its columns, with their names, types and collations
- the filters that are fast
- the column rule: a column is added, never changed in place; a column that
  will be dropped is announced one release ahead

**Worked examples in the guide** (sketches):

```php
// inventory-master dispatchTransfer — the documents as today, then the fact
$pdo->beginTransaction();
try {
    $ledger = new Ledger($pdo, $requestKey);
    if ($ledger->replayed()) {                       // a resent request: it already happened
        $pdo->rollBack();
        return transferState($transferId);           // answer from the current state, write nothing
    }
    $shopPo = Insert::new($pdo)->into('purchases')->columns([...])->returning('id')->perform()->fetchColumn();
    // … its lines, as today; not transfers.status: dispatch sets 'sent' …
    $ledger->dispatch($transferId);                  // every unit and quantity onto the road; guards inside
    $pdo->commit();
} catch (\Throwable $e) {
    $pdo->rollBack();
    throw $e;                                        // a Refused reaches lib.php: message + facts
}

// frontdesk assignSerial — the late attach (refused: in assembly, not here, claimed, a pré-venda)
$answer = (new Claims($pdo, $requestKey))->attach($saleId, $serialId);   // ['sold' => true] when the line was already paid

// frontdesk markDelivered — the handover; the order's "delivered" is the event's
(new Ledger($pdo, $requestKey))->handOver($orderId);   // Refused: "a moto da linha X ainda não tem chassi"

// assembly assemblyCommitToStock — the state, nothing else
(new Ledger($connection, $requestKey))->build((int) $job['serials_id'], $jobId);
```

## 8. Documentation and proof of the core

- **Each class and method has a docblock** in the house's voice: what it is
  for, what it refuses, what it answers, an example. Each database function
  has a comment block, as 009's do.
- **README.md is the consumer guide** (§7). atlas-manual.txt gains a section on
  composing the domain's Selects.
- **The view contract test:** for every view, the name, type and collation of
  every column, and `security_invoker`. It runs against the A definitions and
  the C definitions.
- **The database's proof:** `atlas-migration/pg/movements-test.php` (a scratch
  schema, as transfer-test.php), on PostgreSQL 18 with ci_ai. It exercises
  every function through Ledger, Claims and Positions:
  - a bike's whole life, and every refusal by its code and its facts
  - RLS: each view, read by another location's seat, returns none of this
    location's rows
  - two connections racing for the same unit, and for the last bulk unit
  - a request repeated with its key posts once
  - a refusal inside a caller's transaction, then the caller carries on
  - the facts read with Portuguese labels: the app's `setlocale` on the PHP
    side, and `lc_messages` pt_BR on the server
  - chassis typed in lower case, and names with accents, through every guard
  - random sequences of events, with every check view empty after each
- **Each module's tests** run against the domain on _testpg (PostgreSQL 18).
- **The tripwires:** the write tripwire fails on any write outside the domain.
  The read tripwire (from step A) fails on any read of legacy state outside it.

## 9. How it comes in (the approved order)

| step | the core | the database | it is done when |
|---|---|---|---|
| A | `Positions` + README (reading) + the value objects and enums it needs; every module read moved onto Positions | the views on today's tables: security_invoker, text in ci_ai, the time twins | the read tripwire passes; the contract test pins every view; no seat reads another location's rows |
| B | `Ledger`, `Claims`, `Post`, the exceptions, README (setting) | the layer's tables and constraints, the roles and grants, the functions, the checks; nothing calls them yet | movements-test.php is green (§8) |
| C1 | — | the opening, rehearsed on a copy of production: an opening hop per unit and a balance per cell × variant; the old history archived for unit_trajectory, not replayed through the new constraints | every `legacy_*` view EXCEPT its layer twin is empty, or matches a written list of expected differences |
| C2 | the modules' setters switch to Ledger and Claims | the views redefined on the layer; the legacy columns kept one release, written from the ledger; the drift views run daily | N days without drift |
| C3 | — | the old state retired, the `legacy_*` views dropped | — |

**Rollback:** once C2 posts, going back would lose postings, so C is
forward-fix only. That is why C1 rehearses the opening on production's own data,
and why C2 keeps the old columns, written from the ledger, for one release.

## 10. For Johan to approve

1. **The split:** the database posts and guards — every invariant a
   constraint, the app's role only executes — and the PHP core is a typed facade
   plus the reading API.
2. **The domain** in `/var/sys/core/movements/`, namespace `Movements`, one
   loader file.
3. **The reading API hands out Atlas Selects over documented views**, which
   modules narrow, split, page, join and nest. Their columns are the contract:
   name, type and collation. The views run with the reader's RLS.
4. **The writing API:** one method per business event (Ledger), claims apart
   (Claims). It runs inside the caller's transaction, each call in its own
   savepoint, and posts a repeated request once. The user is the session's.
5. **Errors:** NotFound, Refused, Forbidden and Retry, by SQLSTATE code, with
   their facts on one `mv:` line. Refused becomes the existing chassis toast.
6. **The consumer guide** as the domain's README, with worked examples from
   the real modules.
7. **The gates:** each step ends on its test (§9), and the switch is rehearsed
   on production's data before it runs. PostgreSQL 18 minimum, everywhere.

## 11. What changed from revision 1

| change | where | review finding |
|---|---|---|
| PostgreSQL 18 minimum; text in ci_ai through the views, the layer and the functions; LIKE, not ILIKE; no trigram index on ci_ai | intro, §3.7, §5, §7 | 1, 2, 14 |
| the views run with the reader's RLS (`security_invoker`) | §3.4, §3.9 | 3 |
| `count()` over a derived table; `onHandAt()` and `unitsAt()` replace `asOf()`; `$parent` replaces `$on`; aliases | §5 | 4 |
| step A moves the readers; the `legacy_*` views are the oracle of the switch | §3.9, §9 | 5 |
| each call in its own savepoint; the documents' events require the caller's transaction | §4, §7 | 6 |
| the event key; `replayed()` | §3.8, §4, §7 | 7 |
| the invariants as constraints (hops, balances, residence, claims); state derived, never hand-written; one lock order | §3.2, §3.5 | 8 |
| the `mv:` line; `Retry`; the code catalogue; bugs never shown raw | §3.3, §6 | 9 |
| the dispatcher emits `serial` for a Refused about a unit | §6 | 10 |
| one call shape: lists as jsonb, every function answers jsonb, translation around the fetch | §3.8, §4 | 11 |
| fact words (`sent`, `delivered`) belong to the functions | §3.3, §7 | 12 |
| roles and grants | §3.4 | 13 |
| time: seq orders, occurred_at never runs backwards, the lock date, timestamptz | §3.6 | 15 |
| `unit_claims` | §3.2, §3.3 | 16 |
| C split into C1–C3, with the rollback stance; each step's gate | §9, §10 | 17 |
| signatures aligned: unsell's qty, notSent's note, writeOff's Reason, adjust's and return's location, build and returnToBench (and their functions), claim_replace, claim_detach | §3.8, §4 | smaller corrections |

## 12. Open questions

For movements.md, or for the business:
- **Which text columns are ci_ai?** On 18, ILIKE raises an error on a ci_ai
  column. If a module searches with ILIKE today, the column it searches is not
  ci_ai, and §7's rule must name the exceptions. On those columns ILIKE ignores
  case but not accents.
- **Is `ci_ai` defined as** `CREATE COLLATION ci_ai (provider = icu, locale = 'und-u-ks-level1', deterministic = false)`?
  The review's probes assumed so.
- **The event catalogue:**
  - back from the provider (unless `to_provider` is final)
  - a customer's bike in for service (here, but the customer's)
  - parts consumed by assembly or the workshop
  - what `removeUnit` means for the chassis: may it be minted again?
  - bulk on a draft remessa: held, or not?
- **A customer's return:** does it land `validating` (inspection) or
  `available`?
- **`owned_elsewhere`:** ours elsewhere, or others' here? Or both, as two views?
- **Cost:** do movements carry `unit_cost` from now on (valuation, CMV), or is
  valuation out of scope? Either way, the plan should say so.
- **Fiscal:** does `flip` or `dispatch` need an authorised NF-e first? If so,
  the function checks it as a precondition.
- **Which claims may coexist:** may a fleet unit travel on a remessa hold?
