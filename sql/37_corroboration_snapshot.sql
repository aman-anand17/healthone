-- ===========================================================================
-- A SNAPSHOT OF THE CORROBORATION VIEW, BECAUSE THE VIEW IS TOO SLOW TO READ
-- ON EVERY PAGE RENDER.
--
-- MEASURED, not assumed. Selecting five columns from
-- RULES.V_PROPOSAL_CORROBORATION took 40 SECONDS end to end against ~15s for a
-- trivial query on the same warehouse - so roughly 25 seconds of actual work
-- for nine rows. The cause is not the row count: the view calls the Python UDF
-- RULES.INTERVAL_FROM_PHRASE per proposal and runs REGEXP matching over the
-- document chunk text, and a Python UDF pays sandbox start-up on top of that.
--
-- The app reads this view twice on the Rule library page (once for proposals,
-- once to decorate active rules), so opening that tab cost most of a minute.
-- In a four-minute demo that is unusable, and for a reviewer it is simply bad.
--
-- WHY A TABLE AND NOT A MATERIALIZED VIEW: Snowflake materialized views cannot
-- reference a view, a UDF, or non-deterministic expressions, and this view is
-- built on all three. A dynamic table is also out - same UDF restriction for
-- incremental mode, and FULL refresh would just move the 25 seconds elsewhere.
--
-- WHY THIS IS NOT A CACHE THAT CAN LIE: corroboration is a pure function of
-- (proposals, document chunks, vocabulary). Nothing else can change it. So the
-- snapshot is refreshed by the three operations that change those inputs -
-- ingest, approve, reject - and the app calls the refresh immediately after
-- each. The live view remains the definition and the source of truth; this is
-- its last computed result. tests/test_corroboration.sql still asserts against
-- the VIEW, so the nine checks can never drift into being whatever the
-- snapshot happens to hold.
-- ===========================================================================

USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE WAREHOUSE HO_WH;

-- Shape is taken from the view itself, so the two cannot drift apart when a
-- check is added. CREATE OR REPLACE ... AS SELECT also populates it.
CREATE OR REPLACE TABLE RULES.CORROBORATION_SNAPSHOT AS
SELECT *, CURRENT_TIMESTAMP() AS SNAPSHOT_AT
  FROM RULES.V_PROPOSAL_CORROBORATION;

COMMENT ON TABLE RULES.CORROBORATION_SNAPSHOT IS
  'Last computed result of RULES.V_PROPOSAL_CORROBORATION. The view is the
   definition; this exists because the view costs ~25s to read (Python UDF plus
   regex per proposal) and the app reads it on every Rule library render.
   Refreshed by SP_REFRESH_CORROBORATION after ingest, approve and reject -
   the only three operations that can change its inputs.';

-- ---------------------------------------------------------------------------
-- The refresh. CREATE OR REPLACE TABLE ... AS SELECT inside a procedure would
-- drop and recreate the object, losing the grant to HO_REVIEWER, so this
-- deletes and reinserts instead. Both statements are in one transaction: a
-- reader must never see an empty snapshot.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE RULES.SP_REFRESH_CORROBORATION()
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Recompute RULES.CORROBORATION_SNAPSHOT from the live view. Call after ingest, approve or reject.'
EXECUTE AS OWNER
AS
$$
DECLARE
  n INT;
BEGIN
  BEGIN TRANSACTION;
    DELETE FROM RULES.CORROBORATION_SNAPSHOT;
    INSERT INTO RULES.CORROBORATION_SNAPSHOT
      SELECT *, CURRENT_TIMESTAMP() FROM RULES.V_PROPOSAL_CORROBORATION;
    SELECT COUNT(*) INTO :n FROM RULES.CORROBORATION_SNAPSHOT;
  COMMIT;
  RETURN OBJECT_CONSTRUCT('ok', TRUE, 'rows', :n);
EXCEPTION
  WHEN OTHER THEN
    ROLLBACK;
    RETURN OBJECT_CONSTRUCT('ok', FALSE, 'error', SQLERRM);
END;
$$;

GRANT SELECT ON TABLE RULES.CORROBORATION_SNAPSHOT TO ROLE HO_REVIEWER;
GRANT USAGE ON PROCEDURE RULES.SP_REFRESH_CORROBORATION() TO ROLE HO_REVIEWER;

-- Prove it: the snapshot must agree with the view it came from.
SELECT 'snapshot rows'  AS k, COUNT(*)::STRING AS v FROM RULES.CORROBORATION_SNAPSHOT
UNION ALL
SELECT 'view rows', COUNT(*)::STRING FROM RULES.V_PROPOSAL_CORROBORATION;
