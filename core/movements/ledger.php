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

/**
 * Event 7, not sent: taken off the remessa's road, back at the origin: a serial-tracked model by its named units,
 * counted goods by quantity. The master's.
 *
 * @param list<int> $serialIds
 * @return array{taken_off: int, units: list<int>, on_road: int}
 */
function movementNotSent(PDO $pdo, int $transferId, int $variantId, int $qty, array $serialIds = [], ?string $note = null): array
{
    return movementCall($pdo, 'movement_not_sent', [[$transferId, 'bigint'], [$variantId, 'bigint'], [$qty, 'integer'],
                                                    [array_values(array_map('intval', $serialIds)), 'jsonb'], [$note, 'text']]);
}

/**
 * Event 8, lost on the road: written off where it was, on the remessa's road. $bears: who bears the loss, 'origin'
 * or 'carrier'. The master's.
 *
 * @param list<int> $serialIds
 * @return array{taken_off: int, units: list<int>, on_road: int}
 */
function movementLost(PDO $pdo, int $transferId, int $variantId, int $qty, array $serialIds, string $bears, ?string $note = null): array
{
    return movementCall($pdo, 'movement_lost', [[$transferId, 'bigint'], [$variantId, 'bigint'], [$qty, 'integer'],
                                                [array_values(array_map('intval', $serialIds)), 'jsonb'], [$bears, 'text'], [$note, 'text']]);
}

/**
 * Event 9, swapped: the chassis that went was not the one the remessa names. A correction dated at the dispatch:
 * the named unit never left, the real one went. The master's; the same model; the real one free at the origin and
 * unmoved since the dispatch.
 *
 * @return array{swapped: bool, named: int, real: int}
 */
function movementSwap(PDO $pdo, int $transferId, int $namedSerialId, int $realSerialId, ?string $note = null): array
{
    return movementCall($pdo, 'movement_swap', [[$transferId, 'bigint'], [$namedSerialId, 'integer'], [$realSerialId, 'integer'], [$note, 'text']]);
}

/** A remessa draft holds a unit at its origin: available, where its owner stands, held by nothing else. @return array{held: bool} */
function claimHold(PDO $pdo, int $transferId, int $serialId): array
{
    return movementCall($pdo, 'claim_hold', [[$transferId, 'bigint'], [$serialId, 'integer']]);
}

/** A draft lets a unit go, or every unit it holds when $serialId is null. @return array{released: int} */
function claimRelease(PDO $pdo, int $transferId, ?int $serialId = null): array
{
    return movementCall($pdo, 'claim_release', [[$transferId, 'bigint'], [$serialId, 'integer']]);
}

/**
 * The attach: an order line takes its unit, available where the order is and held by nothing else. On an order paid
 * in full the sale is posted at once.
 *
 * @return array{attached: bool, sold: bool}
 */
function claimSale(PDO $pdo, int $saleId, int $serialId): array
{
    return movementCall($pdo, 'claim_sale', [[$saleId, 'bigint'], [$serialId, 'integer']]);
}

/** An order line lets its unit go, while it is not sold. @return array{released: bool, serials_id?: int} */
function claimSaleRelease(PDO $pdo, int $saleId): array
{
    return movementCall($pdo, 'claim_sale_release', [[$saleId, 'bigint']]);
}

/** The rental fleet takes a unit for one of its resources. @return array{held: bool} */
function claimFleet(PDO $pdo, int $resourceId, int $serialId): array
{
    return movementCall($pdo, 'claim_fleet', [[$resourceId, 'bigint'], [$serialId, 'integer']]);
}

/** The fleet lets a resource's unit go, unless it is out with a customer. @return array{released: bool, serials_id?: int} */
function claimFleetRelease(PDO $pdo, int $resourceId): array
{
    return movementCall($pdo, 'claim_fleet_release', [[$resourceId, 'bigint']]);
}

/**
 * Event 20, written off (theft, a total loss) where it stands. The master's, with the baixa_moto approval for this
 * unit; a unit in stock or on the bench, held by nothing.
 *
 * @return array{state: string}
 */
function movementWriteOff(PDO $pdo, int $serialId, int $approvalId, ?string $note = null): array
{
    return movementCall($pdo, 'movement_write_off', [[$serialId, 'integer'], [$approvalId, 'bigint'], [$note, 'text']]);
}

/**
 * Event 21, returned to the provider: to $supplierId, or else to the supplier it was bought from. As a write-off:
 * the master's, the approval, a unit in stock or on the bench, held by nothing.
 *
 * @return array{state: string, suppliers_id: int}
 */
function movementToProvider(PDO $pdo, int $serialId, int $approvalId, ?int $supplierId = null, ?string $note = null): array
{
    return movementCall($pdo, 'movement_to_provider', [[$serialId, 'integer'], [$approvalId, 'bigint'], [$supplierId, 'bigint'], [$note, 'text']]);
}

/**
 * Counted goods' lines as the database takes them: each ['variants_id' => …, 'qty' => …], or for an adjustment
 * ['variants_id' => …, 'balance' => …] (the balance it is to have). A key left out or null is not sent.
 */
function movementLines(array $lines): array
{
    $out = [];
    foreach ($lines as $line) {
        $row = [];
        foreach (['variants_id', 'qty', 'balance'] as $key) {
            if (isset($line[$key])) {
                $row[$key] = (int) $line[$key];
            }
        }
        $out[] = $row;
    }
    return $out;
}

