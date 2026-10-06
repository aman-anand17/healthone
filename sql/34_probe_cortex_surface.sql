-- ===========================================================================
-- WHAT CORTEX CAN THIS TRIAL ACTUALLY DO?  Paste into Snowsight, Run All.
--
-- Account #4 (kiczehe-dg41118, AP Tokyo) was created correctly: hackathon
-- AI Data Cloud link, the registered Gmail, Enterprise flow. AI_COMPLETE still
-- refuses with:
--
--     AI function _COMPLETE_WITH_PROMPT_HISTORY_LLM is not available
--     for trial accounts.
--
-- Account #2 was created through the SAME flow on 30 Aug and AI_COMPLETE
-- worked. So this is not a signup mistake - it looks like Snowflake tightened
-- LLM access on trial accounts in between. That is not something a grant or a
-- parameter fixes, and guessing is what cost nine days on account #1.
--
-- WHAT THIS FILE IS FOR. The error names an INTERNAL function
-- (_COMPLETE_WITH_PROMPT_HISTORY_LLM) behind the newer AI_COMPLETE entry
-- point. Cortex has several entry points that route to different internals,
-- and the task-specific ones are frequently available when generic completion
-- is not. The product needs ONE working text-generation path; which name it
-- goes through is an implementation detail we control (RULES.EXTRACTOR_CONFIG
-- already stores the model as data, not as a literal).
--
-- So this probes the whole surface and reports what survives. Every probe has
-- its own exception handler, because they fail independently and a bare SELECT
-- that raises aborts the worksheet and hides everything after it.
-- ===========================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE ACCOUNTADMIN;

EXECUTE IMMEDIATE $$
DECLARE
  report STRING := '';
  nl     STRING := CHR(10);
