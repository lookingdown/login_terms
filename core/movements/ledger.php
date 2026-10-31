<?php
/**
 * core/movements/ledger.php — the writing side of the movement layer (movements-code.md §4).
 *
 * One function per event, each one call to its database function, which holds the guards.
 * Inside the caller's transaction a call runs in a savepoint: a refusal undoes the event
 * alone and the caller's transaction stays usable. Without one, the call is its own.
 */

use Atlas\Query\Select;

/** A refusal from the database: its code (MV0nn), the operator's Portuguese, and its facts. */
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
