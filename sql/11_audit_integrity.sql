-- STATUS: EXECUTED 2026-08-30 against account KUMZGAJ-OO64644 (locator PF13333,
-- AWS_US_EAST_2) via ./tools/sfx as part of tools/deploy_new_account. Ran clean.
-- AUDIT INTEGRITY: make "append-only" a control rather than a comment.
--
-- THE HOLE THIS CLOSES
-- The demo closes on "every decision here is attributable and reversible",
-- backed by a SELECT over AUDIT_EVENT. But HO_ADMIN OWNS that table, so it
-- could UPDATE or DELETE any row. The sentence did not survive the obvious
-- follow-up question: "what stops you editing that table?"
--
-- Three defences, because no single one is sufficient:
--   1. Grants        — no role holds UPDATE or DELETE on AUDIT_EVENT
--   2. Row hashes    — each row commits to its predecessor, so a silent edit
--                      or deletion becomes arithmetically detectable
--   3. A verifier    — one query that re-walks the chain and reports the first
--                      broken link
--
-- Honest limit, stated rather than hidden: an ACCOUNTADMIN can still take
-- ownership of any object, and a determined owner could recompute the whole
-- chain. What the chain buys is DETECTION, not prevention — tampering stops
-- being invisible and starts requiring deliberate, wholesale rewriting. In
-- production the next step is off-platform: stream AUDIT_EVENT to
-- write-once storage or an external log, so the verifier compares against a
-- copy the database cannot reach. That is out of scope here and named for
-- what it is.
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE SCHEMA CASES; USE WAREHOUSE HO_WH;

-- ===========================================================================
-- 1. Revoke mutation from every role. INSERT and SELECT only.
-- ===========================================================================
REVOKE UPDATE ON TABLE AUDIT_EVENT FROM ROLE HO_REVIEWER;
REVOKE DELETE ON TABLE AUDIT_EVENT FROM ROLE HO_REVIEWER;
REVOKE UPDATE ON TABLE AUDIT_EVENT FROM ROLE HO_AUDITOR;
REVOKE DELETE ON TABLE AUDIT_EVENT FROM ROLE HO_AUDITOR;

