#!/usr/bin/env bash
# Two tills sell the same bike at once. Review §6 (optional: the chain's key as the lock).
# The hop key alone serialises them: till B waits for till A's commit, then is refused; one sale exists.
#
#   PGDATABASE=scratch bash race.sh        (any psql connection settings work: PGHOST, PGPORT, PGUSER …)
set -u
psql_q() { psql -X -q -tA -v ON_ERROR_STOP=0 "$@"; }

psql_q <<'SQL'
SET client_min_messages = warning;
DROP SCHEMA IF EXISTS probe_race CASCADE;
CREATE SCHEMA probe_race;
CREATE TABLE probe_race.hops (
  serials_id int NOT NULL, seq int NOT NULL, to_cell text NOT NULL,
  PRIMARY KEY (serials_id, seq));
INSERT INTO probe_race.hops VALUES (7, 1, 'location 1');
SQL

# till A: sells unit 7 (its hop 2) and holds the transaction open for 3 seconds
psql_q >/dev/null 2>&1 <<'SQL' &
BEGIN;
INSERT INTO probe_race.hops VALUES (7, 2, 'customer 10');
SELECT pg_sleep(3);
COMMIT;
SQL

sleep 1
start=$(date +%s)
echo "till B sells the same unit:"
psql_q -c "INSERT INTO probe_race.hops VALUES (7, 2, 'customer 11')" 2>&1 | sed 's/^/  /'
end=$(date +%s)
wait
echo "till B waited about $((end - start)) s for till A's commit"
echo "unit 7 now: $(psql_q -c "SELECT string_agg(seq || ' ' || to_cell, ' | ' ORDER BY seq) FROM probe_race.hops WHERE serials_id = 7")"
psql_q -c "DROP SCHEMA probe_race CASCADE" >/dev/null 2>&1
