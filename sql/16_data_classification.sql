-- STATUS: EXECUTED 2026-08-30 against account KUMZGAJ-OO64644 (locator PF13333,
-- AWS_US_EAST_2) via ./tools/sfx. Ran clean. Covered by the suites in
--  tests/.
-- DATA CLASSIFICATION with Snowflake object tags, plus tag-based masking.
--
-- WHY TAGS RATHER THAN MORE HAND-ATTACHED POLICIES
-- sql/10 attaches masking policies column by column. That works, and it is
-- what you want for the per-person break-glass logic. But it does not scale
-- and it does not answer the question a compliance reviewer actually asks:
-- "show me every column in this database that holds patient data, and prove
-- each one is protected." Column-by-column attachment cannot answer that
-- without someone reading all the DDL.
--
-- A tag is a first-class object. Classify a column once, and:
--   * it becomes discoverable   — one query lists all PHI in the account
--   * protection can follow the tag rather than the column
--   * new columns inherit protection by being classified, not by remembering
--
-- THE ONE PLACE THIS IS DANGEROUS, AND HOW IT IS HANDLED
-- P360_PERSON is a MATERIALIZED dynamic table. Its refresh runs as the table
-- owner and writes real values into storage. If the RAW columns it reads were
-- masked, the refresh would materialise MASKED values, and break-glass could
-- never recover the real name — it would be gone from the 360 entirely.
-- So RAW_EHR_PATIENT.NAME/DOB are CLASSIFIED but NOT policy-masked; their
-- enforcement lives downstream on P360_PERSON where break-glass can lift it.
-- RAW_PLAN_MEMBER.NAME/DOB are not in any dynamic table's lineage (only
-- PLAN_CODE is read), so those DO carry tag-based masking — which is where
-- the mechanism is demonstrated without breaking the product.
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE WAREHOUSE HO_WH;

-- ===========================================================================
-- 1. The classification vocabulary
-- ===========================================================================
CREATE TAG IF NOT EXISTS SEC.DATA_SENSITIVITY
  ALLOWED_VALUES 'PHI', 'PII', 'QUASI_IDENTIFIER', 'CLINICAL', 'INTERNAL'
  COMMENT = 'Data classification. PHI directly identifies a patient. QUASI_IDENTIFIER is re-identifying in combination (DOB, clinic, sex). CLINICAL is medical content, not identifying on its own.';

CREATE TAG IF NOT EXISTS SEC.SOURCE_SYSTEM_TAG
  ALLOWED_VALUES 'EHR', 'PHARMACY', 'CLAIMS', 'LAB', 'DOCUMENT', 'DERIVED'
  COMMENT = 'Which source system a column originates from. Provenance as metadata.';

-- ===========================================================================
-- 2. Classify. Direct identifiers first.
-- ===========================================================================
ALTER TABLE RAW.RAW_EHR_PATIENT MODIFY COLUMN NAME
  SET TAG SEC.DATA_SENSITIVITY = 'PHI', SEC.SOURCE_SYSTEM_TAG = 'EHR';
ALTER TABLE RAW.RAW_EHR_PATIENT MODIFY COLUMN PATIENT_ID
  SET TAG SEC.DATA_SENSITIVITY = 'PHI', SEC.SOURCE_SYSTEM_TAG = 'EHR';
ALTER TABLE RAW.RAW_EHR_PATIENT MODIFY COLUMN DOB
  SET TAG SEC.DATA_SENSITIVITY = 'QUASI_IDENTIFIER', SEC.SOURCE_SYSTEM_TAG = 'EHR';
ALTER TABLE RAW.RAW_EHR_PATIENT MODIFY COLUMN PRIMARY_CLINIC
  SET TAG SEC.DATA_SENSITIVITY = 'QUASI_IDENTIFIER', SEC.SOURCE_SYSTEM_TAG = 'EHR';

ALTER TABLE RAW.RAW_PLAN_MEMBER MODIFY COLUMN NAME
  SET TAG SEC.DATA_SENSITIVITY = 'PHI', SEC.SOURCE_SYSTEM_TAG = 'CLAIMS';
ALTER TABLE RAW.RAW_PLAN_MEMBER MODIFY COLUMN MEMBER_ID
  SET TAG SEC.DATA_SENSITIVITY = 'PHI', SEC.SOURCE_SYSTEM_TAG = 'CLAIMS';
ALTER TABLE RAW.RAW_PLAN_MEMBER MODIFY COLUMN DOB
  SET TAG SEC.DATA_SENSITIVITY = 'QUASI_IDENTIFIER', SEC.SOURCE_SYSTEM_TAG = 'CLAIMS';

-- The crosswalk is the re-identification key: it is the single object that
-- links a pseudonym back to two real-world identifiers. Classified as such.
ALTER TABLE CONF.CONF_PERSON_XWALK MODIFY COLUMN PATIENT_ID
  SET TAG SEC.DATA_SENSITIVITY = 'PHI', SEC.SOURCE_SYSTEM_TAG = 'DERIVED';
