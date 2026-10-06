-- STATUS: EXECUTED 2026-08-27 — created and queried successfully.
--
-- A GOVERNED SEMANTIC LAYER over the Patient & Member 360.
--
-- WHY THIS EARNS ITS PLACE
-- Business questions ("how many cases per clinic?", "average days overdue by
-- priority?") normally mean either a hand-written query per question or
-- free-form text-to-SQL, which is our single biggest live-stability risk. A
-- semantic view is the third option: dimensions, metrics and relationships are
-- declared ONCE, with synonyms, and questions are answered from that
-- definition. Nobody writes SQL against raw tables, and the same metric
-- cannot be computed two different ways by two different people.
--
-- It is also what Cortex Analyst consumes, so this object is the bridge to
-- natural-language querying the moment Cortex is entitled on the account.
--
-- Verified working:
--   SELECT * FROM SEMANTIC_VIEW(P360.HEALTHONE_360
--     METRICS cases.case_count, cases.avg_days_overdue
--     DIMENSIONS cases.case_type, cases.priority);
--   -> MED_CONFLICT/MEDIUM 11 (avg 213 days), MONITORING_GAP/HIGH 7 (avg 200),
--      MONITORING_GAP/MEDIUM 6 (avg 85)
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE SCHEMA P360; USE WAREHOUSE HO_WH;
CREATE OR REPLACE SEMANTIC VIEW P360.HEALTHONE_360
  TABLES (
    person AS P360.P360_PERSON
      PRIMARY KEY (PERSON_ID)
      WITH SYNONYMS ('patient','member','people')
      COMMENT = 'One row per person, provider and payer sides joined',
    cases AS CASES.CASE_REGISTRY
      PRIMARY KEY (CASE_ID)
      WITH SYNONYMS ('review cases','alerts')
      COMMENT = 'Monitoring gap and medication conflict cases',
    labs AS P360.P360_LAB_TIMELINE
      WITH SYNONYMS ('lab results','tests')
      COMMENT = 'Every lab result, mapped or not'
  )
  RELATIONSHIPS (
    cases_to_person AS cases (PERSON_ID) REFERENCES person,
    labs_to_person  AS labs  (PERSON_ID) REFERENCES person
  )
  DIMENSIONS (
    person.sex AS SEX WITH SYNONYMS ('gender'),
    person.clinic AS PRIMARY_CLINIC WITH SYNONYMS ('site','location'),
    person.plan AS PLAN_CODE WITH SYNONYMS ('insurance plan'),
    cases.case_type AS CASE_TYPE WITH SYNONYMS ('type of case'),
    cases.priority AS PRIORITY WITH SYNONYMS ('urgency'),
    cases.status AS STATUS WITH SYNONYMS ('state'),
    labs.test AS LAB_TEST_ID WITH SYNONYMS ('which test')
  )
  METRICS (
    person.person_count AS COUNT(person.PERSON_ID)
      WITH SYNONYMS ('number of patients') COMMENT = 'Distinct people',
    cases.case_count AS COUNT(cases.CASE_ID)
      WITH SYNONYMS ('number of cases') COMMENT = 'Count of review cases',
    cases.avg_days_overdue AS AVG(cases.DAYS_SINCE_REFERENCE)
      WITH SYNONYMS ('average days overdue')
      COMMENT = 'Mean days since the last qualifying event',
    labs.result_count AS COUNT(labs.RESULT_DATE)
      WITH SYNONYMS ('number of lab results')
  )
  COMMENT = 'Governed semantic layer over the Patient and Member 360.';