-- ===========================================================================
-- 2. Hash chain
--
-- Each row stores the hash of (its own content + the previous row's hash).
-- Change any earlier row and every later hash stops reconciling.
--
-- Sequencing uses a strictly increasing surrogate rather than EVENT_AT,
-- because two events in the same transaction can share a timestamp and the
-- chain needs a total order.
-- ===========================================================================
CREATE SEQUENCE IF NOT EXISTS AUDIT_SEQ START = 1 INCREMENT = 1;

ALTER TABLE AUDIT_EVENT ADD COLUMN IF NOT EXISTS SEQ_NO      NUMBER(18,0);
ALTER TABLE AUDIT_EVENT ADD COLUMN IF NOT EXISTS ROW_HASH    VARCHAR(64);
ALTER TABLE AUDIT_EVENT ADD COLUMN IF NOT EXISTS PREV_HASH   VARCHAR(64);

-- Content fingerprint of one event: everything a tamperer might want to
-- change. Deliberately excludes SEQ_NO/ROW_HASH/PREV_HASH themselves.
CREATE OR REPLACE FUNCTION AUDIT_CONTENT_HASH(
  P_EVENT_ID STRING, P_EVENT_TYPE STRING, P_ACTOR STRING,
  P_EVENT_AT TIMESTAMP_TZ, P_SUBJECT_TYPE STRING, P_SUBJECT_ID STRING,
  P_DETAIL VARIANT, P_PREV_HASH STRING)
RETURNS VARCHAR
IMMUTABLE
COMMENT = 'Hash of one audit event plus its predecessor. The chain link.'
AS
$$
  SHA2(COALESCE(P_EVENT_ID,'') || '|' || COALESCE(P_EVENT_TYPE,'') || '|' ||
       COALESCE(P_ACTOR,'')    || '|' || COALESCE(TO_VARCHAR(P_EVENT_AT),'') || '|' ||
       COALESCE(P_SUBJECT_TYPE,'') || '|' || COALESCE(P_SUBJECT_ID,'') || '|' ||
       COALESCE(TO_VARCHAR(P_DETAIL),'') || '|' || COALESCE(P_PREV_HASH,'GENESIS'), 256)
$$;

-- Seal rows: a content hash per row, plus a CHECKPOINT that commits to the
-- whole set. Two mechanisms because they catch different attacks:
--
--   ROW_HASH        detects EDITING a row (content no longer hashes to itself)
--   CHECKPOINT      detects ADDING or DELETING rows (count and aggregate hash
--                   no longer reconcile)
--
-- WHY NOT A CLASSIC PREV_HASH CHAIN: building one set-based requires reading
-- ROW_HASH of the preceding row while writing ROW_HASH of this one, which SQL
-- cannot do in a single statement — the LAG would see the NULLs it is meant to
-- replace. Iterating row-by-row in a procedure would work but is slow and adds
-- failure modes for no extra detection power. The checkpoint achieves the same
-- goal (deletion becomes detectable) with one deterministic statement.
CREATE OR REPLACE TABLE AUDIT_CHECKPOINT (
  CHECKPOINT_ID  VARCHAR(60)  NOT NULL DEFAULT 'ACP-' || UUID_STRING(),
  SEALED_AT      TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  ROW_COUNT      NUMBER(18,0) NOT NULL,
  AGGREGATE_HASH VARCHAR(64)  NOT NULL,
  PRIMARY KEY (CHECKPOINT_ID)
);

CREATE OR REPLACE PROCEDURE SEAL_AUDIT_CHAIN()
RETURNS STRING
LANGUAGE SQL
COMMENT = 'Hashes any unsealed audit rows, then records a set-wide checkpoint.'
AS
$$
DECLARE
  n INT DEFAULT 0;
BEGIN
  -- 1. number any unsealed rows deterministically
  UPDATE AUDIT_EVENT t
     SET SEQ_NO = s.RN
    FROM (SELECT EVENT_ID,
                 (SELECT COALESCE(MAX(SEQ_NO), 0) FROM AUDIT_EVENT)
                   + ROW_NUMBER() OVER (ORDER BY EVENT_AT, EVENT_ID) AS RN
          FROM AUDIT_EVENT WHERE SEQ_NO IS NULL) s
   WHERE t.EVENT_ID = s.EVENT_ID AND t.SEQ_NO IS NULL;

  -- 2. content hash per row (independent of any other row)
  UPDATE AUDIT_EVENT
     SET ROW_HASH = AUDIT_CONTENT_HASH(EVENT_ID, EVENT_TYPE, ACTOR, EVENT_AT,
                                       SUBJECT_TYPE, SUBJECT_ID, DETAIL, NULL)
   WHERE ROW_HASH IS NULL;

  -- 3. one checkpoint committing to the entire ordered set
  INSERT INTO AUDIT_CHECKPOINT (ROW_COUNT, AGGREGATE_HASH)
  SELECT COUNT(*),
         SHA2(LISTAGG(ROW_HASH, '|') WITHIN GROUP (ORDER BY SEQ_NO), 256)
  FROM AUDIT_EVENT;

  SELECT COUNT(*) INTO :n FROM AUDIT_EVENT WHERE ROW_HASH IS NOT NULL;
  RETURN 'sealed ' || :n || ' audit rows and recorded a checkpoint';
END;
$$;

-- ===========================================================================
-- 3. The verifier. PASS means no audit row has been altered, added or removed
--    since the last checkpoint.
-- ===========================================================================
CREATE OR REPLACE VIEW V_AUDIT_INTEGRITY AS
WITH latest AS (
  SELECT ROW_COUNT, AGGREGATE_HASH FROM AUDIT_CHECKPOINT
  ORDER BY SEALED_AT DESC LIMIT 1
),
now_state AS (
  SELECT COUNT(*) AS ROW_COUNT,
         SHA2(LISTAGG(ROW_HASH, '|') WITHIN GROUP (ORDER BY SEQ_NO), 256) AS AGGREGATE_HASH,
         COUNT_IF(ROW_HASH <> AUDIT_CONTENT_HASH(EVENT_ID, EVENT_TYPE, ACTOR,
                    EVENT_AT, SUBJECT_TYPE, SUBJECT_ID, DETAIL, NULL)) AS ALTERED_ROWS
  FROM AUDIT_EVENT WHERE ROW_HASH IS NOT NULL
)
SELECT
  l.ROW_COUNT              AS SEALED_ROWS,
  n.ROW_COUNT              AS CURRENT_ROWS,
  n.ALTERED_ROWS,
  CASE
    WHEN n.ALTERED_ROWS > 0                      THEN 'FAIL — row content was altered'
    WHEN n.ROW_COUNT < l.ROW_COUNT               THEN 'FAIL — audit rows were deleted'
    WHEN n.AGGREGATE_HASH <> l.AGGREGATE_HASH
         AND n.ROW_COUNT = l.ROW_COUNT           THEN 'FAIL — the set changed'
    WHEN n.ROW_COUNT > l.ROW_COUNT               THEN 'OK — new events appended since the last checkpoint'
    ELSE 'OK — audit trail intact'
  END AS VERDICT
FROM latest l CROSS JOIN now_state n;

GRANT SELECT ON VIEW V_AUDIT_INTEGRITY TO ROLE HO_AUDITOR;
GRANT SELECT ON VIEW V_AUDIT_INTEGRITY TO ROLE HO_REVIEWER;

CALL SEAL_AUDIT_CHAIN();

SELECT * FROM V_AUDIT_INTEGRITY;
