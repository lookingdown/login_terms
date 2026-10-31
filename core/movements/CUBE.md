# The cube

The movement layer is a transport layer. It knows where every entity is at any moment, because it
keeps the line each entity draws through place, owner and state over time. "Now" is not a stored
value. It is one cut through those lines: the last entry of each.

## The shape

A bike's life is a line through four axes:

- **where:** a location, the road of a remessa, a customer, a supplier
- **whose:** a location, a customer, a supplier
- **what:** validating, available, written off
- **when:** business time, when it happened; beside it system time, when it was recorded

Every movement is a point where the line turns. Between two movements the line runs straight: a
**stay**. The past is facts (the legs, and the stays they form). The future is intent: the stays its
documents plan, here called **waypoints** — a rental, an appointment, a service order, a loan, an
order's hold, a remessa's arrival.

Any question is a cut through the cube. The answer comes back flat, as rows, but the cut is what the
question means:

| hold fixed | you get | in PHP (CONSUMERS.md) |
|---|---|---|
| a moment | a slice: every entity's place then | `cube($pdo, ['at' => $t])` |
| a moment, and a moment of knowing | the books as they stood then: what we believed, not what we know now | `cube($pdo, ['at' => $t, 'known' => $k])` |
| an entity | its line, from receipt to now, then its plans | `cube($pdo, ['unit' => 502])` |
| a place and a period | occupancy: who stood there, from when to when | `cube($pdo, ['place' => 'location:1', 'between' => [$a, $b]])` |
| a place, ahead | who is expected there, and when | `cube($pdo, ['place' => 'location:2', 'between' => ['now', null], 'layer' => 'plan'])` |
| two lines | an encounter: the same place at overlapping times | `cubeConflicts($pdo)` |
| a plan and its fact | variance: early, late, missed | `unit_waypoints.planned` beside `.actual` |

A status column is this cube cut at now and thrown away each time it is overwritten. The layer
keeps the lines. So "now" is one cut among all of them, history is not a log kept beside the
state but the state itself, and questions nobody thought of when it was built can still be asked.

## The axes

The cube is dots. Each dot is a unit, in a place, of an owner, in a state, for a stretch of time, for a
reason. Nothing asks a table for rows. Hold one axis at a value and you get every angle of the rest. An
axis takes a point to cut, a range or a set to widen, or nothing to stay whole. Every answer has the same
shape, dots, so a screen or a map draws any cut the same way.

| axis | at a point | widened |
|---|---|---|
| time | a moment: every unit, its place, owner and state then | a period: every stay that touches it |
| unit | a serial number: every moment of its life, then its plans | a model: every unit of it |
| place | a location, a road, a customer: who stands there | a set of places |
| customer | every dot they take part in: their bikes, rentals, appointments, service | |
| knowing | the books as they stood at a moment (the second clock) | |

In SQL, `cube_dots()` takes one parameter per axis. In PHP, `cube()` answers the dots, `cubeSelect()` gives
them as a Select like the other readers, and `cubeDot()` gives one unit's dot, advanced first by an action
when one is given. CONSUMERS.md has the shape, every axis and every angle:

```php
cube($pdo, ['at' => '2026-11-11 15:50']);                                      // every angle of that moment
cube($pdo, ['unit' => 502]);                                                   // every moment of that unit
cube($pdo, ['place' => 'location:1', 'between' => ['2026-10-01', '2026-11-01']]);  // who stood at the master in October
cube($pdo, ['customer' => 7, 'at' => 'saturday 12:00']);                       // where customer 7's bikes will be on Saturday
cubeDot($pdo, ['unit' => 504], 'built', ['assembly' => 81]);                   // the bike passed assembly: its dot now
```

## A map beside the territory

The cube is not a second system of record. It is a map drawn from the system's own records: the
movements for the facts, the documents for the plans.
- It is kept in the same transaction as the records it reads, so it is never behind.
- It can be drawn again from them at any time: `unit_residence` is rebuilt from the legs.
- The health checks compare the map with the territory.

## What it answers here

- **Where every bike was on any date:** the day of a count, a night of a theft, the accountant's year end.
- **Since when it stands where it stands:** parada há N dias, time in assembly, time on the road per trip.
- **What we believed on a date against what we know now:** "the screen said in stock when we sold it".
- **The passport:** a bike's whole line as one identity, sold, returned and sold again.
- **The roster ahead:** rentals, appointments, service orders, loans and holds, with the collisions found before they happen. One bike booked twice; a customer at a shop at 10:00 for a bike that will still be on the road.
- **Plan against fact:** purchases late, service orders overdue, rentals collected late.

