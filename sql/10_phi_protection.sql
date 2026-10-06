-- STATUS: EXECUTED 2026-08-30 against account KUMZGAJ-OO64644 (locator PF13333,
-- AWS_US_EAST_2) via ./tools/sfx. Ran clean. Covered by the suites in
--  tests/.
-- PHI PROTECTION: pseudonymisation, break-glass reveal, row-level scoping.
--
-- WHY THIS EXISTS
-- Until now the app showed every reviewer a full patient name, both source
-- system ids and a date of birth, on the first screen. In a medication-safety
-- workflow that fails the "minimum necessary" principle: a reviewer deciding
-- whether a potassium test is overdue does not need to know who the patient
-- is. Identity matters at exactly one moment — escalation, when the case must
-- be routed to a treating clinician.
--
-- THE DESIGN (5 layers, defence in depth)
--   1. Display token       a stable pseudonym replaces the identifiers
--   2. Data-layer masking  NAME/DOB masked by policy, not by the UI
--   3. Break-glass         just-in-time, reason-coded, time-limited reveal
--   4. Audit               every reveal is an immutable event
--   5. Row scoping         a reviewer sees only their assigned clinics
--
-- Layer 2 is the important one: masking in the UI alone is theatre, because
-- anyone with a SQL client bypasses it. The policy makes the database itself
-- refuse to return the value.
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE WAREHOUSE HO_WH;

CREATE SCHEMA IF NOT EXISTS HEALTHONE.SEC;

-- ===========================================================================
-- LAYER 1 — the display token
--
-- Format: PT-482913****  (what a reviewer sees and quotes to a colleague)
--
-- The digits are derived from a HASH of PERSON_ID, NOT from the real medical
-- record number. That distinction matters: showing the leading digits of a
-- real MRN is itself partial PHI and is re-identifiable in a small
-- population. A derived token gives the same familiar shape while leaking
-- nothing about the real identifier.
--
-- Properties: deterministic (the same person always shows the same token, so
-- a case can be tracked and discussed), non-reversible from inside the app,
-- and checked for collisions by assertion A-14.
--
-- PRODUCTION NOTE, stated plainly: HASH() with an inline salt is adequate for
-- synthetic demo data. A real deployment would use a keyed HMAC with the key
-- in a secrets manager and rotated, so that an account admin reading this SQL
-- could not recompute the mapping.
-- ===========================================================================
CREATE OR REPLACE FUNCTION SEC.PERSON_TOKEN(PERSON_ID STRING)
  RETURNS STRING
  IMMUTABLE
  COMMENT = 'Stable non-identifying display pseudonym. Never derived from the real MRN.'
AS
$$
  'PT-' || LPAD(ABS(HASH(PERSON_ID || '|HO-TOKEN-SALT-v1')) % 1000000, 6, '0') || '****'
$$;

-- ===========================================================================
-- LAYER 3 + 4 — break-glass reveal, with the audit built into the same call
--
-- A reviewer cannot write this table directly (there are no grants on it).
-- The only way a row appears is through SEC.REQUEST_PHI_REVEAL, which runs as
-- owner and writes the audit event in the same procedure. So "revealed but
-- not logged" is not a reachable state — that is the entire point.
-- ===========================================================================
CREATE OR REPLACE TABLE SEC.PHI_REVEAL_GRANT (
  GRANT_ID     VARCHAR(60)  NOT NULL DEFAULT 'PHG-' || UUID_STRING(),
  PERSON_ID    VARCHAR(40)  NOT NULL,
  GRANTED_TO   VARCHAR(120) NOT NULL,   -- CURRENT_USER() at request time
  CASE_ID      VARCHAR(60),
  REASON_CODE  VARCHAR(60)  NOT NULL,
  REASON_TEXT  VARCHAR(1000),
  GRANTED_AT   TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  EXPIRES_AT   TIMESTAMP_TZ NOT NULL,
  PRIMARY KEY (GRANT_ID)
);

