-- STATUS: SUPERSEDED 2026-08-30. NEVER EXECUTED. Do not run.
-- Replaced by: sql/27_cortex_enabled.sql, which creates CONF.DOC_SEARCH for real now that
-- EMBED_TEXT_768 is entitled. This file was written against the blocked account.
-- Passage retrieval + citations over document chunks (docs/02 §2.7).
-- Prereq: DOC_CHUNK has CHANGE_TRACKING = TRUE (sql/03).
USE ROLE HO_ADMIN; USE DATABASE HEALTHONE; USE SCHEMA CONF;

CREATE OR REPLACE CORTEX SEARCH SERVICE SAFETY_DOC_SEARCH
  ON chunk_text
  ATTRIBUTES doc_id, section_label
  WAREHOUSE = HO_WH
  TARGET_LAG = '5 minutes'
  AS (SELECT chunk_id, doc_id, section_label, chunk_text FROM DOC_CHUNK);

-- Live-doc beat note (docs/02 §2.7): the demo's critical path does NOT depend
-- on this service; if a fresh doc must be searchable immediately:
-- ALTER CORTEX SEARCH SERVICE SAFETY_DOC_SEARCH REFRESH;
