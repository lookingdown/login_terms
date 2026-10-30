# The movement core — the proposal, revision 3

This supersedes `docs/movements-core.md` (revision 1). It makes `movements-code.md` concrete:
- the shape Johan approved: functions in `core/positions.php` and `core/movements.php`, built like `core/serials.php`
- the layer of code §3.1
- one event, `movement_dispatch`, written out in full as the pattern for the others

Everything here runs on imobee's own schema (`impublic.sql`, PostgreSQL 18.6). The tests are in `tests/`.

| file | what | step |
|---|---|---|
| `sql/movements-layer.sql` | the layer's tables (`transfer_units`, `movements`, `movement_legs`, `positions` kept by trigger) and the append-only guard; `mv_refuse()`, `mv_user()` and `movement_dispatch()`; the views on the layer (unit_positions, stock_on_hand, stock_sellable, owned_elsewhere, road_by_transfer, stock_total); the grants to `app_staff` | B (the views as the switch defines them) |
| `core/movements.php` | `MovementRefused`, `movementCall()` (the one door), `movementDispatch()` | C |
| `core/positions.php` | `unitPosition()`, `stockTotal()`, `transferProgress()`, the `positions*()` Selects, `positionsCount()` | A |
| `sql/diagnostics.sql` | the draft's B0 diagnostics and reconciliation checks, with the discrepancy classes of code §3.4.1, on today's tables | before the opening |
| `tests/dispatch-test.sql` | 11 cases in the database, on a copy of the pg_dump schema, with its forced RLS and guards | |
| `tests/core-test.php` | 11 cases through PHP | |

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
`movement_dispatch` keeps each of them:

1. It is SECURITY DEFINER, with `SET search_path = public, pg_temp`.
2. The user comes from the session: `mv_user()` refuses an empty `app.user`.
3. The guards come first. Each refusal goes through `mv_refuse(code, Portuguese, facts)`, which raises SQLSTATE `MV0nn` and one `mv:` line of DETAIL.
4. Locks: units FOR UPDATE in id order; counted goods take `pg_advisory_xact_lock(0, variant)`, then `(location, variant)`, as 009 does.
5. A unit leaves the cell its last +1 leg put it in.
6. Lists come in as jsonb, and the answer goes out as jsonb.
7. EXECUTE is revoked from PUBLIC and granted to `app_staff`.

## The PHP door keeps these
`movementCall()` keeps each of them:

1. **The caller's transaction.** Inside it, each call takes a savepoint, so a refusal undoes the event alone and the caller's transaction stays usable. With no transaction open, the call is its own transaction.
2. **One place.** Atlas runs the query on fetch, so the call executes, translates and decodes in one place.
3. **Refusals.** `MV0nn` becomes `MovementRefused`, with the message and the facts read from the `mv:` line. Anything else is a bug and goes on unchanged.
4. **For modules:** write the documents first, then make the one call. Never write state, legs or positions. Let a `MovementRefused` reach lib.php.

## The other events
These are the names and arguments of code §4, written on `movement_dispatch`'s pattern:

- `movementReceive($pdo, $purchaseItemId, $newReceived, $numbers)`: the line's new total, so a correction down is a lower total
- `movementArrive($pdo, $transferId, $line, $newReceived, $units)`: per line, the new total
- `movementBuilt` and `movementBackToBench($pdo, $serialId, $assemblyId)`: the unit must be the assembly job's (`assembly.serials_id`)
- `movementNotSent`, `movementLost`, `movementSwap`; `movementFlip` (step D, by the master's admin)
- `movementSell($pdo, $orderId)`, which records the cost in `sales.unit_cost`; `movementHandOver`, refused for a bike line without its unit
- `movementUnsell`, `movementReturn`; `movementRentOut` and `movementRentBack`; `movementLoanOut` and `movementLoanBack`
- `movementWriteOff`; `movementToProvider($pdo, $serialId, $supplierId, …)`; `movementAdjust`; `movementCountClose`; `movementCorrect`; `movementUnitRemove`
- `claimHold` / `claimRelease` (`transfer_units`); `claimSale` / `claimSaleRelease`, which refuses a unit still in assembly. Assembly's own job-to-unit link isn't a claim. `claimFleet` / `claimFleetRelease`.

## Step A
`core/positions.php` is step A's code. In step A the same functions read the same view names and columns, defined on today's tables. Those definitions must answer what today's readers answer (serialState.php, stockUnits.php, the stockLedger.php readers), module by module, so I write them from those files.

## What changed from revision 1
- functions in `core/positions.php` and `core/movements.php`, not a `Movements` namespace of classes
- `positions` kept by a trigger, instead of "never a column"
- the approved names: `road_by_transfer`, `claim_sale`, `MovementRefused`, `MV0nn`
- one call shape: lists as jsonb, answers as jsonb, a savepoint per call, refusals read from the `mv:` line
- `positionsCount()` counts over a derived table; the views are `security_invoker`; `search_path` puts `pg_temp` last
- the positions trigger updates first and inserts only a new cell, because `INSERT … ON CONFLICT` checks the CHECK on the proposed row (the leg's own qty) before it sees the existing one, so it could never take a balance down to 0. The tests found this.

## Notes for Johan
- The application's role is `app_staff`, not `sys_owner` (`locations_fiscal_guard` checks it), so RLS and the grants do apply to the seats.
- RLS is forced on the key tables, and its policies name only `app_staff` and `app_portal`. Every SECURITY DEFINER function is owned by `sys_owner`, so `sys_owner` must have BYPASSRLS. A `pg_dump` doesn't carry that, so a restore needs `ALTER ROLE sys_owner BYPASSRLS` first.
- Restoring `impublic.sql` as Navicat wrote it stores each function's `search_path` as one quoted name (`"""$user"", public"`). That breaks those functions after a restore: `relation "locations" does not exist`. A `pg_dump` keeps them right.