-- Controlled reason codes. Free text alone would make the audit trail
-- unanalysable — you could never ask "how often do we reveal, and why".
CREATE OR REPLACE TABLE SEC.PHI_REVEAL_REASON (
  REASON_CODE VARCHAR(60)  NOT NULL,
  DESCRIPTION VARCHAR(300) NOT NULL,
  PRIMARY KEY (REASON_CODE)
);
INSERT INTO SEC.PHI_REVEAL_REASON (REASON_CODE, DESCRIPTION) VALUES
  ('ESCALATE_TO_CLINICIAN', 'Routing this case to the treating clinician'),
  ('CONFIRM_PATIENT',       'Confirming this is the correct patient before acting'),
  ('DATA_QUALITY',          'Investigating a suspected data-quality problem'),
  ('PATIENT_ENQUIRY',       'Responding to a direct enquiry about this patient');

CREATE OR REPLACE PROCEDURE SEC.REQUEST_PHI_REVEAL(
  P_PERSON_ID   STRING,
  P_CASE_ID     STRING,
  P_REASON_CODE STRING,
  P_REASON_TEXT STRING)
RETURNS STRING
LANGUAGE SQL
COMMENT = 'Break-glass: grants a 30-minute PHI reveal and logs it inseparably.'
EXECUTE AS OWNER
AS
$$
DECLARE
  reason_ok INT;
BEGIN
  SELECT COUNT(*) INTO :reason_ok
    FROM SEC.PHI_REVEAL_REASON WHERE REASON_CODE = :P_REASON_CODE;
  IF (reason_ok = 0) THEN
    RETURN 'REJECTED: unknown reason code';
  END IF;

  INSERT INTO SEC.PHI_REVEAL_GRANT
    (PERSON_ID, GRANTED_TO, CASE_ID, REASON_CODE, REASON_TEXT, EXPIRES_AT)
  SELECT :P_PERSON_ID, CURRENT_USER(), :P_CASE_ID, :P_REASON_CODE, :P_REASON_TEXT,
         DATEADD('minute', 30, CURRENT_TIMESTAMP());

  INSERT INTO CASES.AUDIT_EVENT (EVENT_TYPE, ACTOR, SUBJECT_TYPE, SUBJECT_ID, DETAIL)
  SELECT 'PHI_REVEALED', CURRENT_USER(), 'PERSON', :P_PERSON_ID,
         OBJECT_CONSTRUCT('case_id', :P_CASE_ID, 'reason_code', :P_REASON_CODE,
                          'reason_text', :P_REASON_TEXT, 'window_minutes', 30);

  RETURN 'GRANTED for 30 minutes — this access has been recorded in the audit trail';
END;
$$;

-- ===========================================================================
-- LAYER 2 — masking enforced by the database
--
-- Conditional masking: each policy receives the row's PERSON_ID as a second
-- argument so it can check for a reveal grant for THAT specific patient.
-- Without the second argument, one reveal would unmask the entire cohort.
--
-- NO ROLE IS EXEMPT — not even HO_ADMIN, the role that builds the platform.
-- An earlier draft exempted it "because it loads the data", which was wrong
-- twice over: nothing in the load path reads P360_PERSON (the loader writes
-- RAW, and the reconciler uses drug/condition/test vocabulary names, never
-- patient names), and an exemption for the most privileged role is precisely
-- the exemption an auditor asks about. The only way to see a name is to break
-- glass, and breaking glass is always logged — a much stronger claim: the
-- platform administrator cannot read a patient name without leaving a record.
-- ===========================================================================
-- ASCII ONLY, deliberately. These strings reach the user through a
-- Snowsight iframe, and a U+2022 BULLET here rendered as
-- "PT-579488a-oa-o" in the deployed app. Asterisks are not a stylistic
-- choice; they are the only thing that survives every renderer in the
-- path intact.
CREATE MASKING POLICY IF NOT EXISTS SEC.MASK_PHI_NAME AS (v STRING, pid STRING)
  RETURNS STRING -> '*** NAME WITHHELD ***';
