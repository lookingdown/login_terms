# The movement domain in system core — strategy and design (for approval)

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

**What it adapts** is the house's way: Atlas Query throughout, PostgreSQL with
RLS, and the cells where · owner · state.

---

## 1. The strategy in one paragraph

The **database posts**: one function per business event, one transaction,
balanced rows, every guard inside, every invariant a constraint. Nothing,
whether a module, a script or psql, can write stock or a unit's position another
way. The **PHP core gives it a face**:
- a writing facade with one method per event, joining the caller's
  transaction, with typed exceptions
- a reading API that hands out **Atlas Select objects** over the derived views,
  which a module narrows, splits, pages and joins as it needs, without ever
  knowing the tables underneath

So the modules hold no stock logic at all. They decide (documents) and announce
(events); they ask (selects). Step A puts the reading API in first, on today's
tables. The switch (step C) redefines what is under it, and no consumer changes.

## 2. Where it lives

```
/var/sys/core/movements/
  movements.php        the one require: loads the domain (no Composer autoload for core)
  README.md            the consumer guide (§7): how to read, how to set, the rules
  Ledger.php           the writing facade — one method per event (§4)
  Claims.php           intent on documents — attach, hold, fleet (§4)
  Positions.php        the reading API — Atlas Selects over the views (§5)
  Cell.php             value object: where · owner · state (a correction's target)
  ReceiveLine.php      value object: one line of a receipt (units by id, or a quantity)
  FlipLine.php         value object: one unit or a quantity to flip
  Kind.php             enum: the events (received, built, dispatched, arrived, flipped, sold, …)
  State.php            enum: validating | available | written_off
  Reason.php           enum: an adjustment's reason (found, damaged, loss, expired, count)
  MovementException.php  the base of the exceptions (§6)
  NotFound.php · Refused.php · Forbidden.php

/var/sys/migrations/sql/NNN-*.sql   the database side (§3), as every schema change is
```

- **Namespace:** `Movements` (`use Movements\Ledger;`), so the domain's names
  clash with nothing in core's global functions.
- **The one line a module needs:** `require_once '/var/sys/core/movements/movements.php';`
- **No module keeps a copy of anything in it.**

## 3. The database side: the posting engine

What we take from the draft, and why it is the industry's way:
- **Each event is one function, one transaction**, and posts complete double
  entries. The PHP backend never assembles multi-table writes: every client
  (PHP, a cron job, psql) posts the same balanced event.
- **The guards are where the data is:**
  - over-receiving refused, measured at the road's net
  - selling a unit that is not here, refused
  - two tills racing for the last unit, serialised by the lock
- **The invariants are constraints:**
  - a unit's legs are ±1
  - a unit's chain is unbroken
  - nothing negative at a place
  - only sellable items (materials refused)
- **Reconciliation views** (`movement_checks_*`) must return no rows.
- **State is a query** (views), never a column.

What we change from the draft:
- **No virtual locations.** The cell is where · owner · state (movements.md):
  the road is a remessa, the customer is a customers row, the state is a word.
- **Claims are functions of the documents** that hold them (sales.serials_id,
  transfer_units, the fleet).
- **The user is the session's** (`app.user`, set by the seat), not a parameter.
- **A refusal carries a code and its facts** (SQLSTATE `MVxnn`, DETAIL as
  JSON), so PHP maps it by code, never by parsing words.

**The functions** (in the migrations of steps B–C; their names and arguments
are the contract):