/**
 * Event 10, flipped (Transferência rápida, step D): units and counted goods from $from to $to at once, with no road.
 * Only the master's admin or superadmin. Units by name, each available at $from and held by nothing; counted goods
 * as lines, ['variants_id' => …, 'qty' => …], up to what $from has.
 *
 * @return array{movement_id: int, units: int, lines: int}
 */
function movementFlip(PDO $pdo, int $from, int $to, array $serialIds = [], array $counted = [], ?string $note = null): array
{
    return movementCall($pdo, 'movement_flip', [[$from, 'integer'], [$to, 'integer'],
                                                [array_values(array_map('intval', $serialIds)), 'jsonb'],
                                                [movementLines($counted), 'jsonb'], [$note, 'text']]);
}

/**
 * Event 16, a rental goes out: the booking's fleet bike, to the booking's customer, still its location's. Refused
 * unless the booking is to come or under way and the bike is available where it is kept. Again is nothing.
 *
 * @return array{done: bool}
 */
function movementRentOut(PDO $pdo, int $bookingId): array
{
    return movementCall($pdo, 'movement_rent_out', [[$bookingId, 'bigint']]);
}

/** Event 17, the rental's bike back home, whatever the booking's status; only what went out on it. @return array{done: bool} */
function movementRentBack(PDO $pdo, int $bookingId): array
{
    return movementCall($pdo, 'movement_rent_back', [[$bookingId, 'bigint']]);
}

/**
 * Event 16, a loan goes out: its bike, to the loan's customer (a loan names one), still its location's. Refused
 * unless the loan is being prepared or with the person, and the bike is available and held by nothing.
 *
 * @return array{done: bool}
 */
function movementLoanOut(PDO $pdo, int $loanId): array
{
    return movementCall($pdo, 'movement_loan_out', [[$loanId, 'bigint']]);
}

/** Event 17, the loan's bike back home, whatever the loan's status; only what went out on it. @return array{done: bool} */
function movementLoanBack(PDO $pdo, int $loanId): array
{
    return movementCall($pdo, 'movement_loan_back', [[$loanId, 'bigint']]);
}

/**
 * Event 22, adjusted (Ajuste; adjustStock and adjustStockBatch): counted goods at the session's location, one line
 * or many, each ['variants_id' => …, 'qty' => the difference] or ['variants_id' => …, 'balance' => what it is to
 * have] (worked out under the model's lock), with its reason (found, damaged, loss, expired, count, other) and note.
 * A bike is refused: it is adjusted through its unit. Nothing differing posts nothing (movement_id null).
 *
 * @return array{adjusted: int, movement_id: ?int, items: list<array{variants_id: int, before: int, after: int, delta: int}>}
 */
function movementAdjust(PDO $pdo, array $lines, string $reason, string $note): array
{
    return movementCall($pdo, 'movement_adjust', [[movementLines($lines), 'jsonb'], [$reason, 'text'], [$note, 'text']]);
}

/**
 * Event 23, counted (Inventário): an open count's parts set to what was counted, as one movement, reason count.
 * The module closes the count after (fechado; parts_adjusted is adjusted). Closing twice posts nothing again.
 *
 * @return array{adjusted: int, movement_id: ?int, items: list<array{variants_id: int, before: int, after: int, delta: int}>}
 */
function movementCountClose(PDO $pdo, int $countId): array
{
    return movementCall($pdo, 'movement_count_close', [[$countId, 'bigint']]);
}

/**
 * Event 24, corrected (the supervisor, on the unit's page): the unit put in the cell it really is in. $cell speaks the
 * cube's coordinates: ['place' => 'location:2'], with 'owner' (the place's when left out) and 'state' (validating or
 * available; the unit's own when left out). The supervisor's word is $approvalId, an approval unit_correction for this
 * unit, used once; $note says why. Never a sale, never a write-off; a claimed unit only to where its holder stands.
 *
 * @return array{movement_id: int}
 */
function movementCorrect(PDO $pdo, int $serialId, int $approvalId, array $cell, string $note): array
{
    $location = function (string $axis) use ($cell): ?int {
        if (!isset($cell[$axis])) {
            return null;
        }
        if (!preg_match('/^location:(\d+)$/', (string) $cell[$axis], $m)) {
            throw new InvalidArgumentException("A correction puts a unit at a location: {$axis} is location:<id>, not {$cell[$axis]}.");
        }
        return (int) $m[1];
    };
    return movementCall($pdo, 'movement_correct', [[$serialId, 'integer'], [$approvalId, 'bigint'], [$location('place'), 'integer'],
                                                   [$location('owner'), 'integer'], [$cell['state'] ?? null, 'text'], [$note, 'text']]);
}

/**
 * Removing a unit that is nothing yet (deleteSerial): its receipt corrected down by this unit, with the supervisor's
 * approval unit_removal for it. Only a unit whose one movement is its receipt and that no document names. Its
 * number is freed; the answer gives it back, for the approval's record.
 *
 * @return array{removed: bool, purchase_items_id: int, serial_number: ?string}
 */
function movementUnitRemove(PDO $pdo, int $serialId, int $approvalId, ?string $note = null): array
{
    return movementCall($pdo, 'movement_unit_remove', [[$serialId, 'integer'], [$approvalId, 'bigint'], [$note, 'text']]);
}