ALTER MASKING POLICY SEC.MASK_PHI_NAME SET BODY ->
  CASE
    WHEN EXISTS (
      SELECT 1 FROM SEC.PHI_REVEAL_GRANT g
      WHERE g.PERSON_ID = pid
        AND g.GRANTED_TO = CURRENT_USER()
        AND g.EXPIRES_AT > CURRENT_TIMESTAMP()
    ) THEN v
    ELSE '*** NAME WITHHELD ***'
  END;

CREATE MASKING POLICY IF NOT EXISTS SEC.MASK_PHI_DOB AS (v DATE, pid STRING)
  RETURNS DATE -> DATE '1900-01-01';
ALTER MASKING POLICY SEC.MASK_PHI_DOB SET BODY ->
  CASE
    WHEN EXISTS (
      SELECT 1 FROM SEC.PHI_REVEAL_GRANT g
      WHERE g.PERSON_ID = pid
        AND g.GRANTED_TO = CURRENT_USER()
        AND g.EXPIRES_AT > CURRENT_TIMESTAMP()
    ) THEN v
    ELSE DATE '1900-01-01'
  END;

-- Source-system identifiers are themselves identifying, so they are masked to
-- their shape rather than their value: 'P1024' -> 'P****'. The reviewer can
-- still see that a hospital id exists and is distinct from the plan id, which
-- is all the workflow needs.
CREATE MASKING POLICY IF NOT EXISTS SEC.MASK_SOURCE_ID AS (v STRING, pid STRING)
  RETURNS STRING -> LEFT(v, 1) || '****';
ALTER MASKING POLICY SEC.MASK_SOURCE_ID SET BODY ->
  CASE
    WHEN EXISTS (
      SELECT 1 FROM SEC.PHI_REVEAL_GRANT g
      WHERE g.PERSON_ID = pid
        AND g.GRANTED_TO = CURRENT_USER()
        AND g.EXPIRES_AT > CURRENT_TIMESTAMP()
    ) THEN v
    ELSE LEFT(v, 1) || '****'
  END;

-- ===========================================================================
-- LAYER 5 — row scoping. A reviewer sees only their assigned clinics.
--
-- NOTE on a real Snowflake constraint: a column may appear in a masking
-- policy signature OR a row access policy signature, never both. NAME, DOB,
-- PATIENT_ID, MEMBER_ID and PERSON_ID are all used by the masking policies
-- above, so the row policy keys on PRIMARY_CLINIC instead.
-- ===========================================================================
CREATE OR REPLACE TABLE SEC.REVIEWER_ASSIGNMENT (
  USER_NAME      VARCHAR(120) NOT NULL,
  PRIMARY_CLINIC VARCHAR(80)  NOT NULL,
  ASSIGNED_AT    TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);
-- AMAN is the build/service account and is intentionally assigned every
-- clinic, so the golden tests keep seeing the whole cohort. A real reviewer
-- would hold one or two.
INSERT INTO SEC.REVIEWER_ASSIGNMENT (USER_NAME, PRIMARY_CLINIC)
SELECT 'AMAN', c.CLINIC FROM (
  SELECT 'Northgate Clinic' AS CLINIC UNION ALL
  SELECT 'Riverside Clinic' UNION ALL
  SELECT 'Eastfield Clinic') c;

-- Same attachment constraint as the masking policies: a policy in use cannot
-- be replaced, so create-if-absent then ALTER SET BODY.
CREATE ROW ACCESS POLICY IF NOT EXISTS SEC.CLINIC_SCOPE AS (clinic VARCHAR)
  RETURNS BOOLEAN -> FALSE;
ALTER ROW ACCESS POLICY SEC.CLINIC_SCOPE SET BODY ->
  EXISTS (
    SELECT 1 FROM SEC.REVIEWER_ASSIGNMENT a
    WHERE a.USER_NAME = CURRENT_USER()
      AND a.PRIMARY_CLINIC = clinic
  );