| function | arguments | answers |
|---|---|---|
| movement_receive | purchase_items_id bigint, received integer, chassis text[] | jsonb: units minted (ids), received |
| movement_arrive | transfers_id bigint, lines jsonb (ReceiveLine[]) | jsonb: received, still on the road |
| movement_built / movement_back_to_bench | serials_id integer, assembly_id bigint | void |
| movement_dispatch | transfers_id bigint | integer: legs |
| movement_not_sent / movement_lost | transfers_id bigint, lines jsonb, note text (lost: bears text) | jsonb |
| movement_swap | transfers_id bigint, named integer, real integer, note text | void |
| movement_flip | from integer, to integer, lines jsonb (FlipLine[]), note text | jsonb |
| movement_sell / movement_hand_over | orders_id bigint | jsonb: lines moved, lines waiting for a unit |
| movement_unsell / movement_return | sales_id bigint, qty integer, why text | void |
| movement_rent_out / back, movement_loan_out / back | bookings_id / loans_id bigint | void |
| movement_write_off / movement_to_provider | serials_id integer, reason text, note text, approvals_id bigint | void |
| movement_adjust | variants_id bigint, delta integer, reason text, note text | integer: the new balance |
| movement_count_close | stock_counts_id bigint | table: the units not read (never guessed) |
| movement_correct | serials_id integer, cell jsonb, note text, occurred_at timestamp | void |
| movement_unit_remove | serials_id integer, note text | void |
| claim_attach / claim_detach | sales_id bigint, serials_id integer | jsonb: sold now (a paid line) or held |
| claim_hold / claim_release | transfers_id bigint, serials_id integer[] | integer |
| claim_fleet / claim_fleet_release | serials_id integer, resource id | void |

**The views** (the read API's ground, §5):
- unit_positions
- stock_on_hand
- stock_sellable
- owned_elsewhere
- road
- unit_trajectory
- movement_list
- the point-in-time functions stock_at(t) and unit_at(id, t)

In step A they are defined on today's tables; at the switch, on the layer.

## 4. The writing side: Ledger and Claims

**One method per event**, named for the business, not the table. Each one:
- joins the caller's transaction, or owns one (the draft's `tx()`, as
  serialInTransaction does today)
- calls its database function **through Atlas**:

  ```php
  // sketch — Ledger's one private door to the database
  private function post(string $function, array $args): Select
  {
      $q = Select::new($this->pdo);
      $call = implode(', ', array_map(
          fn(array $a) => 'CAST(' . $q->bindInline($a[0]) . ' AS ' . $a[1] . ')',   // [value, sql type]
          $args,
      ));
      return $q->columns("{$function}({$call}) AS result");   // the caller fetches: fetchValue / fetchOne
  }
  ```

  This is `SELECT movement_dispatch(CAST(:_1_1_ AS bigint))`, the same shape as
  core's `Select::new($pdo)->columns('app_location()')`. No `:name` arrays, no
  prepare by hand.
- translates a refusal into a typed exception (§6), and answers what the
  function answers, typed.

```php
// sketch — the public API (signatures; the docblocks carry the rules)
namespace Movements;

final class Ledger
{
    public function __construct(PDO|\Atlas\Pdo\Connection $db) {}

    public function receive(int $purchaseItemId, int $received, array $chassis = []): array;  // ['minted' => int[], 'received' => int]
    public function arrive(int $transferId, ReceiveLine ...$lines): array;
    public function built(int $serialId, int $assemblyId): void;
    public function backToBench(int $serialId, int $assemblyId): void;
    public function dispatch(int $transferId): int;
    public function notSent(int $transferId, ReceiveLine ...$lines): array;
    public function lost(int $transferId, string $bears, string $note, ReceiveLine ...$lines): array;
    public function swap(int $transferId, int $namedSerialId, int $realSerialId, string $note): void;
    public function flip(int $from, int $to, string $note, FlipLine ...$lines): array;
    public function sell(int $orderId): array;          // what moved, what waits for its unit
    public function handOver(int $orderId): array;      // Refused for a bike line without its unit
    public function unsell(int $saleId, string $why): void;
    public function returnFromCustomer(int $saleId, int $qty, string $why): void;
    public function rentOut(int $bookingId): void;   public function rentBack(int $bookingId): void;
    public function loanOut(int $loanId): void;      public function loanBack(int $loanId): void;
    public function writeOff(int $serialId, string $reason, string $note, ?int $approvalId): void;
    public function toProvider(int $serialId, string $note, ?int $approvalId): void;
    public function adjust(int $variantId, int $delta, Reason $reason, string $note): int;
    public function closeCount(int $countId): array;    // the units not read
    public function correct(int $serialId, Cell $to, string $note, ?DateTimeImmutable $occurredAt = null): void;
    public function removeUnit(int $serialId, string $note): void;
}

final class Claims
{
    public function attach(int $saleId, int $serialId): array;   // the late attach; sells at once on a paid line
    public function detach(int $saleId): void;
    public function replace(int $saleId, int $serialId): array;
    public function hold(int $transferId, int ...$serialIds): int;
    public function release(int $transferId, int ...$serialIds): int;
    public function fleetAdd(int $serialId, int $resourceId): void;
    public function fleetRemove(int $serialId): void;
}
```

