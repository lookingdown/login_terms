# The cube, for its consumers

The layer keeps every bike's line through place, owner and state over time, beside the plans its
documents hold for it. A consumer reaches all of it through one shape, **axes in, dots out**. A screen, a
report or a map reads every angle the same way, and a unit's next event goes in through the same door.

```php
require_once '/var/sys/core/movements/movements.php';

cube($pdo, $axes)                           // the dots, as rows
cubeSelect($pdo, $axes[, $parent, $as])     // the same dots as an Atlas Select: narrow, page, group, join, nest
cubeDot($pdo, $axes[, $action, $with])      // one unit's dot; with an action, the unit is advanced first
cubeConflicts($pdo[, $parent, $as])         // the encounters that cannot happen
```

## The dot

Every answer is a list of these, whatever the angle:

```php
['unit' => 504, 'model' => 100, 'layer' => 'fact',
 'place' => 'location:1', 'owner' => 'location:1', 'state' => 'available',
 'starts' => '2026-10-31 09:12:40', 'ends' => null,
 'why' => 'built', 'ref' => 6, 'customer' => null]
```

| key | what |
|---|---|
| `unit`, `model` | the serial (`serials_id`) and its model (`variants_id`) |
| `layer` | `fact`: it happened. `plan`: a document intends it |
| `place` | where: `location:2`, `road:55` (a remessa on its way), `customer:7`, `supplier:3`, `books` |
| `owner` | whose, in the same coordinates. A plan has none |
| `state` | `validating`, `available`, `written_off`. A plan has none |
| `starts`, `ends` | its stretch of time. `ends` null: it runs on. `starts` = `ends`: an instant (two events in one second) |
| `why`, `ref` | what put it there. A fact: its movement's kind and id. A plan: its kind and its document's id |
| `customer` | the customer in it, if any |

A plan's `why` names its document: `rental` is a booking, `appointment` a workshop appointment, `service`
a service order, `loan` a loan, `reserved` an order's hold.

## The axes

Each axis takes a point to cut, or a list to widen. Left out, it stays whole. Axes combine with AND.

| axis | takes | e.g. |
|---|---|---|
| `at` | a moment | `'at' => '2026-10-15 12:00'` |
| `between` | a period `[from, to)`, either end null | `'between' => ['2026-10-01', null]` |
| `unit` | `serials_id`, or several | `'unit' => [502, 504]` |
| `model` | `variants_id`, or several | `'model' => 100` |
| `place` | a coordinate, or several | `'place' => ['location:1', 'location:2']` |
| `owner` | a coordinate, or several | `'owner' => 'location:1'` |
| `state` | a state, or several | `'state' => 'validating'` |
| `customer` | `customers_id`, or several | `'customer' => 7` |
| `layer` | `fact` or `plan` | `'layer' => 'fact'` |
| `known` | a moment: the books as they stood then | `'known' => '2026-10-15'` |

- **A moment** is a `DateTimeInterface`, or anything `DateTimeImmutable` reads (`'2026-10-15 12:00'`,
  `'saturday 12:00'`). `'now'` is the database's clock, wherever a moment goes.
- **At a moment** each unit has one fact, the cell it stood in then, and the plans that hold it then.
- **Over a period** you get every dot that touches it, instants included.
- `owner` and `state` are a fact's. Cutting on either leaves the plans out.
- Rows come by unit, then by time.
- **A wrong question never answers the whole cube.** An unknown axis (`units`), `at` with `between`, or a
  place that is no coordinate throws `InvalidArgumentException`.

## Every angle, one call

```php
// a slice: where every bike was at a moment
cube($pdo, ['at' => '2026-10-15 12:00', 'layer' => 'fact']);

// the same slice as the screen showed it then: the second clock
cube($pdo, ['at' => '2026-10-15 12:00', 'known' => '2026-10-15 12:00']);

// a unit's line, its passport: its stays from receipt to now, then its plans
cube($pdo, ['unit' => 502]);

// a place over a period: who stood at the master in October
cube($pdo, ['place' => 'location:1', 'between' => ['2026-10-01', '2026-11-01']]);

// a place ahead: what is expected at Prudente from now on
cube($pdo, ['place' => 'location:2', 'between' => ['now', null], 'layer' => 'plan']);

// a customer: every dot they are in, their bikes, rentals, appointments and service
cube($pdo, ['customer' => 7]);

// where customer 7's bikes will be on Saturday at noon
cube($pdo, ['customer' => 7, 'at' => 'saturday 12:00']);

// the bench: what the master has validating now
cube($pdo, ['at' => 'now', 'state' => 'validating', 'owner' => 'location:1']);

// parada há 30 dias: available at Prudente, in the same cell for 30 days or more
cubeSelect($pdo, ['at' => 'now', 'state' => 'available', 'place' => 'location:2'])
    ->where('c.starts <= ', (new DateTimeImmutable('-30 days'))->format('Y-m-d H:i:s'))->fetchAll();

// a model per place, now
cubeSelect($pdo, ['at' => 'now', 'model' => 100, 'layer' => 'fact'])
    ->resetColumns()->columns('c.place', 'COUNT(*)')->groupBy('c.place')->fetchKeyPair();

// a list screen, counted and paged
$dots = cubeSelect($pdo, ['place' => 'location:1', 'between' => ['2026-10-01', null]]);
$total = positionsCount($pdo, $dots);
$page = $dots->limit(50)->offset(100)->fetchAll();

// nested in a module's own query: the serials on a bench now
$select = Select::new($pdo)->columns('s.id', 's.serial_number')->from('serials AS s');
$select->where('s.id IN ', cubeSelect($pdo, ['at' => 'now', 'state' => 'validating'], $select)
    ->resetColumns()->columns('c.unit'));

// what cannot happen: two plans at once, a plan where the bike will not be
cubeConflicts($pdo)->where('wc.serials_id = ', 502)->fetchAll();
```

