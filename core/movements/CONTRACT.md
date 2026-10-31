# The contract: who reads, who writes, and the shapes between them

For inventory-master (`php-files/functions.php`) and the four core kernels it reads through: `serialState.php`,
`stockUnits.php`, `unitTimeline.php` and `movementLog.php`. The other modules take the same shapes (movements-code.md §5).

## The rules

1. **Shapes come from what each screen needs, not from what it answers today.** A different answer is allowed when it
   is explained (the list at the end). An unexplained difference is a bug. That is each module's proof, on a rehearsal
   with a copy of the live data, comparing facts (where each screen puts each unit, how many of each model) rather than keys.
2. **Seven shapes, reused everywhere:** a unit, its word, a model line, a movement row, a ref, a page and a refusal. A
   screen never gets a second spelling of the same fact.
3. **A writer answers the shape its screen reads,** so the screen redraws from the answer, without fetching again.
4. **A writer writes its documents, then makes one call to the layer.** It never writes a position, a state or a leg.
5. **No words leave the server.** What a person reads goes as a key and its parameters, and the module's i18n turns
   it into words, per locale. `i18n/movements.js` holds the layer's words, in en and pt. Keys are English. Names (a
   location's, a customer's) and numbers (a chassis, a remessa) travel as parameters. Places travel as coordinates
   (`location:2`, `road:55`).
6. **Values travel typed:** ids and quantities as integers, money as numbers, booleans as booleans, moments as
   `Y-m-d H:i:s`. A unit has one `cost`, chosen by the server, so a screen no longer picks between the landed and the
   invoice cost (`useCost.js`).
7. **A screen tells refusals apart by their code, never by their message.**

## The shapes

### Unit

```php
[
    'id' => 503, 'serial_number' => '9C2KC1650PR000004', 'observations' => null,
    'model' => ['variants_id' => 100, 'sku' => 'MX-VERDE', 'items_id' => 10, 'item_name' => 'Moto X', 'segment' => 'moto'],
    'position' => ['place' => 'road:55', 'owner' => 'location:1', 'state' => 'available',
                   'since' => '2026-10-31 09:12:40', 'why' => 'dispatched',
                   'where' => ['key' => 'road', 'params' => ['to' => 'Prudente', 'transfers_id' => 55]]],
    'word' => 'transit',
    'claim' => null,     // ['kind' => 'draft' | 'order' | 'fleet', 'ref' => Ref]: what holds it
    'bench' => null,     // ['assembly_id' => 81, 'stage' => 'in_process']: its open assembly job
    'service' => null,   // ['service_orders_id' => 12, 'status' => 'in_progress', 'phase' => 'in_work']: its open service order
    'earmark' => null,   // ['location_id' => 2, 'name' => 'Prudente']: a hint, never a claim
]
```

- `position` is the unit's dot now (the cube's fact at `now`): its place, owner and state, `since` (when its stay
  began) and `why` (the movement that put it there). It is null for a unit that is nothing yet.
- `where` is its place for people: a key (`master`, `location`, `road`, `customer`, `supplier`, `books`) and the
  names it needs. The screen shows `t('message.place_' + where.key, where.params)`.
- A screen that needs them adds document facts beside it:
  - `purchase`: `purchases_id`, `purchase_items_id`, `nf`, `supplier_name`, `arrived`
  - `cost`: what the unit cost the location it stands at, from its receipt there
  - `price`
  - `customer`: `id` and `name`, when a customer is its place or its owner

### Word

One vocabulary, derived from the position, replacing `serialState()`. Each key is an English word; its words for
people are `unitWord_<key>` in the i18n (Pronta, Ready, …).

| key | when | today |
|---|---|---|
| `boxed` | validating; its job received, or no job | boxed |
| `unboxed` | validating; its job revised | unboxed |
| `assembling` | validating; its job in process | assembling |
| `built` | available; its job ready, still at the workshop | built |
| `stock` | available where its owner stands, nothing holding it | stock |
| `assigned` | as `stock`, with an earmark | assigned |
| `held` | held by a remessa draft | held |
| `reserved` | held by an order line not yet paid in full | new |
| `fleet` | held by the rental fleet | new |
| `transit` | on a remessa's road | transit |
| `sold` | its customer's, still at the shop | sold, in part |
| `delivered` | handed over | sold, in part |
| `rented` | with a customer, still the location's, by a rental | rental |
| `loaned` | the same, by a loan | loan |
| `provider` | at its supplier | returned, in part |
| `workshop` | an open service order whose day has come (scheduled today or before), whatever its cell, until step F makes the workshop a place | warranty |
| `written_off` | written off | written_off, scrapped |
| `removed` | taken back from its receipt (its last movement a receipt corrected down): it never was | the row deleted |
| `unknown` | no position yet | unknown |