**Movements and claims are kept apart on purpose:** a claim is intent (a
document's word), a movement is fact.

## 5. The reading side: Positions — Atlas Selects, not fixed answers

The core does not guess every question a screen will ask. It hands out a
**Select** already built over the right view: its FROM, its documented alias,
its documented columns. The module narrows it with Atlas's additive syntax,
splits it (a page and its total), joins its own tables, or nests it as a
sub-select of its own query. The columns are the contract, and they stay the
same through the switch.

```php
// sketch — the reading API
namespace Movements;

final class Positions
{
    public function __construct(PDO|\Atlas\Pdo\Connection $db) {}

    /** FROM unit_positions AS up — serials_id, serial_number, variants_id, sku, item_name,
     *  place_kind, location_id, transfers_id, customers_id, supplier_id, owner_kind,
     *  owner_location_id, owner_customer_id, state, since, claim_kind, claim_ref, word */
    public function units(?Select $on = null): Select;

    /** FROM stock_sellable AS ss — location_id, variants_id, qty (available, minus claims,
     *  minus paid lines waiting for a unit) */
    public function sellable(?Select $on = null): Select;

    public function onHand(?Select $on = null): Select;        // FROM stock_on_hand AS oh
    public function ownedElsewhere(?Select $on = null): Select; // FROM owned_elsewhere AS oe
    public function road(?Select $on = null): Select;          // FROM road AS rd — per remessa, line, unit
    public function trajectory(int $serialId): Select;         // FROM unit_trajectory AS ut, in order
    public function movements(?Select $on = null): Select;     // FROM movement_list AS ml — Movimentações

    // conveniences for the commonest single answers
    public function unit(int $serialId): ?array;               // units()->where('up.serials_id = ', $id)->fetchOne()
    public function sellableUnits(int $variantId, int $locationId): array;  // the pickers
    public function count(Select $q): int;                     // clone, resetColumns/OrderBy/Limit, COUNT(*)
    public function asOf(Select $q, DateTimeImmutable $at): Select;         // the time axis
}
```

**`?Select $on`:** a sub-select must be born of its parent (atlas-manual §8:
"Always create a subselect from its parent"). So a consumer passes
`$select->subSelect()` and gets the view built onto it, its bound values
belonging to the consumer's own query.

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
if ($q !== '') {
    $units->whereSprintf('(up.serial_number LIKE %s OR up.sku LIKE %s)', "%{$q}%", "%{$q}%");
}
$total = $pos->count($units);                                    // clone + resets inside
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
$select->where('v.id IN ', $pos->sellable($select->subSelect())
    ->resetColumns()->columns('ss.variants_id')
    ->where('ss.location_id = ', $here)->where('ss.qty > 0'));

// the passport / Rastrear: a unit's story, or as it stood on a date
$story = $pos->trajectory($serialId)->fetchAll();
$then  = $pos->asOf($pos->onHand()->where('oh.location_id = ', $here), $countDate)->fetchAll();
```

## 6. Errors: typed, coded, with their facts

```
MovementException  (RuntimeException)    anything else from the domain
 ├── NotFound      SQLSTATE MVN..        the document or unit does not exist          → the module's 404 / error
 ├── Refused       SQLSTATE MVR..        the state refuses the event (nothing written) → 409; its message is for the operator
 └── Forbidden     SQLSTATE MVF..        not this location's, not the master's, not an admin → 403
```

- **Every exception carries `facts()`**, the DETAIL JSON: the serials_id,
  variants_id and place it is about.
- **`Refused::unit()`** builds core's existing `SerialUnavailable` from the
  facts (its whereabouts and its way out), so the screens' toasts and their
  buttons keep working unchanged.
- **The message is written in the database in Portuguese,** where the rule is.
- **The draft's string matching** ("not found", "only draft") is replaced by
  the code.

**In a module's lib.php dispatcher**, the one line beside the existing
SerialUnavailable one:

```php
$result = ["error" => $e->getMessage()]
    + ($e instanceof SerialUnavailable ? ["serial" => $e->facts()] : [])
    + ($e instanceof \Movements\MovementException ? ["movement" => $e->facts()] : []);
```

## 7. The consumer guide (README.md in the domain) — what it will say

**Reading (any module):**
- Ask `Positions`. Never read serials.status, location_id or transfers_id,
  `stock`, `stock_balances` or `variants.stock`; after the switch they no longer
  exist.
- Narrow the Select; never re-derive. "Sellable" is `sellable()`: do not
  subtract claims yourself.
- Count with `count()`, or clone and reset. Never run the query twice by hand.
- A sub-select comes from your own query: `$pos->units($select->subSelect())`.

**Setting (a module's functions.php):**
- **Decide in your documents, then announce the fact.** Write the remessa, the
  order or the count with Atlas Insert and Update as today; then one call:
  `$ledger->dispatch($id)`.
- **Inside your transaction.** Ledger and Claims join it; your commit is the
  event's commit, and your rollback undoes both.
- **Never write a unit's state, `stock`, `movements` or `positions`** yourself.
  The database refuses it; the tripwire test fails on it.
- **Catch nothing you cannot handle.** A `Refused` is the operator's message:
  let it reach your dispatcher.
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
- what it refuses
- what it answers
- an example taken from the module that uses it

**Worked examples in the guide** (sketches):

```php
// inventory-master dispatchTransfer — the documents as today, then the fact
$pdo->beginTransaction();
try {
    $shopPo = Insert::new($pdo)->into('purchases')->columns([...])->returning('id')->perform()->fetchColumn();
    // … its lines, transfers.status = 'sent', as today …
    (new Ledger($pdo))->dispatch($transferId);       // every unit and quantity onto the road; guards inside
    $pdo->commit();
} catch (\Throwable $e) {
    $pdo->rollBack();
    throw $e;                                        // a Refused reaches lib.php: message + facts
}

// frontdesk assignSerial — the late attach (refused: in assembly, not here, claimed, a pré-venda)
$answer = (new Claims($pdo))->attach($saleId, $serialId);   // ['sold' => true] when the line was already paid

// frontdesk markDelivered — the handover, beside the order's own words
(new Ledger($pdo))->handOver($orderId);              // Refused: "a moto da linha X ainda não tem chassi"

// assembly assemblyCommitToStock — the state, nothing else
(new Ledger($connection))->built((int) $job['serials_id'], $jobId);
```

## 8. Documentation and proof of the core

- **Each class and method has a docblock** in the house's voice: what it is
  for, what it refuses, what it answers, an example. Each database function
  has a comment block, as 009's do.
- **README.md is the consumer guide** (§7). atlas-manual.txt gains a section on
  composing the domain's Selects.
- **The database's proof:** `atlas-migration/pg/movements-test.php` (a scratch
  schema, as transfer-test.php). It exercises every function through Ledger,
  Claims and Positions: a bike's whole life, every refusal, RLS, the
  reconciliation views empty.
- **Each module's tests** run against the domain on _testpg.
- **The tripwire test** fails on any write outside it.

## 9. How it comes in (the approved order)

| step | the core | the database |
|---|---|---|
| A | `Positions` + README (reading) + the value objects and enums it needs | the views on today's tables |
| B | `Ledger`, `Claims`, the exceptions, the value objects, README (setting) | the layer's tables, the functions, the checks; nothing calls them yet |
| C | the modules' setters switch to Ledger and Claims | the views redefined on the layer, the opening (the history ported), the old state retired |

## 10. For Johan to approve

1. **The split:** the database posts and guards; the PHP core is a typed facade
   plus the reading API.
2. **The domain** in `/var/sys/core/movements/`, namespace `Movements`, one
   loader file.
3. **The reading API hands out Atlas Selects over documented views**, which
   modules narrow, split, page, join and nest. Their columns are the contract.
4. **The writing API:** one method per business event (Ledger), claims apart
   (Claims). The user is the session's.
5. **Errors:** NotFound, Refused and Forbidden, by SQLSTATE code, with their
   facts; Refused becomes the existing chassis toast.
6. **The consumer guide** as the domain's README, with worked examples from
   the real modules.
