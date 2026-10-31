<?php
/**
 * core/movements — the movement layer's PHP face. One require loads it:
 *
 *   require_once '/var/sys/core/movements/movements.php';
 *
 * ledger.php is the writing side (one function per event), positions.php the reading side, and
 * cube.php the consumer's door: any angle of the cube in, dots out; one dot advanced by an action
 * (CONSUMERS.md). The database holds the rules: sql/.
 */

require_once __DIR__ . '/ledger.php';
require_once __DIR__ . '/positions.php';
require_once __DIR__ . '/cube.php';