ALTER TABLE CONF.CONF_PERSON_XWALK MODIFY COLUMN MEMBER_ID
  SET TAG SEC.DATA_SENSITIVITY = 'PHI', SEC.SOURCE_SYSTEM_TAG = 'DERIVED';

-- Clinical content: medical, but not identifying on its own.
ALTER TABLE CONF.CONF_LAB_RESULT MODIFY COLUMN RESULT_VALUE
  SET TAG SEC.DATA_SENSITIVITY = 'CLINICAL', SEC.SOURCE_SYSTEM_TAG = 'LAB';
ALTER TABLE CONF.CONF_CLINICAL_NOTE MODIFY COLUMN NOTE_TEXT
  SET TAG SEC.DATA_SENSITIVITY = 'CLINICAL', SEC.SOURCE_SYSTEM_TAG = 'EHR';

-- The 360 columns that are already policy-protected (sql/10). Classifying
-- them too means the inventory in §4 shows protection AND classification
-- agreeing, rather than one without the other.
ALTER TABLE P360.P360_PERSON MODIFY COLUMN NAME
  SET TAG SEC.DATA_SENSITIVITY = 'PHI', SEC.SOURCE_SYSTEM_TAG = 'DERIVED';
ALTER TABLE P360.P360_PERSON MODIFY COLUMN DOB
  SET TAG SEC.DATA_SENSITIVITY = 'QUASI_IDENTIFIER', SEC.SOURCE_SYSTEM_TAG = 'DERIVED';
ALTER TABLE P360.P360_PERSON MODIFY COLUMN PATIENT_ID
  SET TAG SEC.DATA_SENSITIVITY = 'PHI', SEC.SOURCE_SYSTEM_TAG = 'DERIVED';
ALTER TABLE P360.P360_PERSON MODIFY COLUMN MEMBER_ID
  SET TAG SEC.DATA_SENSITIVITY = 'PHI', SEC.SOURCE_SYSTEM_TAG = 'DERIVED';

