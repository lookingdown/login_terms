<?php
/**
 * core/movements — the movement layer's PHP face. One require loads it:
 *
 *   require_once '/var/sys/core/movements/movements.php';
 *
 * ledger.php is the writing side (one function per event), positions.php the reading side, and
 * cube.php the consumer's door: any angle of the cube in, dots out; one dot advanced by an action
 * (CONSUMERS.md). The kernels give the screens their shapes (CONTRACT.md): units.php (a unit, its
 * word, the units list), journal.php (the movements) and trajectory.php (a unit's whole life).
 * The database holds the rules: sql/.
 */

require_once __DIR__ . '/ledger.php';
require_once __DIR__ . '/positions.php';
require_once __DIR__ . '/cube.php';
require_once __DIR__ . '/units.php';
require_once __DIR__ . '/journal.php';
require_once __DIR__ . '/trajectory.php';