- **Precedence:** `workshop`, `held`, `reserved`, `fleet`, `assigned`, `built`, then `stock`, whichever applies first.
- **The workshop's phases** (`service.phase`, words `servicePhase_<phase>`), from the service order's status:
  `received` (receiving, pending); `in_work` (diagnosing, awaiting_authorization, in_progress, waiting_parts);
  `finished` (ready, delivery_scheduled). Completed and cancelled close it.
- **The bench** stays as it shows today: the assembly job's stage gives the word, and `built` and `back_to_bench`
  move the unit.
- **Keys that go:**
  - `transferred`, the master's copy of a bike: one database holds one unit
  - `returned`: a customer's return puts the bike back in stock, and its line says so
  - `scrapped`: a cancelled job's bike is written off

### Model line

One model at one location.

```php
[
    'variants_id' => 100, 'sku' => 'MX-VERDE', 'items_id' => 10, 'item_name' => 'Moto X', 'segment' => 'moto',
    'serial' => true, 'price' => 12000.0, 'low_stock' => 2,
    'here' => ['available' => 3, 'validating' => 1],   // the location's own, standing there
    'sellable' => 1,                                  // available, minus the units held, minus paid lines waiting for a unit
    'road' => ['in' => 0, 'out' => 1],                // on remessas to it, from it
    'elsewhere' => 0,                                 // its own, out on a rental or a loan
]
```

### Movement row

One movement as one location sees it. Movimentações and a model's last moves are both lists of these.

```php
[
    'movement_id' => 6, 'at' => '2026-10-31 09:12:40', 'recorded_at' => '2026-10-31 09:12:40', 'kind' => 'built',
    'model' => ['variants_id' => 100, 'sku' => 'MX-VERDE', 'item_name' => 'Moto X'],
    'unit' => ['id' => 504, 'serial_number' => '9C2KC1650PR000005'],   // null for counted goods
    'qty' => 0,          // what it changed in the location's own stock: −1 dispatched, +1 arrived, 0 built
    'from' => ['place' => 'location:1', 'state' => 'validating'],
    'to' => ['place' => 'location:1', 'state' => 'available'],
    'names' => ['location:1' => 'Matriz'],
    'ref' => ['type' => 'assembly', 'id' => 81],
    'note' => null, 'reason' => null, 'who' => 'Johan',
]
```

