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
5. **Places come twice:** as coordinates for code (`location:2`, `road:55`) and as words for people (`where`).

## The shapes

### Unit

```php
[
    'id' => 503, 'serial_number' => '9C2KC1650PR000004', 'observations' => null,
    'model' => ['variants_id' => 100, 'sku' => 'MX-VERDE', 'items_id' => 10, 'item_name' => 'Moto X', 'segment' => 'moto'],
    'position' => ['place' => 'road:55', 'owner' => 'location:1', 'state' => 'available',
                   'since' => '2026-10-31 09:12:40', 'why' => 'dispatched', 'where' => 'A caminho de Prudente · REM-0055'],
    'word' => ['key' => 'transit', 'label' => 'Em trânsito'],
    'claim' => null,     // ['kind' => 'draft' | 'order' | 'fleet', 'ref' => Ref]: what holds it
    'bench' => null,     // ['assembly_id' => 81, 'stage' => 'in_process']: its open assembly job
    'earmark' => null,   // ['location_id' => 2, 'name' => 'Prudente']: a hint, never a claim
]
```

- `position` is the unit's dot now (the cube's fact at `now`): its place, owner and state, `since` (when its stay
  began) and `why` (the movement that put it there). It is null for a unit that is nothing yet.
- A screen that needs them adds document facts beside it:
  - `purchase`: `purchases_id`, `nf`, `supplier_name`, `arrived`
  - `cost`: what the unit cost the location it stands at, from its receipt there
  - `price`
  - `customer`: `id` and `name`, when a customer is its place or its owner

### Word

One vocabulary, derived from the position. It replaces `serialState()`. The keys are stable; the labels are the install's.

| key | label | when | today |
|---|---|---|---|
| `boxed` | Recebido | validating; its job received, or no job | boxed |
| `unboxed` | Revisado | validating; its job revised | unboxed |
| `assembling` | Em montagem | validating; its job in process | assembling |
| `built` | Pronta | available; its job ready, still at the workshop | built |
| `stock` | No estoque | available where its owner stands, nothing holding it | stock |
| `assigned` | Atribuída | as `stock`, with an earmark | assigned |
| `held` | Em remessa | held by a remessa draft | held |
| `reserved` | Reservada | held by an order line not yet paid in full | new |
| `fleet` | Na frota | held by the rental fleet | new |
| `transit` | Em trânsito | on a remessa's road | transit |
| `sold` | Vendida | its customer's, still at the shop | sold, in part |
| `delivered` | Com o cliente | handed over | sold, in part |
| `rented` | Na locação | with a customer, still the location's, by a rental | rental |
| `loaned` | Emprestada | the same, by a loan | loan |
| `provider` | Devolvida ao fornecedor | at its supplier | returned, in part |
| `workshop` | Na oficina | at the workshop (step F) | warranty |
| `written_off` | Baixada | written off | written_off, scrapped |
| `unknown` | — | no position yet | unknown |

