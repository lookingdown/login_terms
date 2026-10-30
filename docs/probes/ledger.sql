-- The ledger's invariants as plain constraints, and the roles that make "no other way" true,
-- on PostgreSQL 18. Review findings 3, 8, 13 and 15.
--
-- Run as a superuser (it creates two roles and drops them) on a scratch database:
--   psql -d scratch -f ledger.sql
-- Needs btree_gist for part 3. Some statements fail on purpose: each \echo says what to look for.
-- The cell is reduced to (kind, id) here; the layer's cell is where · owner · state.

\set ON_ERROR_STOP 0
\pset footer off
SET client_min_messages = warning;
DROP SCHEMA IF EXISTS probe_ledger CASCADE;
CREATE SCHEMA probe_ledger;
SET search_path = probe_ledger;

CREATE TABLE locations (id int PRIMARY KEY);
CREATE TABLE transfers (id bigint PRIMARY KEY);
INSERT INTO locations VALUES (1), (2);
INSERT INTO transfers VALUES (55);

-- one row per hop of a unit: from a cell to a cell (−1 there, +1 here)
CREATE TABLE hops (
  serials_id      int    NOT NULL,
  seq             int    NOT NULL CHECK (seq >= 1),
  prev_seq        int    CHECK ((seq = 1) = (prev_seq IS NULL) AND (prev_seq IS NULL OR prev_seq = seq - 1)),
  from_kind       text   NOT NULL,
  from_id         bigint NOT NULL,
  to_kind         text   NOT NULL CHECK (to_kind IN ('location', 'road', 'customer')),
  to_id           bigint NOT NULL,
  -- a foreign key skips its check when any column is NULL, so the cell is NOT NULL (kind, id),
  -- and the typed foreign keys hang on STORED generated columns (18's default, VIRTUAL, takes none)
  to_location_id  int    GENERATED ALWAYS AS (CASE WHEN to_kind = 'location' THEN to_id END) STORED REFERENCES locations,
  to_transfers_id bigint GENERATED ALWAYS AS (CASE WHEN to_kind = 'road' THEN to_id END) STORED REFERENCES transfers,
  occurred_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (serials_id, seq),                                        -- no fork: one successor per hop
  UNIQUE (serials_id, seq, to_kind, to_id),
  FOREIGN KEY (serials_id, prev_seq, from_kind, from_id)
    REFERENCES hops (serials_id, seq, to_kind, to_id)                   -- unbroken: a unit leaves where it last arrived
);

\echo
\echo '== 1. a unit''s chain. Expect: the receipt and the dispatch pass; the fork, the skipped step,'
\echo '      the hop from a road the unit is not on, and the hop to an unknown location are refused.'
INSERT INTO hops (serials_id, seq, prev_seq, from_kind, from_id, to_kind, to_id) VALUES (7, 1, NULL, 'none', 0, 'location', 1);
INSERT INTO hops (serials_id, seq, prev_seq, from_kind, from_id, to_kind, to_id) VALUES (7, 2, 1, 'location', 1, 'road', 55);
\echo '-- fork (a second seq 2):'
INSERT INTO hops (serials_id, seq, prev_seq, from_kind, from_id, to_kind, to_id) VALUES (7, 2, 1, 'location', 1, 'customer', 10);
\echo '-- skipped step (seq 4 after 2):'
INSERT INTO hops (serials_id, seq, prev_seq, from_kind, from_id, to_kind, to_id) VALUES (7, 4, 3, 'road', 55, 'location', 2);
\echo '-- off a road it is not on:'
INSERT INTO hops (serials_id, seq, prev_seq, from_kind, from_id, to_kind, to_id) VALUES (7, 3, 2, 'road', 56, 'location', 2);
\echo '-- onto a location that does not exist:'
INSERT INTO hops (serials_id, seq, prev_seq, from_kind, from_id, to_kind, to_id) VALUES (7, 3, 2, 'road', 55, 'location', 9);
SELECT string_agg(format('seq %s: %s %s -> %s %s', seq, from_kind, from_id, to_kind, to_id), ' | ' ORDER BY seq) AS unit_7 FROM hops;

\echo
\echo '== 2. quantities. Expect: the road is a cell too, so arriving more than was dispatched is refused.'
CREATE TABLE stock_balance (
  cell_kind   text   NOT NULL,
  cell_id     bigint NOT NULL,
  variants_id bigint NOT NULL,
  qty         int    NOT NULL CHECK (qty >= 0),
  PRIMARY KEY (cell_kind, cell_id, variants_id)
);
INSERT INTO stock_balance VALUES ('road', 55, 900, 3), ('location', 2, 900, 0);
\echo '-- arrive 4 of the 3 on the road:'
UPDATE stock_balance SET qty = qty - 4 WHERE cell_kind = 'road' AND cell_id = 55 AND variants_id = 900;
\echo '-- arrive 2: 18 answers the old and the new balance in the same statement (RETURNING old/new):'
UPDATE stock_balance SET qty = qty - 2 WHERE cell_kind = 'road' AND cell_id = 55 AND variants_id = 900
RETURNING format('road 55: %s -> %s', old.qty, new.qty) AS balance;

\echo
\echo '== 3. the time axis (18, btree_gist). Expect: a backdated residence that overlaps an existing one is refused.'
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE TABLE unit_residence (
  serials_id int       NOT NULL,
  cell       text      NOT NULL,
  during     tstzrange NOT NULL,
  PRIMARY KEY (serials_id, during WITHOUT OVERLAPS)
);
INSERT INTO unit_residence VALUES (7, 'location 1', tstzrange('2026-10-01', '2026-10-20')),
                                  (7, 'road 55',    tstzrange('2026-10-20', NULL));
\echo '-- a correction backdated to 15 Oct, overlapping both:'
INSERT INTO unit_residence VALUES (7, 'location 2', tstzrange('2026-10-15', '2026-10-25'));

\echo
\echo '== 4. roles. Expect: a new function is executable by PUBLIC; a seat at location 1 reads 2 rows from the'
\echo '      table and from a security_invoker view, but 4 (every location''s) through a plain view.'
DROP ROLE IF EXISTS probe_owner;
DROP ROLE IF EXISTS probe_app;
CREATE ROLE probe_owner NOLOGIN;
CREATE ROLE probe_app NOLOGIN;
CREATE SCHEMA probe_roles AUTHORIZATION probe_owner;
GRANT USAGE ON SCHEMA probe_roles TO probe_app;
SET ROLE probe_owner;
CREATE TABLE probe_roles.serials (id int, location_id int);
INSERT INTO probe_roles.serials VALUES (1, 1), (2, 1), (3, 2), (4, 3);
ALTER TABLE probe_roles.serials ENABLE ROW LEVEL SECURITY;
CREATE POLICY seat ON probe_roles.serials USING (location_id = current_setting('app.location')::int);
GRANT SELECT ON probe_roles.serials TO probe_app;
CREATE VIEW probe_roles.v_plain AS SELECT id FROM probe_roles.serials;
CREATE VIEW probe_roles.v_invoker WITH (security_invoker = true) AS SELECT id FROM probe_roles.serials;
GRANT SELECT ON probe_roles.v_plain, probe_roles.v_invoker TO probe_app;
CREATE FUNCTION probe_roles.movement_anything() RETURNS int LANGUAGE sql AS 'SELECT 1';
RESET ROLE;
SELECT 'EXECUTE for PUBLIC on a new function: ' || has_function_privilege('public', 'probe_roles.movement_anything()', 'EXECUTE') AS result;
SET ROLE probe_app;
SET app.location = '1';
SELECT 'seat at location 1, table:                 ' || count(*) AS result FROM probe_roles.serials;
SELECT 'seat at location 1, plain view:            ' || count(*) AS result FROM probe_roles.v_plain;
SELECT 'seat at location 1, security_invoker view: ' || count(*) AS result FROM probe_roles.v_invoker;
RESET ROLE;
RESET app.location;

DROP SCHEMA probe_roles CASCADE;
DROP ROLE probe_owner;
DROP ROLE probe_app;
DROP SCHEMA probe_ledger CASCADE;
