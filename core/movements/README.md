# The movement core — the proposal, revision 3

This supersedes `docs/movements-core.md` (revision 1). It makes `movements-code.md` concrete, all of it
in one place, `core/movements/`, as on the server (`/var/sys/core/movements/`):
- functions built like `core/serials.php`, loaded by one require
- the layer of code §3.1
- three events written out in full as the pattern for the others: `movement_dispatch`, a document's
  (many units and counted goods), and `movement_built` and `movement_back_to_bench`, a unit's
- the cube: every unit's place at any moment, its line, and the roster ahead (`CUBE.md`), with one door for
  its consumers, axes in and dots out (`CONSUMERS.md`)

Everything here runs on imobee's own schema (the pg_dump of 30 October, PostgreSQL 18.6).

| file | what | step |
|---|---|---|
| `movements.php` | the one require: `require_once '/var/sys/core/movements/movements.php';` | |
| `ledger.php` | the writing side: `MovementRefused`, `movementCall()` (the one door), `movementDispatch()`, `movementBuilt()`, `movementBackToBench()`, `movementReceive()`, `movementArrive()`, `movementSell()`, `movementHandOver()`, `movementUnsell()`, `movementReturn()`, `movementNotSent()`, `movementLost()`, `movementSwap()`, `movementWriteOff()`, `movementToProvider()`, `movementFlip()`, `movementRentOut()`, `movementRentBack()`, `movementLoanOut()`, `movementLoanBack()`, `movementAdjust()`, `movementCountClose()` (with `movementLines()`, counted goods' lines); the claims, `claimHold()`, `claimRelease()`, `claimSale()` (the attach), `claimSaleRelease()`, `claimFleet()`, `claimFleetRelease()` | C |
| `positions.php` | the reading side at now: `unitPosition()`, `stockTotal()`, `transferProgress()`, the `positions*()` Selects, `positionsCount()` | C |
| `cube.php` | the cube's door (`CONSUMERS.md`): `cube()`, `cubeSelect()`, `cubeDot()` with its actions, `cubeConflicts()` | B |
| `units.php` | the kernel of a unit (`CONTRACT.md`): `unitWord()`, `servicePhase()`, `unitRows()` (the Unit), `stockUnitsList()` (a location's units), `placeWhere()` | C |
| `journal.php` | `movementsList()`: the movements as one location sees them, with the documents' process lines, and one model's running balance | C |
| `trajectory.php` | `unitTrajectory()`: a unit's whole life, the line, its facts, the trail and the story | C |
| `i18n/movements.js` | the layer's words, en and pt, for every module's i18n: the units' words, the movement kinds, the places, the refusals | C |
| `CONTRACT.md` | who reads and who writes: inventory-master's functions and the four core kernels, mapped to the layer, with the shapes in and out and the differences from today, explained | C |
| `sql/layer.sql` | the layer: `transfer_units`, `movements`, `movement_legs`, `positions` (kept by trigger), the append-only guard, `mv_refuse()`, `mv_user()`, the posting primitive `mv_post()` with `mv_cell()`, `mv_pair()` and `mv_unit_leg()`, `unit_claims` and `mv_unit_claim()`, `movement_dispatch()`, `movement_built()`, `movement_back_to_bench()`, `movement_receive()`, `movement_arrive()`, the sale path (`movement_sell()`, `movement_hand_over()`, `movement_unsell()`, `movement_return()`, with `mv_order()`, `mv_order_line()`, `mv_line_sold()`, `mv_line_out()` and the cost, `mv_cost()`), the remessa's corrections (`movement_not_sent()`, `movement_lost()` through `mv_take_off()`, `movement_swap()`, and `mv_on_road()`), the claims (`claim_hold()`, `claim_release()`, `claim_sale()`, `claim_sale_release()`, `claim_fleet()`, `claim_fleet_release()` over `mv_claimable()`), the baixa (`movement_write_off()`, `movement_to_provider()` through `mv_baixa()`), the quick transfer (`movement_flip()`, with `app_user_admin()`), the rentals and the loans (`movement_rent_out()`, `movement_rent_back()`, `movement_loan_out()`, `movement_loan_back()` through `mv_rental()`, `mv_loan()` and `mv_lend()`; `loans.customers_id`), the adjustments and the count (`movement_adjust()`, `movement_count_close()` through `mv_adjust()`; a movement's `reason`), the views on the layer, the health checks, `stock_at()`, `unit_at()`, RLS and grants | B (the views as the switch defines them) |
| `sql/cube.sql` | the time axis: `unit_residence` (stays, one place at a time by PostgreSQL 18's temporal key), `unit_waypoints`, `unit_waypoint_conflicts`, `cube_dots()` (one parameter per axis) | B |
| `sql/readers.sql` | what the kernels read in one statement: `movement_rows(location)`, the journal as one location sees it | C |
| `sql/diagnostics.sql` | the draft's B0 diagnostics and reconciliation checks, with the discrepancy classes of code §3.4.1, on today's tables | before the opening |
| `sql/cube-legacy.sql` | the cube read from today's history, as the opening will port it | before the opening |
| `tests/dispatch-test.sql` | 18 cases in the database, on a copy of the pg_dump schema, with its forced RLS and guards: the dispatch, the reads, the health checks, each refusal of built and back to the bench, and a movement that does not balance | |
| `tests/cube-test.sql` | 14 cases on the time axis: the stays, a cut along each axis in both clocks, an instant, the encounters, the road's forward end, and the rules that keep one place at a time | |
| `tests/core-test.php` | 61 cases through PHP: the door, the readers, the cube's every angle, its dots and its actions, the kernels, and a receipt, an arrival, a sale, a write-off, an adjustment, a rental, a loan, a quick transfer and a count undone after | |
| `tests/receive-test.sql` | 15 cases: a supplier's delivery received, its numbers checked, corrected down; a remessa arriving at its shop; the health checks. Run after the PHP: it changes what the others read | |
| `tests/sale-test.sql` | 18 cases: an order paid and sold, handed over, returned; counted goods sold, returned, undone; each refusal; the health checks. Run after receive-test.sql | |
| `tests/road-test.sql` | 14 cases: a remessa dispatched, its chassis swapped, a helmet not sent, one lost on the way, the rest arriving; each refusal; the health checks. Run after sale-test.sql | |
| `tests/claims-test.sql` | 18 cases: a draft's hold and release, the attach on an unpaid and on a paid order, the fleet's claim, a write-off and a return to the provider; each refusal; the health checks. Run after road-test.sql | |
| `tests/stock-test.sql` | 39 cases: a quick transfer there and onward; a rental and a loan out and back, each once; adjustments by difference and by balance, one model and two; a count closed, then again; a seat that writes only through the functions; each refusal; the health checks. Run after claims-test.sql | |

Run the tests in that order, on a scratch copy: `sql/layer.sql`, `sql/cube.sql`, `sql/readers.sql`, `tests/dispatch-test.sql`, `tests/cube-test.sql`, `php tests/core-test.php path/to/vendor/autoload.php`, `tests/receive-test.sql`, `tests/sale-test.sql`, `tests/road-test.sql`, `tests/claims-test.sql`, then `tests/stock-test.sql`.

## The draft's ERP controls, in the layer
- **Health checks**, the draft's `v_recon_*`: `movement_check_balance`, `_chain`, `_positions`, `_serial_mix` and `_roads`. Each must answer nothing, and anything found is fixed by posting a movement.
- **The time axis**, the draft's `f_stock_at` and `f_serial_at`: `stock_at(t)` has stock_on_hand's columns, and `unit_at(id, t)` gives a unit's position at that moment.
- **RLS in the house's way:** forced, with policies for `app_staff` and `app_portal`. Tested as an `app_staff` seat:
  - at the master, it sees everything
  - at a shop, it sees its own floor and the roads from or to it, and nothing else

## Before the opening: the draft's diagnostics on the live data
`sql/diagnostics.sql` adapts the draft's checks to how today's tables record a remessa: the departure is booked on the transfer, the arrival on the shop's purchase line. On the dump of 30 October (98 units, 402 stock rows):

| check | rows | |
|---|---|---|
| D1 a negative balance | 1 | CDV, MINI DRIFT: −4 |
| D2 a remessa line whose two sides don't balance | 1 | transfer 23: one bike left the master and never arrived, yet the remessa is "received" |
| D3 ghost road rows | 0 | |
| D4 a bike balance that is not its units | 19 | |
| D5 a unit sold on no live line | 1 | unit 61 |
| D6 a chassis twice | 5 pairs | each is a clean chassis and a copy ending in ".": a returned bike sold again under a second identity, which breaks the draft's "one serial, one trajectory" |
| D7 a bike sold on a line with no unit | 28 | |
| D8 a remessa bike line that carried no unit | 29 | every bike line of remessas 1–28 |
| D9 a unit whose story does not end where it stands | 1 | unit 110: its row says CDV, its last event the master |
| D10 a unit in transit on a remessa that is not on the road | 0 | |

The legacy statuses in use are sold 78, stock 12, assembly 4 and returned 4. No unit is in `warranty` or `transferred`, so the opening needs no rule for them.

As the data stands, the opening's guard (code §3.4.1) would refuse: each of its five classes has rows. They are the client's to settle (rule §0.2).

## Every event function keeps these rules
`movement_dispatch`, `movement_built`, `movement_back_to_bench`, `movement_receive`, `movement_arrive`, the sale path's four, the remessa's three corrections, the claims, the baixa, the quick transfer, the rentals and the loans, the adjustment and the count keep each of them:

1. It is SECURITY DEFINER, with `SET search_path = public, pg_temp`.
2. The user comes from the session: `mv_user()` refuses an empty `app.user`.
3. The guards come first. Each refusal goes through `mv_refuse(code, message, facts)`, which raises SQLSTATE `MV0nn` and one `mv:` line of DETAIL. The message is English, for the log. The code is the i18n key (`mvRefused_<code>`, `i18n/movements.js`) and the facts are its parameters: no words for people leave the database.
4. Locks: units FOR UPDATE in id order; counted goods take `pg_advisory_xact_lock(0, variant)`, then `(location, variant)`, as 009 does. Two locations (a flip) take the lower first.
5. A unit leaves the cell its last +1 leg put it in (`mv_unit_leg()`).
6. **One door into the journal:** the guards build the legs (`mv_pair()` over `mv_cell()`), then one call to `mv_post(kind, ref, legs)` writes the movement and its legs together. `mv_post` refuses legs that do not balance per model (MV003). Nothing else writes the journal.
7. Lists come in as jsonb, and the answer goes out as jsonb.
8. EXECUTE is revoked from PUBLIC and granted to `app_staff`; `mv_post` is granted to no one.

## The PHP door keeps these
`movementCall()` keeps each of them:

1. **The caller's transaction.** Inside it, each call takes a savepoint, so a refusal undoes the event alone and the caller's transaction stays usable. With no transaction open, the call is its own transaction.
2. **One place.** Atlas runs the query on fetch, so the call executes, translates and decodes in one place.
3. **Refusals.** `MV0nn` becomes `MovementRefused`, with the message and the facts read from the `mv:` line. Anything else is a bug and goes on unchanged.
4. **For modules:** write the documents first, then make the one call. Never write state, legs or positions. Let a `MovementRefused` reach lib.php.

## The other events
These are the names and arguments of code §4, written on `movement_dispatch`'s pattern:

- `movementCorrect` (event 24, the supervisor's correction); `movementUnitRemove`
- `movementWorkshopIn` and `movementWorkshopOut` (step F)

## No step A (Johan, 2026-10-31)
Step A defined the read interface on today's tables first, with the rule that every read answers the same before and after. That rule would have rebuilt what is being replaced, so step A goes:
- The interface is defined once, on the layer, in the shapes of `CONTRACT.md`: each designed from what its screen needs.
- The readers move in step C together with the writers.
- The proof is a rehearsal on a copy of the live data. Every difference between today's answer and the new one is explained (CONTRACT.md lists them), and an unexplained one is a bug.

## What changed from revision 1
- functions in one place, `core/movements/` (`ledger.php`, `positions.php`, one loader), not a `Movements` namespace of classes
- `positions` kept by a trigger, instead of "never a column"
- the approved names: `road_by_transfer`, `claim_sale`, `MovementRefused`, `MV0nn`
- one call shape: lists as jsonb, answers as jsonb, a savepoint per call, refusals read from the `mv:` line
- `positionsCount()` counts over a derived table; the views are `security_invoker`; `search_path` puts `pg_temp` last
- the positions trigger updates first and inserts only a new cell, because `INSERT … ON CONFLICT` checks the CHECK on the proposed row (the leg's own qty) before it sees the existing one, so it could never take a balance down to 0. The tests found this.

## Notes for Johan
- The application's role is `app_staff`, not `sys_owner` (`locations_fiscal_guard` checks it), so RLS and the grants do apply to the seats.
- RLS is forced on the key tables, and its policies name only `app_staff` and `app_portal`. Every SECURITY DEFINER function is owned by `sys_owner`, so `sys_owner` must have BYPASSRLS. A `pg_dump` doesn't carry that, so a restore needs `ALTER ROLE sys_owner BYPASSRLS` first.
- Restoring `impublic.sql` as Navicat wrote it stores each function's `search_path` as one quoted name (`"""$user"", public"`). That breaks those functions after a restore: `relation "locations" does not exist`. A `pg_dump` keeps them right.
