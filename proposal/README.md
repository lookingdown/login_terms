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
| `tests/dispatch-test.sql` | 9 cases in the database | |
| `tests/core-test.php` | 11 cases through PHP | |

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

Two legacy values need Johan's word on where they go: `serials.status` `warranty` and `transferred`.

## What changed from revision 1
- functions in `core/positions.php` and `core/movements.php`, not a `Movements` namespace of classes
- `positions` kept by a trigger, instead of "never a column"
- the approved names: `road_by_transfer`, `claim_sale`, `MovementRefused`, `MV0nn`
- one call shape: lists as jsonb, answers as jsonb, a savepoint per call, refusals read from the `mv:` line
- `positionsCount()` counts over a derived table; the views are `security_invoker`; `search_path` puts `pg_temp` last
- the positions trigger updates first and inserts only a new cell, because `INSERT … ON CONFLICT` checks the CHECK on the proposed row (the leg's own qty) before it sees the existing one, so it could never take a balance down to 0. The tests found this.

## Two notes for Johan
- The application's role is `app_staff`, not `sys_owner` (`locations_fiscal_guard` checks it), so RLS and the grants do apply to the seats.
- Restoring `impublic.sql` as Navicat wrote it stores each function's `search_path` as one quoted name (`"""$user"", public"`). That breaks those functions after a restore: `relation "locations" does not exist`. A `pg_dump` keeps them right.