BEGIN
  report := report || '=== TEXT GENERATION: is there ANY working path? ===' || :nl;

  -- 1. The LEGACY entry point. Different name, different internal routing.
  --    This is the one most likely to survive, and the product only needs one.
  BEGIN
    LET r STRING := (SELECT SNOWFLAKE.CORTEX.COMPLETE('claude-sonnet-5',
                                                      'Reply with exactly: OK'));
    report := report || '  [PASS] CORTEX.COMPLETE claude-sonnet-5 -> ' || :r || :nl;
  EXCEPTION WHEN OTHER THEN
    report := report || '  [FAIL] CORTEX.COMPLETE claude-sonnet-5 -> ' || SQLERRM || :nl;
  END;

  -- 2. Same legacy path, small open model. Separates "no LLM at all" from
  --    "no Claude on a trial".
  BEGIN
    LET r STRING := (SELECT SNOWFLAKE.CORTEX.COMPLETE('mistral-7b',
                                                      'Reply with exactly: OK'));
    report := report || '  [PASS] CORTEX.COMPLETE mistral-7b -> ' || :r || :nl;
  EXCEPTION WHEN OTHER THEN
    report := report || '  [FAIL] CORTEX.COMPLETE mistral-7b -> ' || SQLERRM || :nl;
  END;

  -- 3. llama, the most widely enabled model on Cortex.
  BEGIN
    LET r STRING := (SELECT SNOWFLAKE.CORTEX.COMPLETE('llama3.1-8b',
                                                      'Reply with exactly: OK'));
    report := report || '  [PASS] CORTEX.COMPLETE llama3.1-8b -> ' || :r || :nl;
  EXCEPTION WHEN OTHER THEN
    report := report || '  [FAIL] CORTEX.COMPLETE llama3.1-8b -> ' || SQLERRM || :nl;
  END;

  report := report || :nl
         || '=== TASK-SPECIFIC FUNCTIONS (often allowed when COMPLETE is not) ===' || :nl;

  -- 4. EXTRACT_ANSWER is the interesting one for THIS product: it pulls a span
  --    out of a passage, which is most of what rule extraction needs.
  BEGIN
    LET r STRING := (SELECT SNOWFLAKE.CORTEX.EXTRACT_ANSWER(
        'Serum potassium should be checked at least every three months.',
        'How often should potassium be checked?')::STRING);
    report := report || '  [PASS] CORTEX.EXTRACT_ANSWER -> ' || :r || :nl;
  EXCEPTION WHEN OTHER THEN
    report := report || '  [FAIL] CORTEX.EXTRACT_ANSWER -> ' || SQLERRM || :nl;
  END;

  BEGIN
    LET r STRING := (SELECT SNOWFLAKE.CORTEX.SUMMARIZE(
        'Patients receiving CardioZen who have chronic kidney disease should '
     || 'have serum potassium measured at least every three months for the '
     || 'duration of therapy.'));
    report := report || '  [PASS] CORTEX.SUMMARIZE -> ' || LEFT(:r, 60) || :nl;
  EXCEPTION WHEN OTHER THEN
    report := report || '  [FAIL] CORTEX.SUMMARIZE -> ' || SQLERRM || :nl;
  END;

  BEGIN
    LET r STRING := (SELECT SNOWFLAKE.CORTEX.SENTIMENT('This is excellent')::STRING);
    report := report || '  [PASS] CORTEX.SENTIMENT -> ' || :r || :nl;
  EXCEPTION WHEN OTHER THEN
    report := report || '  [FAIL] CORTEX.SENTIMENT -> ' || SQLERRM || :nl;
  END;

  BEGIN
    LET r STRING := (SELECT AI_CLASSIFY('every three months',
                      ['monitoring interval', 'dosage', 'adverse event'])::STRING);
    report := report || '  [PASS] AI_CLASSIFY -> ' || :r || :nl;
  EXCEPTION WHEN OTHER THEN
    report := report || '  [FAIL] AI_CLASSIFY -> ' || SQLERRM || :nl;
  END;

  report := report || :nl || '=== RETRIEVAL AND DOCUMENTS ===' || :nl;

  BEGIN
    LET d INT := (SELECT ARRAY_SIZE(SNOWFLAKE.CORTEX.EMBED_TEXT_768(
                    'snowflake-arctic-embed-m', 'monitoring interval')));
    report := report || '  [PASS] EMBED_TEXT_768 -> ' || :d || ' dims' || :nl;
  EXCEPTION WHEN OTHER THEN
    report := report || '  [FAIL] EMBED_TEXT_768 -> ' || SQLERRM || :nl;
  END;

  BEGIN
    LET d INT := (SELECT ARRAY_SIZE(SNOWFLAKE.CORTEX.EMBED_TEXT_1024(
                    'snowflake-arctic-embed-l-v2.0', 'monitoring interval')));
    report := report || '  [PASS] EMBED_TEXT_1024 -> ' || :d || ' dims' || :nl;
  EXCEPTION WHEN OTHER THEN
    report := report || '  [FAIL] EMBED_TEXT_1024 -> ' || SQLERRM || :nl;
  END;

  -- AI_PARSE_DOCUMENT resolved on account #3 with an argument error rather
  -- than the trial refusal, which hinted it might be allowed. Same probe here:
  -- an ARGUMENT/signature error means available; a trial refusal means not.
  BEGIN
    LET r STRING := (SELECT AI_PARSE_DOCUMENT());
    report := report || '  [PASS] AI_PARSE_DOCUMENT resolvable' || :nl;
  EXCEPTION WHEN OTHER THEN
    report := report || '  [?]    AI_PARSE_DOCUMENT -> ' || SQLERRM || :nl
           || '         (signature/argument error = AVAILABLE;' || :nl
           || '          "not available for trial accounts" = NOT)' || :nl;
  END;

  report := report || :nl || '=== VERDICT ===' || :nl
    || '  Any PASS on 1-3  -> the product works. Point' || :nl
    || '                      RULES.EXTRACTOR_CONFIG at that function+model.' || :nl
    || '  Only 4-7 pass    -> extraction is rebuildable on task-specific calls;' || :nl
    || '                      degraded but still genuinely AI.' || :nl
    || '  EMBED passes     -> Cortex Search still possible.' || :nl
    || '  All fail         -> no Cortex on this trial. Organisers must fix the' || :nl
    || '                      entitlement, or we ship the deterministic' || :nl
    || '                      extractor and say so plainly.' || :nl;

  RETURN report;
END;
$$;