-- ===========================================================================
-- 3. Tag-based masking — protection that follows the CLASSIFICATION.
--
-- Single-argument policies, because tag-based assignment cannot pass a second
-- column (the per-person conditional policies in sql/10 stay attached
-- directly to P360_PERSON, where break-glass needs the row's PERSON_ID).
--
-- Applied to the payer-side name/DOB, which no dynamic table reads — see the
-- lineage warning in this file's header for why that restriction matters.
-- ===========================================================================
CREATE MASKING POLICY IF NOT EXISTS SEC.TAG_MASK_STRING AS (v STRING)
  RETURNS STRING -> '*** CLASSIFIED ***';
ALTER MASKING POLICY SEC.TAG_MASK_STRING SET BODY ->
  CASE WHEN CURRENT_ROLE() = 'HO_ADMIN' THEN v
       ELSE '*** ' || CURRENT_ROLE() || ' NOT CLEARED ***' END;

CREATE MASKING POLICY IF NOT EXISTS SEC.TAG_MASK_DATE AS (v DATE)
  RETURNS DATE -> DATE '1900-01-01';
ALTER MASKING POLICY SEC.TAG_MASK_DATE SET BODY ->
  CASE WHEN CURRENT_ROLE() = 'HO_ADMIN' THEN v ELSE DATE '1900-01-01' END;

-- One policy per data type may be bound to a tag. Binding here means every
-- column ever tagged 'PII' inherits protection automatically — including
-- columns that do not exist yet.
CREATE TAG IF NOT EXISTS SEC.PAYER_IDENTIFIER
  COMMENT = 'Payer-side identifiers. Carries tag-based masking; safe to bind because no dynamic table reads these columns.';

-- WAS BLOCKED until 2026-08-30, now UNBLOCKED. Binding a policy to a TAG is an
-- account-level operation needing a privilege HO_ADMIN did not hold on the old
-- trial account - even though HO_ADMIN could attach the same policy directly to
-- a column it owns (which is what sql/10 does). On the new account
-- sql/26 grants it:
--   GRANT APPLY MASKING POLICY ON ACCOUNT TO ROLE HO_ADMIN;
-- so the four statements below are live.
--
-- WHY THIS TAG AND NOT DATA_SENSITIVITY. A masking policy bound to a tag
-- applies to every column carrying it, and DATA_SENSITIVITY is on columns that
-- the P360 dynamic tables read. Masking an input to a dynamic table changes
-- what that table computes. PAYER_IDENTIFIER was created precisely because
-- nothing downstream reads those columns, so binding here is safe.
--
--   Attempted : ALTER TAG SEC.PAYER_IDENTIFIER SET MASKING POLICY ...
--   Result    : "Insufficient privileges to operate on tag 'PAYER_IDENTIFIER'.
--                Your primary role HO_ADMIN ... must have APPLY MASKING POLICY
--                granted on ACCOUNT HF31719."
--
-- Column-level enforcement (sql/10) is unaffected and already working, so this
-- is an improvement in how protection is ADMINISTERED, not a gap in whether
-- patient data is protected.
ALTER TAG SEC.PAYER_IDENTIFIER SET MASKING POLICY SEC.TAG_MASK_STRING;
ALTER TAG SEC.PAYER_IDENTIFIER SET MASKING POLICY SEC.TAG_MASK_DATE;
ALTER TABLE RAW.RAW_PLAN_MEMBER MODIFY COLUMN NAME SET TAG SEC.PAYER_IDENTIFIER = 'name';
ALTER TABLE RAW.RAW_PLAN_MEMBER MODIFY COLUMN DOB  SET TAG SEC.PAYER_IDENTIFIER = 'dob';

-- ===========================================================================
-- 4. The compliance artifact: one query answering "where is the patient data,
--    and is it protected?" This is the thing column-by-column DDL cannot give
--    you, and the reason tags are worth having.
-- ===========================================================================
CREATE OR REPLACE VIEW SEC.V_PHI_INVENTORY
COMMENT = 'Compliance answer to: where is the patient data, and is it protected?'
AS
WITH tagged AS (
  -- INFORMATION_SCHEMA.TAG_REFERENCES works one object at a time, and
  -- SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES (which would cover the account in
  -- one query) is not granted to HO_ADMIN. So the objects are enumerated
  -- explicitly. Honest and functional; it would collapse to one row of SQL
  -- with ACCOUNT_USAGE access.
  SELECT 'RAW'  AS SCH, 'RAW_EHR_PATIENT'   AS TBL, COLUMN_NAME AS COL, TAG_NAME, TAG_VALUE
    FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('HEALTHONE.RAW.RAW_EHR_PATIENT','TABLE'))
  UNION ALL SELECT 'RAW','RAW_PLAN_MEMBER', COLUMN_NAME, TAG_NAME, TAG_VALUE
    FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('HEALTHONE.RAW.RAW_PLAN_MEMBER','TABLE'))
  UNION ALL SELECT 'CONF','CONF_PERSON_XWALK', COLUMN_NAME, TAG_NAME, TAG_VALUE
    FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('HEALTHONE.CONF.CONF_PERSON_XWALK','TABLE'))
  UNION ALL SELECT 'CONF','CONF_LAB_RESULT', COLUMN_NAME, TAG_NAME, TAG_VALUE
    FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('HEALTHONE.CONF.CONF_LAB_RESULT','TABLE'))
  UNION ALL SELECT 'CONF','CONF_CLINICAL_NOTE', COLUMN_NAME, TAG_NAME, TAG_VALUE
    FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('HEALTHONE.CONF.CONF_CLINICAL_NOTE','TABLE'))
  UNION ALL SELECT 'P360','P360_PERSON', COLUMN_NAME, TAG_NAME, TAG_VALUE
    FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS('HEALTHONE.P360.P360_PERSON','TABLE'))
),
protected AS (
  SELECT REF_COLUMN_NAME AS COL, POLICY_NAME
  FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
         REF_ENTITY_NAME=>'HEALTHONE.P360.P360_PERSON', REF_ENTITY_DOMAIN=>'TABLE'))
  WHERE POLICY_KIND = 'MASKING_POLICY'
)
SELECT t.SCH, t.TBL, t.COL,
       MAX(IFF(t.TAG_NAME='DATA_SENSITIVITY',  t.TAG_VALUE, NULL)) AS SENSITIVITY,
       MAX(IFF(t.TAG_NAME='SOURCE_SYSTEM_TAG', t.TAG_VALUE, NULL)) AS SOURCE_SYSTEM,
       MAX(p.POLICY_NAME)                                          AS MASKING_POLICY,
       CASE
         WHEN MAX(p.POLICY_NAME) IS NOT NULL                    THEN 'ENFORCED by policy'
         WHEN t.SCH IN ('RAW','CONF')
              AND MAX(IFF(t.TAG_NAME='DATA_SENSITIVITY', t.TAG_VALUE, NULL))
                  IN ('PHI','QUASI_IDENTIFIER')                 THEN 'CLASSIFIED — restricted to HO_ADMIN by grant'
         ELSE 'CLASSIFIED — non-identifying'
       END AS PROTECTION
FROM tagged t
LEFT JOIN protected p ON p.COL = t.COL AND t.TBL = 'P360_PERSON'
GROUP BY t.SCH, t.TBL, t.COL
ORDER BY SENSITIVITY, t.SCH, t.TBL, t.COL;

GRANT SELECT ON VIEW SEC.V_PHI_INVENTORY TO ROLE HO_AUDITOR;

SHOW TAGS IN SCHEMA SEC;
