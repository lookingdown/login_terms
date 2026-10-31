<?php
/**
 * core/movements/ledger.php — the writing side of the movement layer (movements-code.md §4).
 *
 * One function per event, each one call to its database function, which holds the guards.
 * Inside the caller's transaction a call runs in a savepoint: a refusal undoes the event
 * alone and the caller's transaction stays usable. Without one, the call is its own.
 */

use Atlas\Query\Select;

/**
 * A refusal from the database: its code (MV0nn), which is its i18n key (mvRefused_<code>); an English message,
 * for the log; and its facts, the key's parameters.
 */
final class MovementRefused extends RuntimeException
{
    public function __construct(
        string $message,
        public readonly string $sqlState,
        public readonly array $facts,
        ?Throwable $previous = null,
    ) {
        parent::__construct($message, 0, $previous);
    }
}

/**
 * Calls one event's database function and answers its jsonb, decoded.
 *
 * @param string $function a function of this file's, never input
 * @param array<int, array{0: mixed, 1: string}> $args [value, sql type]; an array goes as jsonb
 * @throws MovementRefused when the database refuses the event
 */
function movementCall(PDO $pdo, string $function, array $args = []): array
{
    $select = Select::new($pdo);
    $values = [];
    foreach ($args as [$value, $type]) {
        if (is_array($value)) {
            $value = json_encode($value, JSON_THROW_ON_ERROR);
            $type = 'jsonb';
        }
        $values[] = 'CAST(' . $select->bindInline($value) . " AS {$type})";
    }
    $select->columns($function . '(' . implode(', ', $values) . ') AS answer');

    $own = !$pdo->inTransaction();
    $own ? $pdo->beginTransaction() : $pdo->exec('SAVEPOINT movement');
    try {
        $answer = $select->fetchValue();
        $own ? $pdo->commit() : $pdo->exec('RELEASE SAVEPOINT movement');
    } catch (PDOException $e) {
        $own ? $pdo->rollBack() : $pdo->exec('ROLLBACK TO SAVEPOINT movement');
        throw movementRefusal($e);
    }
    return json_decode((string) $answer, true, 512, JSON_THROW_ON_ERROR);
}

/**
 * A refusal (SQLSTATE MV0nn) as MovementRefused, read from the one mv: line mv_refuse() writes;
 * anything else is a bug and goes on as it is. PostgreSQL's own labels are never read.
 */
function movementRefusal(PDOException $e): Throwable
{
    $state = (string) $e->getCode();
    if (!str_starts_with($state, 'MV') || !preg_match('/mv:(\{.*\})$/m', $e->errorInfo[2] ?? '', $m)) {
        return $e;
    }
    $line = json_decode($m[1], true, 512, JSON_THROW_ON_ERROR);
    return new MovementRefused($line['message'], $state, $line['facts'] ?? [], $e);
}

/**
 * Event 5, the truck leaves: every unit the remessa holds and every counted line go onto its road.
 * The module has written its documents and set the remessa 'sent' first, as 009 expects.
 * Refused: not at the master, not sent, already on the road, a unit not in the sender's stock,
 * a bike line without its unit, materials, too few counted goods.
 *
 * @return array{legs: int}
 */
function movementDispatch(PDO $pdo, int $transferId): array
{
    return movementCall($pdo, 'movement_dispatch', [[$transferId, 'bigint']]);
}

/**
 * Events 3 and 4, assembly passed and failed: only the state changes, where the bike stands, by its
 * assembly job. Refused: not this job's unit, not in that state, another location's bike, and back to the
 * bench for a claimed unit (an order, a remessa draft, the fleet).
 *
 * @return array{state: string}
 */
function movementBuilt(PDO $pdo, int $serialId, int $assemblyId): array
{
    return movementCall($pdo, 'movement_built', [[$serialId, 'integer'], [$assemblyId, 'bigint']]);
}

/** @return array{state: string} */
function movementBackToBench(PDO $pdo, int $serialId, int $assemblyId): array
{
    return movementCall($pdo, 'movement_back_to_bench', [[$serialId, 'integer'], [$assemblyId, 'bigint']]);
}

/**
 * Events 1 and 2, a supplier's delivery line received to its new total, or its receipt corrected down. Each new
 * unit is minted on the bench, numbered when $numbers gives it one (in order); a correction down returns units that
 * are nothing yet to the supplier. The line's qty_received follows. Refused: another location's order, a remessa's
 * line (it arrives), a cancelled order, materials, a number already a unit's, more numbers than new units, a
 * correction below units that are something already.
 *
 * @param list<string|array{serial_number?: string, observations?: string}> $numbers
 * @return array{received: int, units: list<int>}
 */
function movementReceive(PDO $pdo, int $purchaseItemId, int $newReceived, array $numbers = []): array
{
    $numbers = array_map(fn ($n) => is_array($n) ? $n : ['serial_number' => (string) $n], array_values($numbers));
    return movementCall($pdo, 'movement_receive', [[$purchaseItemId, 'bigint'], [$newReceived, 'integer'], [$numbers, 'jsonb']]);
}

/**
 * Event 6, a remessa's line arrived at this location ($shopLineId: the shop's purchase line). The named units (the
 * set the shop has) that are still on the road arrive; with none named, the oldest of the line's model, up to the
 * new total; counted goods by quantity. What arrived does not go back. `on_road` is what the remessa still carries.
 *
 * @param list<int> $units
 * @return array{arrived: int, units: list<int>, on_road: int}
 */
function movementArrive(PDO $pdo, int $transferId, int $shopLineId, int $newReceived, array $units = []): array
{
    return movementCall($pdo, 'movement_arrive', [[$transferId, 'bigint'], [$shopLineId, 'bigint'], [$newReceived, 'integer'],
                                                  [array_values(array_map('intval', $units)), 'jsonb']]);
}

/**
 * Event 11, sold: each line of the paid order that has its unit becomes the customer's; counted goods leave the
 * stock. Run it when the order is paid and again after a late attach: it sells only what is not sold yet, and
 * stamps each line's cost. `waiting`: the bike lines still without their unit.
 *
 * @return array{sold: list<int>, waiting: list<int>}
 */
function movementSell(PDO $pdo, int $orderId): array
{
    return movementCall($pdo, 'movement_sell', [[$orderId, 'bigint']]);
}

/**
 * Event 12, handed over: every sold unit of the paid order is with its customer now. Refused while a bike line has
 * no unit. At the till it follows movementSell() in the same transaction.
 *
 * @return array{handed_over: list<int>}
 */
function movementHandOver(PDO $pdo, int $orderId): array
{
    return movementCall($pdo, 'movement_hand_over', [[$orderId, 'bigint']]);
}

/**
 * Event 13, the sale of one line undone (a void, a cancel, a refund before the handover). $why: the reason, as the
 * module words it. A handed-over unit is returned instead.
 *
 * @return array{undone: int}
 */
function movementUnsell(PDO $pdo, int $saleId, ?string $why = null): array
{
    return movementCall($pdo, 'movement_unsell', [[$saleId, 'bigint'], [$why, 'text']]);
}

/**
 * Event 14, returned after the handover, by the order's customer, to the order's location: a unit, or $qty of a
 * line's counted goods (up to what it has out). $why: the reason, as the module words it.
 *
 * @return array{returned: int}
 */
function movementReturn(PDO $pdo, int $saleId, int $qty = 1, ?string $why = null): array
{
    return movementCall($pdo, 'movement_return', [[$saleId, 'bigint'], [$qty, 'integer'], [$why, 'text']]);
}