## One dot, and its actions

```php
cubeDot($pdo, ['unit' => 504]);                                 // now: where, whose, what, since when
cubeDot($pdo, ['unit' => 504, 'at' => '2026-10-15 12:00']);     // then
cubeDot($pdo, ['unit' => 504], 'built', ['assembly' => 81]);    // advanced: the dot it is in afterwards
```

- `cubeDot()` answers one fact, or null when the unit stood nowhere then (not received yet).
- **An action is the event that moves the unit**, under its movement's name. One word does three jobs: the
  action you call, the movement it posts, and the `why` of the dot it leaves.
- **An action happens now, to that unit alone.** Give it the `unit` and nothing else; to date an event back,
  post a correction. `$with` carries what the event needs.
- An unknown action or a missing need throws `InvalidArgumentException` before anything is sent.
- **The database holds the rules.** A refusal throws `MovementRefused`, and nothing is posted. It carries
  `sqlState` (`MV0nn`), an English message for the log, and `facts`. The code is the i18n key: the screen shows
  `t('message.mvRefused_' + code, refusalParams(t, facts))`, with the words in `i18n/movements.js`.
- Inside the caller's transaction the action takes a savepoint, so a refusal undoes that event alone. A
  module lets the `MovementRefused` reach lib.php, like every other event.

| action | needs | refused when |
|---|---|---|
| `built` | `assembly` | MV020 the unit is unknown; MV021 it is not the job's; MV022 it is not validating where its owner stands; MV023 it is another shop's |
| `back_to_bench` | `assembly` | MV020, MV021 and MV023 as `built`; MV025 it is not available where its owner stands; MV024 an order, a remessa draft or the fleet holds it |
| `written_off` | `approval`, `note` | MV082 not the master; MV081 not in stock or on the bench where its owner stands; MV055 something holds it; MV080 no baixa_moto approval for this unit |
| `to_provider` | `approval`; `supplier`, `note` | as `written_off`; MV083 no supplier named and none it was bought from |
| `flipped` | `to` (a location id); `note` | MV130 not the master's admin or superadmin; MV131 not from one active location to another (a unit that stands at none has none to go from); MV020 the unit is unknown; MV091 it is not available where its owner stands; MV055 something holds it |

The actions to come, each on the same pattern (plan §2, code §4). The needs are a proposal:

| action | event | needs | step |
|---|---|---|---|
| `workshop_in`, `workshop_out` | 18, 19 | `service_order` | F |
| `corrected` | 24 | `place`, `owner`, `state`, `note` | |

Adding one takes three pieces: its database function on `movement_dispatch`'s pattern, its function in
`ledger.php`, and one line in `cubeActions()`. The consumer's call does not change.

**A document's events are not a dot's actions.** A delivery received, a remessa dispatched or arrived, a
sale, its handover or undoing, an adjustment, a count and the opening each move many dots, or dots and
counted goods, at once. A rental and a loan move one dot, but their document names it, and its customer:
the screen holds the booking or the loan, not the bike. They stay on their document's function
(`movementDispatch()`, `movementRentOut()` and code §4's others), and the dots they leave read like any other:
a bike out on a rental or a loan stands at `customer:<id>`, its location's still, its word `rented` or `loaned`.

## What a dot is not, yet

- **Counted goods** (a helmet) have no identity, so they have no line and no dot. They are quantities:
  `positions` now, `stock_at(t)` at a moment, `positionsRoad()` on a road.
- **Some lines have no forward end yet.** An appointment has no length, and a sold bike's handover date is
  not planned anywhere (a remessa's expected arrival is asked at dispatch, MV018). CUBE.md lists what would make them whole.
- **A seat sees its part.** RLS cuts the cube before the axes do. A shop's seat sees the dots at its floor
  and on the roads to and from it; the master sees everything.

## Under the door

`cubeSelect()` calls `cube_dots()` in `sql/cube.sql`, which has one parameter per axis, so the same cuts
work in psql:

```sql
SELECT * FROM cube_dots(p_units => '{502}');
SELECT * FROM cube_dots(tsrange('2026-10-01', '2026-11-01'), p_places => '{location:1}');
```

It draws the facts from the legs on each call, and that is what gives the second clock and the instants.
When the legs grow large, the as-known-now cut can read `unit_residence` instead, which is indexed. The
door would not change.