- **Precedence:** `held`, `reserved`, `fleet`, `assigned`, `built`, then `stock`, whichever applies first.
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
    'movement_id' => 6, 'at' => '2026-10-31 09:12:40', 'recorded_at' => '2026-10-31 09:12:40',
    'kind' => 'built', 'kind_label' => 'Montada',
    'model' => ['variants_id' => 100, 'sku' => 'MX-VERDE', 'item_name' => 'Moto X'],
    'unit' => ['id' => 504, 'serial_number' => '9C2KC1650PR000005'],   // null for counted goods
    'qty' => 0,          // what it changed in the location's own stock: −1 dispatched, +1 arrived, 0 built
    'from' => 'Na bancada · Matriz', 'to' => 'No estoque · Matriz',
    'ref' => ['type' => 'assembly', 'id' => 81, 'label' => 'montagem #81'],
    'note' => null, 'who' => 'Johan',
]
```

- When the list is one model at one location, each row carries `balance`: the location's own stock after it.
- A document's process lines come in the same row, with `qty` 0 and `from` and `to` as their stages: `kind`
  `assembly` for an assembly job's stage, `service` for a service order's state.
- The kinds and their labels:

| kind | label | kind | label |
|---|---|---|---|
| `opening` | Saldo inicial | `sold` | Vendida |
| `received` | Recebida | `handed_over` | Entregue |
| `receipt_corrected` | Recebimento corrigido | `sale_undone` | Venda desfeita |
| `built` | Montada | `returned` | Devolvida pelo cliente |
| `back_to_bench` | Voltou para a montagem | `traded_in` | Recebida na troca |
| `dispatched` | Saiu na remessa | `rented`, `rental_back` | Alugada, Voltou da locação |
| `arrived` | Chegou | `loaned`, `loan_back` | Emprestada, Voltou do empréstimo |
| `not_sent` | Tirada da remessa | `workshop_in`, `workshop_out` | Entrou na oficina, Saiu da oficina |
| `lost` | Perdida na estrada | `written_off` | Baixada |
| `swapped` | Troca de chassi | `to_provider` | Devolvida ao fornecedor |
| `flipped` | Transferência rápida | `adjusted`, `counted` | Ajuste, Inventário |
| `corrected` | Correção | `assembly`, `service` | Montagem, Oficina (the documents' lines) |

### Ref, page, refusal

- **Ref:** the document behind something, to link to: `['type' => 'transfers', 'id' => 55, 'label' => 'REM-0055']`.
- **Page:** `totalRows`, `totalPages`, `currentPage`, `previousPage` and `nextPage`, as today. Each list adds its own
  keys: `counts`, `scope`, `labels` or `kinds`.
- **Refusal:** the layer's `MovementRefused` reaches lib.php. The module answers in its error shape, as the NF-e
  actions already do: `['success' => false, 'error' => <the operator's Portuguese>]`. It adds `code` (`MV0nn`) and `facts`.

## The kernels

| today | becomes | answers |
|---|---|---|
| `serialState($row)` | `unitWord($position, $claim, $bench, $earmark)` | Word |
| `stockUnitsList($pdo, $in, $location, $whereLabel)` | `stockUnitsList($pdo, $in, $location)`, on the layer | Units with `purchase`, `cost` and `price`; a page with `scope`, `scopeTotal`, `counts` per word and `labels` |
| `unitTimeline($id)` | `unitTrajectory($pdo, $id)` | `unit`, `facts`, `trail`, `line` and `events` (below) |
| `movementLog` and `movementLogCsv` | `movementsList($pdo, $in, $location)` and `movementsCsv` | movement rows; a page with `kinds` |

- **`stockUnitsList`'s scope:**
  - `current`: standing at the location, or its own anywhere (on a road from it, out on a rental), or on a road to it
  - `all`: every unit whose line passed through it, sold and gone included
- **`unitTrajectory`** answers:
  - `unit`: the Unit, with `purchase`, `cost` and `price`
  - `facts`: `where`, `since`, `entered_stock` (its first stay available at a location), `cost`, `price`,
    `delivered_at` (its `handed_over` movement), `warranty_months` and `warranty_until`
  - `trail`: the five steps, Fornecedor → Estoque Central → Montagem → Loja → Cliente, read off the line
  - `line`: the cube's dots for the unit, facts then plans
  - `events`: the story. Each fact on the line is an event, titled by its kind. The documents' chapters sit beside
    them in time order: the purchase, the assembly job's stages, a rental's km, the service orders.

## The readers

| function | screen | reads through | answers | what changes |
|---|---|---|---|---|
| `getStockOverview` | Estoque, per model | the on-hand, sellable, road and owned-elsewhere readers; the open deliveries | model lines with `deliveries`; a page | `stock`, `units` and the ✗ become `here`, `sellable`, `road` and `elsewhere`. The mismatch filter goes: a bike's count is its units |
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
| `listRecentSerials` | Rastrear, the front | units by their last movement | Units with `moved_at` | `moved_at` is the last movement. Bench work is a document's (decision 2) |
| `getUnitTimeline`, `inventoryMasterPassportSerial` | Rastrear, the passport | `unitTrajectory` | see the kernels | the story is the line plus the documents |
| `getPurchaseOrder` | a delivery and its receipt | the document; each line's units | as today, `lines[].units` as Units | `serials` is `units` |
| `searchVariants`, `getItemVariants` | the pickers | the on-hand reader | as today, with `here` and `sellable` | `stock` is `here` |

## The writers

| function | takes (as today unless said) | its documents (as today) | the layer | answers | refused when |
|---|---|---|---|---|---|
| `receivePurchaseOrder` | `id`; `items: [{purchase_item_id, qty_received, serials \| units}]`: the line's new total, the numbers typed, or a remessa's arrived units; the receipt check | the received quantity, the order's status and date, the check, the landed costs | a supplier's line: `movementReceive`. A remessa's line: `movementArrive` | `getPurchaseOrder` | a correction below units that are already something (numbered, on a bench, held, sold); more numbers than units; an arrival that isn't on that road |
| `adjustStock`, `adjustStockBatch` | one line (`variants_id` with `qty_new` or `qty_delta`) or `items`; `reason`, `note` | — | `movementAdjust`: one movement, one leg pair per line | `{adjusted, ref: ADJ-YYYY-<movement>, timestamp, user_name, reason, note, items}` | a serial-tracked model (the screen points to the unit); going below zero |
| `writeOffSerial` | `serial_id`, `kind` (theft, total loss, returned to the supplier), `note`, the approval | the note on the observations; the open assembly job cancelled | `cubeDot($unit, 'written_off')`, or `'to_provider'` for a return | Unit, `approval_id` | not standing where its owner stands; held by something; no approval |
| `updateSerial` | `id`, `serial_number`, `observations`; the status goes | the number and observations (`serialChange`); the job's copy of the number | a supervisor's correction: `cubeDot($unit, 'corrected', {place, owner, state, note})` | Unit | — |
| `deleteSerial` | `id`, the password | — | `movementUnitRemove` | `{id, deleted}` | anything beyond its receipt; named by a sale, a job, a service order or an NF-e |
| `saveTransferDraft` | as today | the remessa and its lines | `claimHold` / `claimRelease` (`transfer_units`) instead of `serials.transfers_id` | `getTransfer` | a unit not free here |
| `cancelTransferDraft` | `id` | the remessa cancelled | `claimRelease` | `{id, discarded}` | — |
| `dispatchTransfer` | `id`, `expected` (the shop's order's expected date) | the shop's order and its lines; the remessa sent | `movementDispatch` | as today, with `legs` | MV010–MV017 |
| `relocateStock` | as today | the remessa from the shop; the destination's order | `movementDispatch` | as today | as dispatch |
| `takeOffTransfer` | `id`, `line_id`, `serials` or `qty`, `lost`, `bears` | the lines and the shop's order settled | `movementNotSent`, or `movementLost` (who bears it, in the note) | as today | not on that road; not the master |
| `swapTransferUnit` | `id`, `recorded`, `actual` | the correction's note on the shop's order | `movementSwap`, a correction dated at the dispatch | as today | another SKU; the real one not free at the origin |
| `resolveTransfer` | `id`, `note` | the shop's receipt check | none: it moves nothing | as today | — |
| `countActions` | as today | the count | `countOpen` reads positions; `countClose` calls `movementCountClose` | as today | — |

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

## For Johan to decide

1. **Low stock:** measured on `sellable` (what can be sold) or on `here` (what stands there)?
2. **Rastrear's "recently moved":** movements only, or the bench's work too?
3. **`built` (Pronta):** keep "ready, still at the workshop" as a word of its own?
4. **A remessa's expected arrival:** it already exists. `dispatchTransfer` writes it on the shop's order (`purchases.expected`), set to the dispatch day unless one is given. If the screen asks for it at dispatch, the cube can plan the arrival.
