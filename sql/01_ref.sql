-- STATUS: EXECUTED 2026-08-21 via `snow sql -f`. Assertions A-01/A-02 passed.
-- Built against docs/self-tracking/03_SCHEMA_DESIGN.md §5 (authoritative spec).
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE SCHEMA CONF; USE WAREHOUSE HO_WH;

-- ============================================================================
-- DATE_ANCHOR — the definition of "today" for the whole product (§5.1).
-- Exactly one row, forever. Every date computation in P360/RULES/CASES reads
-- this instead of CURRENT_DATE: keeps dynamic tables deterministic (CURRENT_
-- DATE disqualifies incremental refresh) and keeps the demo from going stale.
-- ============================================================================
CREATE OR REPLACE TABLE DATE_ANCHOR (
  AS_OF   DATE NOT NULL,
  SET_BY  VARCHAR(60) NOT NULL,
  SET_AT  TIMESTAMP_TZ NOT NULL,
  NOTE    VARCHAR(500)
);
INSERT INTO DATE_ANCHOR (AS_OF, SET_BY, SET_AT, NOTE) VALUES
  (DATE '2026-09-01', 'aman', CURRENT_TIMESTAMP(),
   'Fixed demo/detection anchor. Never CURRENT_DATE. Assertion A-01 checks exactly one row.');

-- ============================================================================
-- REF_DRUG — invented drug names, deliberately (§5.2). A real name here would
-- mean misquoting real safety guidance.
-- ============================================================================
CREATE OR REPLACE TABLE REF_DRUG (
  DRUG_ID       VARCHAR(40)  NOT NULL,
  DRUG_NAME     VARCHAR(120) NOT NULL,
  DRUG_CLASS    VARCHAR(120),
  IS_SYNTHETIC  BOOLEAN NOT NULL DEFAULT TRUE,
  PRIMARY KEY (DRUG_ID)
);
INSERT INTO REF_DRUG (DRUG_ID, DRUG_NAME, DRUG_CLASS) VALUES
  ('DRG-CARDIOZEN', 'CardioZen', 'antiarrhythmic (synthetic)'),
  ('DRG-RENUVEX',   'Renuvex',   'renally-cleared agent (synthetic)'),
  ('DRG-HEPATROL',  'Hepatrol',  'hepatically-metabolized agent (synthetic)');

-- ============================================================================
-- REF_CONDITION
-- ============================================================================
CREATE OR REPLACE TABLE REF_CONDITION (
  CONDITION_ID    VARCHAR(40)  NOT NULL,
  CONDITION_NAME  VARCHAR(120) NOT NULL,
  DESCRIPTION     VARCHAR(500),
  PRIMARY KEY (CONDITION_ID)
);
INSERT INTO REF_CONDITION (CONDITION_ID, CONDITION_NAME, DESCRIPTION) VALUES
  ('CND-CKD',         'chronic kidney disease', 'long-term reduced kidney function'),
  ('CND-HYPOTHYROID', 'hypothyroidism',         'underactive thyroid gland'),
  ('CND-CLD',         'chronic liver disease',  'long-term liver condition');

-- ============================================================================
-- REF_LAB_TEST
-- ============================================================================
CREATE OR REPLACE TABLE REF_LAB_TEST (
  LAB_TEST_ID       VARCHAR(40)  NOT NULL,
  CANONICAL_NAME    VARCHAR(120) NOT NULL,
  LOINC_LIKE_CODE   VARCHAR(40),
  UNITS             VARCHAR(20)  NOT NULL,
  PRIMARY KEY (LAB_TEST_ID)
);
INSERT INTO REF_LAB_TEST (LAB_TEST_ID, CANONICAL_NAME, LOINC_LIKE_CODE, UNITS) VALUES
  ('LAB-K',      'serum potassium',   'SYN-2823', 'mmol/L'),
  ('LAB-TSH',    'TSH',               'SYN-3016', 'mIU/L'),
  ('LAB-ALT',    'ALT',               'SYN-1742', 'U/L'),
  ('LAB-CREAT',  'serum creatinine',  'SYN-2160', 'mg/dL');

-- ============================================================================
-- REF_LAB_TEST_SYNONYM — matching is LOWER(TRIM(raw_test_text)) = SYNONYM_TEXT.
--
-- DELIBERATE GAP — DO NOT ADD 'k+ serum level'. Its absence is the entire
-- P1131/GP3 mechanism (docs/04 GP3, 03_SCHEMA_DESIGN §5.5): the result exists
-- in the raw lab feed under a spelling nobody mapped, the vocabulary join
-- misses it, a monitoring-gap case fires for a patient who WAS tested, and
-- the reviewer dismisses it with a reason. Assertion A-02 fails the build if
-- this row is ever added.
-- ============================================================================
CREATE OR REPLACE TABLE REF_LAB_TEST_SYNONYM (
  SYNONYM_TEXT  VARCHAR(160) NOT NULL,
  LAB_TEST_ID   VARCHAR(40)  NOT NULL,
  PRIMARY KEY (SYNONYM_TEXT),
  FOREIGN KEY (LAB_TEST_ID) REFERENCES REF_LAB_TEST(LAB_TEST_ID)
);
INSERT INTO REF_LAB_TEST_SYNONYM (SYNONYM_TEXT, LAB_TEST_ID) VALUES
  ('serum potassium',                'LAB-K'),
  ('potassium, serum',               'LAB-K'),
  ('potassium',                      'LAB-K'),
  ('tsh',                            'LAB-TSH'),
  ('thyroid stimulating hormone',    'LAB-TSH'),
  ('alt',                            'LAB-ALT'),
  ('alanine aminotransferase',       'LAB-ALT'),
  ('serum creatinine',               'LAB-CREAT'),
  ('creatinine',                     'LAB-CREAT');

-- ============================================================================
-- Sanity queries (read-only; run these, not just the CREATEs)
-- ============================================================================
-- SELECT COUNT(*) AS anchor_rows FROM DATE_ANCHOR;                    -- expect 1
-- SELECT * FROM DATE_ANCHOR;
-- SELECT COUNT(*) FROM REF_LAB_TEST_SYNONYM WHERE LOWER(SYNONYM_TEXT) = 'k+ serum level'; -- expect 0