## The fleet, read as a cube from today's history

`sql/cube-legacy.sql` reads the history the tables already hold (`serial_events`, the paid sale lines,
the documents' dates) as the opening will port it. On the dump of 30 October:

| moment | at the master | at PRU | at CDV | on the road | the customers' | not yet known |
|---|---|---|---|---|---|---|
| 21 Sep, before the history | 0 | 0 | 0 | 0 | 53 | 45 |
| 22 Sep 12:00 | 31 | 0 | 0 | 0 | 53 | 14 |
| 23 Sep 12:00 | 26 | 6 | 0 | 0 | 54 | 12 |
| 10 Oct 12:00 | 17 | 7 | 0 | 0 | 68 | 6 |
| 21 Oct, end of the history | 11 | 10 | 0 | 0 | 77 | 0 |

What the cut shows:
- **The two clocks diverge.** Unit 69's received, dispatched and arrived were *recorded* on 21 Oct and *happened* on 22 Sep. Its seed was recorded first and says "sold" at 22 Sep 13:48, but the bike was paid for on 24 Sep. Asked "as the books stood on 10 Oct", these events did not exist yet.
- **Trips and shelves.** 27 trips spent from 15 seconds to 3 days on the road (3 h on average). Bikes stood from 4 hours to 21 days at a shop before being paid for (2½ days on average).
- **A bad date surfaces.** Of 47 purchases with an expected date, 16 were late. One was 1,461 days late: a mistyped year.
- **The workshop.** Of 9 service orders with a bike, 5 are done (3 late, by up to 2 days) and 4 are open since August and September.
- **An entity without an identity has no line.** CDV holds no unit in any slice, yet it sold 8 MINI DRIFT: they moved as quantities, without units (diagnostics D7, D8).
- **What the history cannot say.** 77 bikes were paid for and 1 handover was recorded, so where a sold bike is, at the shop or with its customer, is not known. None of the 28 remessas has an expected arrival.

## What makes the cube whole

Small, and in the documents rather than in the layer:

1. **A remessa's expected arrival** (a date on `transfers`). The road then has a forward end, so "will the bike be at Prudente on Saturday?" has an answer.
2. **The handover as an event.** It already is one in the plan (`movementHandOver`), and then a sold bike's place is known.
3. **An assembly job's expected ready date.** The validating stay gets a planned end: the green bike that is ready on Monday.
4. **A unit for every bike that moves.** That is the discrepancies settled before the opening.
5. **An appointment's length,** or its service order's expected date. An encounter needs both ends; for now an appointment is a moment.

## In the database

`sql/cube.sql`, after `sql/layer.sql`, tested on the pg_dump schema with its forced RLS (`tests/cube-test.sql`; `tests/core-test.php` runs the PHP side):

- **`unit_residence`:** the stays, kept from the legs in the same transaction: the map, which the encounters read through its GiST indexes. PostgreSQL 18's temporal key (`PRIMARY KEY (serials_id, during WITHOUT OVERLAPS)`) makes "one place at a time" a database rule (it needs `btree_gist`).
- **Time runs forward per unit.** An event dated before the unit's last stay began is refused (MV002). A correction (`corrects_id`) may be dated back, and the stays are rebuilt from the legs.
- **A movement's time is truncated to the second, never rounded.** A rounded stamp can fall half a second after the moment it marks, and a slice taken in between would miss the movement. The tests found this.
- **`unit_waypoints`:** the roster, read from bookings, appointments, service orders, loans and orders' holds, with the actual beside the planned where the document records it.
- **`unit_waypoint_conflicts`:** the encounters that cannot happen.
- **`cube_dots()`:** the axes, one parameter each. It draws the facts from the legs, so the second clock comes with it, and so do the instants: two events of a unit in one second leave a stay of no length, which is on the unit's line and in a period, never at a moment.
- **In PHP** (`cube.php`): `cube()`, `cubeSelect()`, `cubeDot()` with its actions, and `cubeConflicts()`. The Selects narrow, page, join and nest like the other readers. `positions.php` stays the cut at now that today's screens read.

Counted goods have no identity and so no line. They live in the same cube by quantity: `positions` is now, `stock_at(t)` is the slice, and the road of a remessa holds what is on it.