- `reason` is the movement's key, its words `reason_<key>`: an adjustment's `found`, `damaged`, `loss`, `expired`,
  `count` or `other` (the house's words, messages.js), or who bears a loss on the road, `origin` or `carrier`.
- When the list is one model at one location, each row carries `balance`: the location's own stock after it.
- A document's process lines come in the same row, with `qty` 0 and `from` and `to` as their stages: `kind`
  `assembly` for an assembly job's stage, `service` for a service order's state.
- The kinds, their words `mvKind_<kind>`: `opening`, `received`, `receipt_corrected`, `built`, `back_to_bench`,
  `dispatched`, `arrived`, `not_sent`, `lost`, `swapped`, `flipped`, `sold`, `handed_over`, `sale_undone`,
  `returned`, `traded_in`, `rented`, `rental_back`, `loaned`, `loan_back`, `workshop_in`, `workshop_out`,
  `written_off`, `to_provider`, `adjusted`, `counted`, `corrected`; and the documents' lines, `assembly` and `service`.

### Ref, page, refusal

- **Ref:** the document behind something, to link to: `['type' => 'transfers', 'id' => 55]`. Its words are `refType_<type>`.
- **Page:** `totalRows`, `totalPages`, `currentPage`, `previousPage` and `nextPage`, as today. Each list adds its own
  keys: `counts`, `scope` or `kinds`.
- **Refusal:** the layer's `MovementRefused` reaches lib.php. The module answers in its error shape, as the NF-e
  actions already do: `['success' => false, 'error' => <an English message, for the log>]`, with `code` (`MV0nn`) and
  `facts`. The screen shows `t('message.mvRefused_' + code, refusalParams(t, facts))`.

## The kernels

| today | becomes | answers |
|---|---|---|
| `serialState($row)` | `unitWord($position, $claim, $bench, $service, $earmark)` | the Word's key |
| `stockUnitsList($pdo, $in, $location, $whereLabel)` | `stockUnitsList($pdo, $in, $location)`, on the layer | Units with `purchase`, `cost` and `price`; a page with `scope`, `scopeTotal` and `counts` per word |
| `unitTimeline($id)` | `unitTrajectory($pdo, $id)` | `unit`, `facts`, `trail`, `line` and `events` (below) |
| `movementLog` and `movementLogCsv` | `movementsList($pdo, $in, $location)`. The spreadsheet is the screen's, built from these rows in its own words | movement rows; a page with `kinds`, the keys |

- **`stockUnitsList`'s scope:**
  - `current`: standing at the location, or its own anywhere (on a road from it, out on a rental), or on a road to it
  - `all`: every unit whose line passed through it, sold and gone included
- **`unitTrajectory`** answers:
  - `unit`: the Unit, with `purchase`, `cost` and `price`
  - `facts`: `where`, `since`, `entered_stock` (its first stay available at a location), `cost`, `price`,
    `delivered_at` (its `handed_over` movement), `warranty_months` and `warranty_until`
  - `trail`: the five steps, read off the line and drawn as a purchase order's road is (`poRoad.js`):
    `[{key, state, sub}]`.
    - `key`: `supplier`, `central`, `assembly`, `shop` or `customer`; its words are `trail_<key>`
    - `state`: `done`, `current` or `todo`
    - `sub`: what the current step waits for, as a key and its parameters: `on_bench`, `waiting_assembly`,
      `earmarked` (with the shop's name), `waiting_shop` or `for_sale`; its words are `trailSub_<key>`
  - `line`: the cube's dots for the unit, facts then plans
  - `events`: the story, `[{at, source, kind, ref, params}]`, in time order. A fact on the line has `source`
    `movement`, its `kind` titled `mvKind_<kind>` and its `ref` the movement's document. A document's chapter has
    `source` `document`, titled `story_<kind>`: the purchase, the assembly job started, an issue on receipt (its
    `condition` a key, `condition_<state>`), the job checked, a service order opened and done. A rental is told by
    its movements.

## The readers

| function | screen | reads through | answers | what changes |
|---|---|---|---|---|
| `getStockOverview` | Estoque, per model | the on-hand, sellable, road and owned-elsewhere readers; the open deliveries | model lines with `deliveries`; a page | `stock`, `units` and the ✗ become `here`, `sellable`, `road` and `elsewhere`. The mismatch filter goes: a bike's count is its units. Low stock is `sellable` at or below `low_stock` |
| `getStockMovements($variant)` | a model's last moves | `movementsList`, one model | movement rows with `balance` | `stock_after` is `balance` |
| `getMovementLog`, `streamMovementLogCsv` | Movimentações | `movementsList`, `movementsCsv` | movement rows; a page with `kinds` | one row per event: a sale once, a remessa as `dispatched` and `arrived` |
| `getSerial($id)` | the unit's page | the Unit; its sales, as today | Unit, `sales`, `actions` | the status you could edit becomes `word`, which is read-only. `actions` lists what can be done to it now: the `cubeActions()` that fit its position. The database still has the last word |
| `listSerials` | Unidades | `stockUnitsList`, across the organisation | Units; a page | filtered by word, not by four statuses |
| `getStockUnits` | Estoque atual · Pelo chassi | `stockUnitsList` | Units with `purchase`, `cost` and `price`; a page | `where` comes from the position; `cost` is what the unit cost this location |
| `getSerialsOverview` | Unidades por modelo | the units standing here, per model | `[model, units: Unit[]]` | the "serial needed" rows go: a bike's count is its units |
| `listTransfers` | Remessas | the remessa (a document); its road; its arrivals | as today, with `road: {on_road, arrived}` | received is read from the arrivals, not from the receiving location's ledger rows |
| `getTransfer($id)` | a remessa | the document; `transferProgress`; its units | as today. Lines with `on_road`; `units`, the Units it carried; `held`, the Units a draft holds | a unit that arrived stays listed. Today it leaves the list when it arrives |
| `listAssignedGroups` | A enviar | earmarked units here, available, nothing holding them | as today | — |
| `assignSuggest` | Montar a remessa, the shortages | the destination's on-hand; the road to it; earmarked units here | as today | `transit` counts counted goods too |
| `listLocationStock` | De uma loja | the units and model lines at the shop, available, nothing holding them | as today | `units[].since` is the stay's start, not rebuilt from the history |
| `listOpenDeliveries`, `listDeliverySerials` | Distribuir | the delivery line's units here, available, nothing holding them (or held by this draft) | as today, the units as Units | — |
| `listRecentSerials` | Rastrear, the front | units by their last movement or service order step | Units with `moved_at` | `moved_at` is its last movement or its service order's last step. The bench counts through `built` and `back_to_bench` |
| `getUnitTimeline`, `inventoryMasterPassportSerial` | Rastrear, the passport | `unitTrajectory` | see the kernels | the story is the line plus the documents |
| `getPurchaseOrder` | a delivery and its receipt | the document; each line's units | as today, `lines[].units` as Units | `serials` is `units` |
| `searchVariants`, `getItemVariants` | the pickers | the on-hand reader | as today, with `here` and `sellable` | `stock` is `here` |

## The writers

| function | takes (as today unless said) | its documents (as today) | the layer | answers | refused when |
|---|---|---|---|---|---|
| `receivePurchaseOrder` | `id`; `items: [{purchase_item_id, qty_received, serials \| units}]`: the line's new total, the numbers typed, or a remessa's arrived units; the receipt check | the order's status and date, the check, the landed costs; the remessa `received` once its arrival answers `on_road` 0. A line's `qty_received` is the layer's: it follows the total under the line's lock | a supplier's line: `movementReceive`, which mints each new unit on the bench. A remessa's line: `movementArrive` | `getPurchaseOrder` | MV030–MV037: another location's order, a remessa's line, a cancelled order, a number already a unit's, more numbers than units, a correction below units that are something already (numbered, on a job, held, sold). MV040–MV043: another location's remessa, a line not its own, more than is on the road, a lower total |
| `adjustStock`, `adjustStockBatch` | one line (`variants_id` with `qty_new` or `qty_delta`) or `items`; `reason`, `note` | — | `movementAdjust($pdo, $lines, $reason, $note)`: one movement, one leg pair per model. A line is `['variants_id', 'qty']` for `qty_delta`, or `['variants_id', 'balance']` for `qty_new`, the difference worked out under the model's lock. A gain comes from the books; a loss is written off where it stands | `{adjusted, ref: ADJ-YYYY-<movement>, timestamp, user_name, reason, note, items}`, the layer answering `movement_id` and each line's `before`, `after`, `delta` | MV110 a serial-tracked model (the screen points to the unit); MV114 going below zero; MV111 no reason; MV112 no note; MV115 found as a loss, or damaged, loss or expired as a gain; MV113 an unknown model; MV015 a material; MV116 a balance given twice |
| `writeOffSerial` | `serial_id`, `kind` (theft, total loss, returned to the supplier), `note`, the approval | the note on the observations; the open assembly job cancelled | `cubeDot($unit, 'written_off')`, or `'to_provider'` for a return | Unit, `approval_id` | not standing where its owner stands; held by something; no approval |
| `updateSerial` | `id`, `serial_number`, `observations`; the status goes; a correction is `place` (with `owner` and `state` if they differ) and `note`, with the supervisor's password | the number and observations (`serialChange`); the job's copy of the number; for a correction, the approval `unit_correction` for the unit, through `approvalRequire` (the serials supervisor's password, as the write-off's approval) | the supervisor's correction, event 24: `cubeDot($pdo, ['unit' => $id], 'corrected', ['approval' => …, 'place' => 'location:2', 'note' => …])`, the owner the place's and the state the unit's own unless given | Unit | MV156 no note; MV150 no approval for this unit; MV151 the approval used already; MV152 a customer's unit (a sale is its order's); MV153 not an active location; MV154 a write-off asked for; MV155 there already; MV093 another seat's unit; MV055 a claimed unit away from its holder; MV157 a unit with no line |
| `deleteSerial` | `id`, the password | the approval `unit_removal` for the unit, through `approvalRequire`, its `detail` keeping the number | `movementUnitRemove($pdo, $id, $approvalId, $note)`: the receipt corrected down by this unit, back to its supplier, the line's received total down by one. The identity row stays (the journal names it) and its number is freed | `{id, deleted}`; the layer answers the number it had | MV161 anything beyond its receipt; MV162 named by an order line, an assembly job, a service order, an appointment, a loan, a draft, the fleet, a count or an issued NF-e; MV160 no approval; MV093 another location's receipt |
| `saveTransferDraft` | as today | the remessa and its lines | `claimHold` / `claimRelease` (`transfer_units`) instead of `serials.transfers_id`, from the draft's own seat or the master's | `getTransfer` | a unit not free here |
| `cancelTransferDraft` | `id` | the remessa cancelled | `claimRelease` | `{id, discarded}` | — |
| `dispatchTransfer` | `id`, `expected_at` (the expected arrival, a date and a time: a same-day delivery has its hour) | `transfers.expected_at`; the shop's order (its `expected`, the date) and its lines; the remessa sent | `movementDispatch` | as today, with `legs` | MV010–MV018: MV018 without an expected arrival |
| `relocateStock` | as today, with `expected_at` | the remessa from the shop; the destination's order | the remessa holds the shop's units (`claimHold`, the master's seat), then `movementDispatch` | as today | as dispatch |
| `takeOffTransfer` | `id`, `line_id`, `serials` or `qty`, `lost`, `bears` | the lines and the shop's order settled | `movementNotSent`, or `movementLost` (who bears it, as the movement's reason) | as today | not on that road; not the master |
| `swapTransferUnit` | `id`, `recorded`, `actual` | the correction's note on the shop's order | `movementSwap`: on the road, a correction dated at the dispatch; arrived (the named unit received at the destination, the real one on its floor), a correction dated at the arrival that puts each where it really stands | as today | another SKU; the real one not free at the origin |
| `resolveTransfer` | `id`, `note` | the shop's receipt check | none: it moves nothing | as today | — |
| `countActions` | as today | the count; at close, `fechado` and `parts_adjusted` from the answer's `adjusted` | `countOpen` reads positions; `countClose` calls `movementCountClose`: each counted part set to what was counted (several lines of a model add up), one movement, reason `count`. Materials, units and lines not counted are left alone | as today | MV120 an unknown count; MV121 not open; MV093 another location's |
| **new:** Transferência rápida | `from`, `to`, `serials`, `counted` (`[{variants_id, qty}]`), `note` | — | `movementFlip`: (A·A·available) → (B·B·available) at once, no road; a unit by `cubeDot($unit, 'flipped', ['to' => B])` | `{movement_id, units, lines}` | MV130 not the master's admin or superadmin (`app_user_admin()` tells the screen whether to show itself); MV131 not from one active location to another; MV091, MV055 a unit not available at A or held; MV132 fewer counted goods at A; MV073 a bike model by quantity; MV133 nothing |

### Outside inventory-master

- **The rentals** (`desk.php`'s `rentalPickup` and `rentalReturn`): the pickup calls `movementRentOut($pdo, $bookingId)`
  after it marks the booking `in_use`, the return `movementRentBack` after `completed`. The booking names the bike
  (its fleet resource's) and the customer; the bike stays its location's, at `customer:<id>`, and the fleet keeps
  holding it. Out is refused for a booking not to come or under way (MV141), a booking without a bike (MV142), a bike
  not available where it is kept (MV143) or held by something but its own resource (MV055), another location's
  booking (MV093). Back is refused only when the bike did not go out on it (MV144), whatever the booking's status.
  Each is once: again answers `{done: false}`.
- **The loans** (`loans.php`, the loan form): a loan names a customer (`loans.customers_id`, migration 026), picked or
  created through `core/customerRecord.php`; a loan without one is refused (MV146). `loanOut` and `loanReturn` call
  `movementLoanOut` and `movementLoanBack`, with the rentals' rules (MV141 for a loan not `preparando` or
  `com_a_pessoa`). The loans written before the column have none: each needs its customer before it goes out.

- **The workshop's monthly close** (`BillingClose.vue`, `core/workshopClose.php`) bills each service order to the
  bike's store of origin, which it reads from `serials.location_id`. That column goes at step C. On the layer, the
  store of origin is the location that sold the bike, from its live sale line. For a bike never sold, it is the
  location that owns it.

## The Vue side

What the screens and composables read today, and where it is in the new shapes. Read from `DistributeStock.vue`,
`useDistribute.js`, `useCost.js`, `poRoad.js`, `usePasswordPrompt.js`, `CountsView.vue` and `BillingClose.vue`.

| today | becomes | where |
|---|---|---|
| a unit's `earmark_location_id` and `earmark` (its name) | `earmark.location_id` and `earmark.name` | the delivery's unit picker |
| `held[].purchase_items_id`, a draft's units grouped by line | `held[].purchase.purchase_items_id` | `openDraft` |
| `dispatchTransfer({id, expected})`, a date | `{id, expected_at}`, a date and a time, required: a `datetime-local` field, the expected arrival | `dispatch`, DistributeStock's "Ship date" |
| `parseInt(remaining)`, `!!parseInt(serial_required)`, `unitCost(row)` | typed values and one `cost`. The conversions stay harmless; new screens need none | useDistribute, useCost |
| `toast.showError(e.message)` | with a `code`: `t('message.mvRefused_' + e.code, refusalParams(t, e.facts))`. The shared API client keeps `code` and `facts` on the error it throws | every screen |
| `isPasswordError(e)` compares the messages 'Invalid password' and 'Invalid supervisor password' | a code for each, from the server, compared instead | usePasswordPrompt |
| a unit's state, `serialState()`'s key and label | `word`, shown as `t('message.unitWord_' + word)` | every unit list |
| the remessa's carrier, stored as words ('Equipe da rede', 'Transportadora · …') and parsed back by its first word | `carrier: {kind: 'team' \| 'company', name}`, when dispatch is rewritten | useDistribute |

The steps strips (StepsStrip with `poRoad.js`) are the pattern for a unit's trail and a remessa's road: keys, each
step `done`, `current` or `todo`.

## The explained differences

| what changes on a screen | why |
|---|---|
| A bike's count and its units no longer disagree. The ✗, the mismatch filter and the "serial needed" rows go | the count is its units. Today 19 models disagree (D4) |
| A bike has one row: no master copy (`transferred`) | one database, one unit. Today 5 chassis exist twice (D6) |
| New words: `reserved`, `fleet`, `delivered`, `rented`, `loaned`, `provider`. Words that go: `transferred`, `returned`, `warranty`, `scrapped` | the layer knows what holds a unit, who has it, and the handover |
| A sale appears once in Movimentações | today both the ledger's row and the order's row list it |
| `since` is the stay's start | today it is rebuilt from `serial_events` |
| A remessa's received quantity comes from its arrivals; its units stay on its page after arriving | today it is the receiving location's ledger rows, and units leave the page when they arrive |
| The numbers the client settles before the opening: D1 (CDV, −4), D2 (remessa 23), D5 (unit 61), D7 (28 lines), D8 (29 lines), D9 (unit 110) | their corrections, before the opening (rule §0.2) |

## Decided (Johan, 2026-10-31)

1. **Low stock** is measured on `sellable`.
2. **Rastrear's "recently moved"** counts the movements and a service order's steps (received, being worked on,
   finished). The bench keeps its stage words, moved by `built` and `back_to_bench`.
3. **`built`** stays: ready, still at the workshop.
4. **A remessa's expected arrival** is asked at dispatch, a date and a time (`transfers.expected_at`), so a same-day
   delivery has its hour. Dispatch refuses a remessa without one (MV018). The cube plans each unit's arrival at the
   destination, and an appointment there after the expected arrival is no conflict.
5. **Words:** keys and interfaces are English, and every word for people comes from i18n. New code keeps to it; old
   code changes when it is rewritten.
