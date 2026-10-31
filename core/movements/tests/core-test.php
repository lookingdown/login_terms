<?php
/**
 * core/movements against imobee (PostgreSQL 18), after sql/layer.sql and tests/dispatch-test.sql
 * on a scratch copy.
 *
 *   PGHOST=… PGPORT=… PGDATABASE=imobee PGUSER=… php core-test.php path/to/vendor/autoload.php
 */
declare(strict_types=1);

require $argv[1] ?? 'vendor/autoload.php';
require __DIR__ . '/../movements.php';

use Atlas\Query\Select;

$dsn = sprintf('pgsql:host=%s;port=%s;dbname=%s', getenv('PGHOST') ?: 'localhost', getenv('PGPORT') ?: '5432', getenv('PGDATABASE') ?: 'imobee');
$pdo = new PDO($dsn, getenv('PGUSER') ?: 'postgres', getenv('PGPASSWORD') ?: '', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$pdo->query('SELECT * FROM app_enter(1, 1)');                  // the connect step: the master, user 1

function check(string $what, bool $ok, mixed $seen = null): void
{
    echo ($ok ? 'ok   ' : 'FAIL ') . $what . ($seen === null ? '' : ' — ' . json_encode($seen, JSON_UNESCAPED_UNICODE)) . "\n";
}

// a remessa from the master to Prudente: bike 503 and one helmet
$transferId = (int) $pdo->query("INSERT INTO transfers (shop_purchases_id, status, location_id, to_location_id, expected_at)
    VALUES (3, 'draft', 1, 2, date_trunc('day', LOCALTIMESTAMP) + interval '1 day 16 hours') RETURNING id")->fetchColumn();
$pdo->exec("INSERT INTO transfer_items (transfers_id, variants_id, items_id, sku, qty) VALUES ({$transferId}, 100, 10, 'MX-VERDE', 1), ({$transferId}, 200, 20, 'CAP-M', 1)");
$pdo->exec("INSERT INTO transfer_units VALUES ({$transferId}, 503)");

// the module: its documents, then the fact, in one transaction
$pdo->beginTransaction();
$pdo->exec("UPDATE transfers SET status = 'sent' WHERE id = {$transferId}");
$answer = movementDispatch($pdo, $transferId);
$pdo->commit();
check('dispatch inside the module\'s transaction', $answer === ['legs' => 4], $answer);

// a refusal inside the caller's transaction undoes the event alone
$pdo->beginTransaction();
try {
    movementDispatch($pdo, $transferId);
    check('a second dispatch is refused', false);
} catch (MovementRefused $e) {
    check('a second dispatch is refused, coded, with its facts', $e->sqlState === 'MV013' && $e->facts === ['transfers_id' => $transferId], [$e->sqlState, $e->getMessage(), $e->facts]);
}
check('the caller\'s transaction is still usable', (int) $pdo->query('SELECT 1')->fetchColumn() === 1);
$pdo->rollBack();

// without a transaction, the call is its own
try {
    movementDispatch($pdo, 999999);
} catch (MovementRefused $e) {
    check('an unknown remessa is refused on its own transaction', $e->sqlState === 'MV011' && !$pdo->inTransaction(), [$e->sqlState, $e->getMessage()]);
}

// the reads
$unit = unitPosition($pdo, 503);
check('the unit is on the remessa\'s road, still the sender\'s', $unit['place_kind'] === 'road' && (int) $unit['transfers_id'] === $transferId && (int) $unit['owner_location_id'] === 1, $unit);
check('an unknown unit has no position', unitPosition($pdo, 999999) === null);
$progress = transferProgress($pdo, $transferId);
check('the road carries one bike and one helmet', array_map(fn ($r) => [(int) $r['variants_id'], (int) $r['qty']], $progress) === [[100, 1], [200, 1]], $progress);
check('the organisation still owns every bike and helmet', stockTotal($pdo) == [100 => 5, 200 => 5], stockTotal($pdo));

// a list screen: narrowed, paged, counted
$onRoad = positionsUnits($pdo)->where('up.place_kind = ', 'road');
check('units on a road, counted', positionsCount($pdo, $onRoad) === 2, positionsCount($pdo, $onRoad));
$byPlace = positionsUnits($pdo)->resetColumns()->columns('up.place_kind', 'COUNT(*)')->groupBy('up.place_kind');
check('a grouped select counts its groups, not a group', positionsCount($pdo, $byPlace) === 2, $byPlace->fetchAll());

// nesting: the models this till can sell, inside the module's own catalogue query
$select = Select::new($pdo)->columns('v.id', 'v.sku')->from('variants AS v');
$select->where('v.id IN ', positionsSellable($pdo, $select)
    ->resetColumns()->columns('ss.variants_id')
    ->where('ss.location_id = ', 1)->where('ss.qty > 0'));
$sellable = $select->orderBy('v.id')->fetchAll();
check('the catalogue nests the sellable models', array_column($sellable, 'sku') === ['CAP-M'], $sellable);

// the cube (cube.php, after tests/cube-test.sql): any angle in, dots out
$moment = cubeSelect($pdo, ['at' => 'now', 'layer' => 'fact']);
check('a moment: every unit somewhere', positionsCount($pdo, $moment) === 5, $moment->fetchAll());
$then = cubeDot($pdo, ['unit' => 503, 'at' => '2026-10-15']);
$now = cubeDot($pdo, ['unit' => 503]);
check('bike 503 stood at the master on 15 Oct, and is on its road now', $then['place'] === 'location:1' && $now['place'] === "road:{$transferId}", [$then['place'], $now['place']]);
check('as the books stood on 15 Oct, they knew no unit yet', cube($pdo, ['at' => '2026-10-15', 'known' => '2026-10-15']) === []);
$life = cube($pdo, ['unit' => 502]);
check('a unit: its line, one stay, then a rental and a service planned', array_column($life, 'why') === ['opening', 'rental', 'service'], array_column($life, 'why'));
$week = cube($pdo, ['customer' => 7, 'at' => (new DateTimeImmutable('today'))->modify('+7 days 12 hours')]);
check('a customer at a moment next week: bike 502 with them', array_column($week, 'unit') === [502] && $week[0]['place'] === 'customer:7', $week);
$road = cube($pdo, ['place' => 'road:55', 'between' => ['2026-10-01', null]]);
check('a place over a period: bike 500 on road 55', array_column($road, 'unit') === [500], $road);
$bench = cube($pdo, ['at' => 'now', 'state' => 'validating', 'owner' => 'location:1']);
check('a state and an owner: what the master has on the bench', array_column($bench, 'unit') === [504], $bench);
$perPlace = cubeSelect($pdo, ['at' => 'now', 'model' => 100, 'layer' => 'fact'])->resetColumns()
    ->columns('c.place', 'COUNT(*)')->groupBy('c.place')->orderBy('c.place')->fetchKeyPair();
check('a model widened, grouped like any Select: its units per place', $perPlace == ['location:1' => 3, "road:{$transferId}" => 1, 'road:55' => 1], $perPlace);
check('two encounters cannot happen', positionsCount($pdo, cubeConflicts($pdo)) === 2, cubeConflicts($pdo)->fetchAll());
$wrong = [];
foreach ([['units' => [502]], ['at' => 'now', 'between' => ['2026-10-01', null]], ['place' => 'shop 2']] as $axes) {
    try {
        cube($pdo, $axes);
    } catch (InvalidArgumentException $e) {
        $wrong[] = $e->getMessage();
    }
}
check('a misspelt axis, two times, a place that is no coordinate: each refused, none answers the whole cube', count($wrong) === 3, $wrong);

// one dot, and the dot advanced by an action
$dot = cubeDot($pdo, ['unit' => 504]);
check('a single dot: bike 504 on the bench at the master', $dot['state'] === 'validating' && $dot['place'] === 'location:1', $dot);
$dot = cubeDot($pdo, ['unit' => 504], 'built', ['assembly' => 81]);
check('advanced by built: the dot it is in now', $dot['state'] === 'available' && $dot['why'] === 'built', $dot);
try {
    cubeDot($pdo, ['unit' => 504], 'built', ['assembly' => 81]);
    check('built twice is refused', false);
} catch (MovementRefused $e) {
    check('built twice is refused, coded, with its facts', $e->sqlState === 'MV022' && $e->facts['state'] === 'available', [$e->sqlState, $e->getMessage()]);
}
$dot = cubeDot($pdo, ['unit' => 504], 'back_to_bench', ['assembly' => 81]);
check('advanced by back_to_bench: validating again', $dot['state'] === 'validating' && $dot['why'] === 'back_to_bench', $dot);
$wrong = [];
foreach ([[['unit' => 504], 'paint', []], [['unit' => 504], 'built', []], [['unit' => 504, 'at' => '2026-10-15'], 'built', ['assembly' => 81]]] as [$axes, $action, $with]) {
    try {
        cubeDot($pdo, $axes, $action, $with);
    } catch (InvalidArgumentException $e) {
        $wrong[] = $e->getMessage();
    }
}
check('an unknown action, an action without what it needs, an action dated back: each told apart', count($wrong) === 3, $wrong);
$line = cube($pdo, ['unit' => 504, 'layer' => 'fact']);
check('its line: the opening, built, back to the bench', array_column($line, 'why') === ['opening', 'built', 'back_to_bench'], array_column($line, 'why'));
$since = $line[1]['starts'];
check('from the build on: both events in the period, one cell at the moment', count(cube($pdo, ['unit' => 504, 'between' => [$since, null]])) === 2
    && count(cube($pdo, ['unit' => 504, 'at' => $since])) === 1);

// the kernels (units.php, journal.php, trajectory.php): the shapes of CONTRACT.md
$at = fn (string $place, string $state, string $why = 'opening', string $owner = '') => ['place' => $place, 'owner' => $owner ?: $place, 'state' => $state, 'why' => $why];
$words = [
    unitWord(null),
    unitWord($at('location:1', 'validating'), null, ['stage' => 'in_process']),
    unitWord($at('location:1', 'available'), ['kind' => 'draft']),
    unitWord($at('location:1', 'available'), null, null, null, ['location_id' => 2]),
    unitWord($at('road:55', 'available', 'dispatched', 'location:1')),
    unitWord($at('location:2', 'available', 'sold', 'customer:7')),
    unitWord($at('customer:7', 'available', 'loaned', 'location:1')),
    unitWord($at('customer:7', 'available', 'sold', 'customer:7'), null, null, ['phase' => 'in_work']),
];
check('the word: nothing, the bench, a draft, an earmark, the road, sold, a loan, the workshop', $words === ['unknown', 'assembling', 'held', 'assigned', 'transit', 'sold', 'loaned', 'workshop'], $words);
check('a service order: received, being worked on, finished, closed', [servicePhase('pending'), servicePhase('waiting_parts'), servicePhase('ready'), servicePhase('completed')] === ['received', 'in_work', 'finished', null]);

$units = array_column(unitRows($pdo, [500, 501, 502, 503, 504, 999999], ['purchase', 'cost', 'price']), null, 'id');
check('the units, each in its word: two on the road, one on an order, one in the fleet, one on the bench', array_map(fn ($u) => $u['word'], $units)
    === [500 => 'transit', 501 => 'reserved', 502 => 'fleet', 503 => 'transit', 504 => 'assembling'], array_map(fn ($u) => $u['word'], $units));
check('a unit on the road says where to, by keys and names', $units[500]['position']['where'] === ['key' => 'road', 'params' => ['to' => 'Prudente', 'transfers_id' => 55]]
    && $units[501]['claim'] === ['kind' => 'order', 'ref' => ['type' => 'orders', 'id' => 900]] && $units[504]['bench']['assembly_id'] === 81, [$units[500]['position']['where'], $units[501]['claim']]);
check('typed values: ids and prices are numbers', is_int($units[500]['model']['variants_id']) && is_float($units[500]['price']));

$master = stockUnitsList($pdo, [], 1);
check('the master\'s units: five, counted per word', $master['meta']['scopeTotal'] === 5 && $master['meta']['counts'] == ['transit' => 2, 'reserved' => 1, 'fleet' => 1, 'assembling' => 1], $master['meta']['counts']);
check('one word of them: the two on the road', stockUnitsList($pdo, ['word' => 'transit'], 1)['meta']['totalRows'] === 2);
check('Prudente\'s units: the two coming to it', array_column(stockUnitsList($pdo, [], 2)['data'], 'id') == [503, 500], array_column(stockUnitsList($pdo, [], 2)['data'], 'id'));

$log = movementsList($pdo, ['serial_id' => 503], 1);
check('a unit in the master\'s movements: dispatched (−1), after its opening (+1)', array_map(fn ($r) => [$r['kind'], $r['qty']], $log['data']) === [['dispatched', -1], ['opening', 1]],
    array_map(fn ($r) => [$r['kind'], $r['qty']], $log['data']));
check('a movement row\'s cells are coordinates, with their names beside', $log['data'][0]['from'] === ['place' => 'location:1', 'owner' => 'location:1', 'state' => 'available']
    && $log['data'][0]['to']['place'] === 'road:' . $transferId && $log['data'][0]['names']['road:' . $transferId] === 'Prudente', $log['data'][0]);
$helmets = movementsList($pdo, ['variants_id' => 200], 1)['data'];
check('one model alone carries its balance: the master\'s helmets, 5 − 2 − 1', $helmets[0]['balance'] === 2 && end($helmets)['balance'] === 5, array_column($helmets, 'balance'));

$life = unitTrajectory($pdo, 504);
check('its whole life: the line, the trail, the story', array_column(array_filter($life['line'], fn ($d) => $d['layer'] === 'fact'), 'why') === ['opening', 'built', 'back_to_bench']
    && array_column($life['trail'], 'state', 'key')['central'] === 'done'
    && in_array('assembly_started', array_column($life['events'], 'kind'), true), [array_column($life['trail'], 'state', 'key'), array_column($life['events'], 'kind')]);

// receive and arrive (ledger.php), in a transaction undone after
$pdo->beginTransaction();
$got = movementReceive($pdo, 301, 2, ['9C2KC1650PR000011']);
$dots = array_map(fn (int $u) => cubeDot($pdo, ['unit' => $u]), $got['units']);
check('a delivery received: two bikes minted on the bench at the master', $got['received'] === 2
    && array_column($dots, 'state') === ['validating', 'validating'] && array_column($dots, 'place') === ['location:1', 'location:1'], $got);
try {
    movementReceive($pdo, 301, 3, ['9C2KC1650PR000001']);
    check('a number already a unit\'s is refused', false);
} catch (MovementRefused $e) {
    check('a number already a unit\'s is refused, with the unit that has it', $e->sqlState === 'MV036' && $e->facts['serials_id'] === 500, [$e->sqlState, $e->facts]);
}
$pdo->query("SELECT set_config('app.location', '2', true)");
$came = movementArrive($pdo, 55, 311, 0, [500]);
check('a remessa\'s bike arrived: Prudente\'s now, its two helmets still on the road', $came['units'] === [500] && $came['on_road'] === 2
    && cubeDot($pdo, ['unit' => 500])['owner'] === 'location:2', $came);
$pdo->rollBack();
check('undone: bike 500 back on its road, the line as it was', cubeDot($pdo, ['unit' => 500])['place'] === 'road:55');

// the sale path (ledger.php), in a transaction undone after: order 900 paid, sold, handed over
$pdo->beginTransaction();
$pdo->exec("SET LOCAL session_replication_role = replica");
$pdo->exec("UPDATE orders SET paid = true, status = 'paid', customers_id = 7 WHERE id = 900");
$pdo->exec("SET LOCAL session_replication_role = origin");
$sold = movementSell($pdo, 900);
$word = fn () => unitRows($pdo, [501])[0]['word'];
check('a paid order sold: bike 501 its customer\'s, still at the shop', count($sold['sold']) === 1 && $word() === 'sold', [$sold, $word()]);
$handed = movementHandOver($pdo, 900);
check('handed over: with its customer now', count($handed['handed_over']) === 1 && $word() === 'delivered', [$handed, $word()]);
try {
    movementUnsell($pdo, $sold['sold'][0], 'cancel');
    check('a handed-over sale is not undone', false);
} catch (MovementRefused $e) {
    check('a handed-over sale is not undone: it is returned', $e->sqlState === 'MV061', $e->sqlState);
}
$pdo->rollBack();
check('undone: bike 501 on its order again, not sold', $word() === 'reserved');

// a dot written off through its action (cube.php), in a transaction undone after
$pdo->beginTransaction();
$pdo->exec("SET LOCAL session_replication_role = replica");
$pdo->exec("INSERT INTO approvals (id, action, ref_type, ref_id, requested_by, approved_by, approved_via, reason, location_id) OVERRIDING SYSTEM VALUE
            VALUES (90, 'baixa_moto', 'serials', 504, 1, 1, 'self', 'total loss', 1)");
$pdo->exec("SET LOCAL session_replication_role = origin");
$dot = cubeDot($pdo, ['unit' => 504], 'written_off', ['approval' => 90, 'note' => 'total loss']);
check('a dot written off by its action: written off where it stands', $dot['state'] === 'written_off' && $dot['why'] === 'written_off' && unitRows($pdo, [504])[0]['word'] === 'written_off', $dot);
$pdo->rollBack();
check('undone: bike 504 on the bench again', cubeDot($pdo, ['unit' => 504])['state'] === 'validating');

// an adjustment, a rental, a loan, a quick transfer and a count (ledger.php, cube.php), in a transaction undone after
$pdo->beginTransaction();
$adjusted = movementAdjust($pdo, [['variants_id' => 200, 'qty' => -1]], 'damaged', 'dropped');
check('an adjustment: one helmet damaged at the master, 2 → 1, one movement', $adjusted['adjusted'] === 1 && is_int($adjusted['movement_id'])
    && $adjusted['items'] == [['variants_id' => 200, 'before' => 2, 'after' => 1, 'delta' => -1]], $adjusted);
$row = movementsList($pdo, ['variants_id' => 200], 1)['data'][0];
check('the journal row carries its reason, and the balance after it', $row['kind'] === 'adjusted' && $row['reason'] === 'damaged' && $row['qty'] === -1
    && $row['balance'] === 1 && $row['to'] === ['place' => 'location:1', 'owner' => 'location:1', 'state' => 'written_off'], $row);
try {
    movementAdjust($pdo, [['variants_id' => 100, 'qty' => 1]], 'found', 'a bike');
    check('a bike adjusted by quantity is refused', false);
} catch (MovementRefused $e) {
    check('a bike adjusted by quantity is refused: through its unit, its model in the facts', $e->sqlState === 'MV110' && $e->facts === ['variants_id' => 100], [$e->sqlState, $e->facts]);
}
$word = fn (int $unit) => unitRows($pdo, [$unit])[0]['word'];
$booking = (int) $pdo->query('SELECT id FROM bookings WHERE resource_id = 1 ORDER BY id LIMIT 1')->fetchColumn();
$out = movementRentOut($pdo, $booking);
check('a rental out: bike 502 with its customer, the master\'s still', $out === ['done' => true] && $word(502) === 'rented'
    && cubeDot($pdo, ['unit' => 502])['place'] === 'customer:7' && cubeDot($pdo, ['unit' => 502])['owner'] === 'location:1', [$out, $word(502)]);
check('out again is nothing', movementRentOut($pdo, $booking) === ['done' => false]);
check('back: in the fleet again', movementRentBack($pdo, $booking) === ['done' => true] && $word(502) === 'fleet', $word(502));
claimFleetRelease($pdo, 1);
$pdo->exec("SET LOCAL session_replication_role = replica");
$loan = (int) $pdo->query("INSERT INTO loans (serials_id, borrower_name, due_at, customers_id, location_id)
                           VALUES (502, 'Cliente Sete', CURRENT_DATE + 7, 7, 1) RETURNING id")->fetchColumn();
$pdo->exec("SET LOCAL session_replication_role = origin");
movementLoanOut($pdo, $loan);
check('a loan out: bike 502 on loan, with its customer', $word(502) === 'loaned' && cubeDot($pdo, ['unit' => 502])['customer'] === 7, $word(502));
movementLoanBack($pdo, $loan);
$dot = cubeDot($pdo, ['unit' => 502], 'flipped', ['to' => 2]);
check('a dot flipped by its action: Prudente\'s at once, standing there, available', $dot['place'] === 'location:2' && $dot['owner'] === 'location:2'
    && $dot['state'] === 'available' && $dot['why'] === 'flipped' && $word(502) === 'stock', $dot);
try {
    movementFlip($pdo, 1, 2, [], [['variants_id' => 200, 'qty' => 5]]);
    check('more helmets flipped than the master has is refused', false);
} catch (MovementRefused $e) {
    check('more helmets flipped than the master has is refused, with what it has', $e->sqlState === 'MV132' && $e->facts['have'] === 1 && $e->facts['want'] === 5, [$e->sqlState, $e->facts]);
}
$pdo->exec("SET LOCAL session_replication_role = replica");
$count = (int) $pdo->query("INSERT INTO stock_counts (location_id) VALUES (1) RETURNING id")->fetchColumn();
$pdo->exec("INSERT INTO stock_count_lines (counts_id, kind, variants_id, counted_qty, location_id) VALUES ({$count}, 'part', 200, 3, 1)");
$pdo->exec("SET LOCAL session_replication_role = origin");
$closed = movementCountClose($pdo, $count);
check('a count closed: the master\'s helmets set to the 3 counted, 1 → 3', $closed['adjusted'] === 1
    && $closed['items'] == [['variants_id' => 200, 'before' => 1, 'after' => 3, 'delta' => 2]], $closed);
$pdo->rollBack();
check('undone: bike 502 in the fleet at the master, and two helmets', $word(502) === 'fleet'
    && (int) $pdo->query('SELECT qty FROM stock_on_hand WHERE location_id = 1 AND variants_id = 200')->fetchColumn() === 2);
