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
$transferId = (int) $pdo->query("INSERT INTO transfers (shop_purchases_id, status, location_id, to_location_id) VALUES (3, 'draft', 1, 2) RETURNING id")->fetchColumn();
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
check('the organisation still owns every bike and helmet', stockTotal($pdo) == [100 => 4, 200 => 5], stockTotal($pdo));

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

// the cube (after tests/cube-test.sql): a slice then and now, a unit's line, the encounters that cannot happen
$then = positionsAt($pdo, new DateTimeImmutable('2026-10-15'))->where('wa.serials_id = ', 503)->fetchOne();
$now = positionsAt($pdo, new DateTimeImmutable())->where('wa.serials_id = ', 503)->fetchOne();
check('bike 503 stood at the master on 15 Oct, and is on its road now', $then['place_kind'] === 'location' && $now['place_kind'] === 'road', [$then['place_kind'], $now['place_kind']]);
$asKnown = positionsAt($pdo, new DateTimeImmutable('2026-10-15'), new DateTimeImmutable('2026-10-15'));
check('as the books stood on 15 Oct, they knew no unit yet', positionsCount($pdo, $asKnown) === 0);
$line = unitTrajectory($pdo, 502);
check('bike 502\'s line: one stay, then a rental and a service planned', array_column($line, 'how') === ['opening', 'rental', 'service'], array_column($line, 'how'));
check('two encounters cannot happen', positionsCount($pdo, positionsConflicts($pdo)) === 2, positionsConflicts($pdo)->fetchAll());