-- ===========================================================================
-- Grants — the reviewer can break glass and can read nothing else in SEC.
-- Critically: NO grants on PHI_REVEAL_GRANT for HO_REVIEWER. The only way a
-- grant row is created is via the procedure, which also writes the audit row.
-- ===========================================================================
GRANT USAGE ON SCHEMA SEC TO ROLE HO_REVIEWER;
GRANT USAGE ON FUNCTION SEC.PERSON_TOKEN(STRING) TO ROLE HO_REVIEWER;
GRANT USAGE ON PROCEDURE SEC.REQUEST_PHI_REVEAL(STRING, STRING, STRING, STRING) TO ROLE HO_REVIEWER;
GRANT SELECT ON TABLE SEC.PHI_REVEAL_REASON TO ROLE HO_REVIEWER;

GRANT USAGE ON SCHEMA SEC TO ROLE HO_AUDITOR;
GRANT SELECT ON TABLE SEC.PHI_REVEAL_GRANT TO ROLE HO_AUDITOR;   -- auditor sees who revealed what
GRANT SELECT ON TABLE SEC.REVIEWER_ASSIGNMENT TO ROLE HO_AUDITOR;

-- ===========================================================================
-- ATTACH THE POLICIES. Without this section everything above is decoration.
--
-- This was the single most serious defect in the build, and it was invisible
-- for nine days. sql/10 created MASK_PHI_NAME and MASK_PHI_DOB and never
-- attached them to a column. P360_PERSON.NAME and .DOB still carried
-- CONF.MASK_PERSON_NAME from sql/04, whose body is
--
--     CASE WHEN CURRENT_ROLE() IN ('HO_ADMIN','HO_REVIEWER') THEN v ...
--
-- so the two roles that actually use the app saw every patient name and date
-- of birth in clear, while the documentation and the app both described
-- break-glass protection. Assertion A-15 is what caught it, on the first
-- account ever built purely from these files.
--
-- FORCE is required: it replaces the existing policy on the column instead of
-- failing with "column already has a masking policy". USING names the second
-- argument the conditional policy needs -- the person id it decides on.
--
-- Order matters. These must run AFTER P360_PERSON exists (sql/04) and after
-- SEC.PHI_REVEAL_GRANT exists, which is why they live at the end of this file
-- rather than next to the policy definitions.
-- ===========================================================================
ALTER TABLE P360.P360_PERSON MODIFY COLUMN NAME
  SET MASKING POLICY SEC.MASK_PHI_NAME USING (NAME, PERSON_ID) FORCE;
ALTER TABLE P360.P360_PERSON MODIFY COLUMN DOB
  SET MASKING POLICY SEC.MASK_PHI_DOB  USING (DOB, PERSON_ID) FORCE;

-- Source-system identifiers are identifying on their own, so they are masked
-- to their shape: 'P1024' -> 'P****'. A reviewer can still tell two patients
-- apart and still see that a record exists in both systems.
ALTER TABLE P360.P360_PERSON MODIFY COLUMN PATIENT_ID
  SET MASKING POLICY SEC.MASK_SOURCE_ID USING (PATIENT_ID, PERSON_ID) FORCE;
ALTER TABLE P360.P360_PERSON MODIFY COLUMN MEMBER_ID
  SET MASKING POLICY SEC.MASK_SOURCE_ID USING (MEMBER_ID, PERSON_ID) FORCE;

-- Prove it here rather than trusting it. Runs as whatever role deployed this:
-- if that role can read a name with no live grant, this returns FAIL and the
-- build should stop.
SELECT 'PHI masking attached and enforced for the deploying role' AS check_name,
       IFF(NOT EXISTS (
             SELECT 1 FROM P360.P360_PERSON p
             WHERE NOT EXISTS (SELECT 1 FROM SEC.PHI_REVEAL_GRANT g
                                WHERE g.PERSON_ID = p.PERSON_ID
                                  AND g.EXPIRES_AT > CURRENT_TIMESTAMP())
               AND (p.NAME NOT LIKE '%WITHHELD%' OR p.DOB <> DATE '1900-01-01')),
           'PASS', 'FAIL') AS result;
