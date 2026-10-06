-- ===========================================================================
-- ACCOUNT #3 ENTITLEMENT PROBE.  Paste into a Snowsight worksheet.
--
-- The second trial expired 2026-10. Before rebuilding into a third account we
-- have to know whether Cortex is entitled there, because the FIRST account
-- looked fine and then refused every Claude model, and nine days of
-- half-finished features came out of believing it.
--
-- HOW TO RUN: hit Run All. The statements are ordered so that the most
-- diagnostic ones come FIRST, because Snowsight stops at the first error - so
-- if something fails you still have the answers that matter. If it stops, send
-- me the error text and the rows you did get.
--
-- These are plain statements on purpose. The first version of this file wrapped
-- every probe in a Snowflake Scripting block with its own exception handler,
-- which reads better but could not be tested without an account to test it on.
-- Eight statements I can verify by eye beat a hundred lines I cannot.
--
-- SAFE TO RUN. Reads only, apart from one ALTER ACCOUNT enabling cross-region
-- inference - a PREREQUISITE, not a workaround: every Claude model on Cortex is
-- cross-region only, in every region. Costs seconds of the smallest warehouse.
-- ===========================================================================

-- ===========================================================================
-- QUICK VERDICT - four lines. Run THIS first on any new account.
-- If it returns OK, the account is entitled and you can stop reading.
-- If it says "not available for trial accounts", the signup flow was wrong and
-- no amount of configuration will fix it.
-- ===========================================================================
-- USE ROLE ACCOUNTADMIN;
-- USE WAREHOUSE COMPUTE_WH;
-- ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';
-- SELECT AI_COMPLETE('claude-sonnet-5', 'Reply with exactly: OK') AS verdict;

-- ===========================================================================
-- WHICH ACCOUNTS DOES THIS LOGIN HAVE, AND WHAT EDITION?
--
-- Needed because the hackathon link can land you in an account you already
-- had. Account #3 came back as a standard trial even though the hackathon link
-- was followed, and "I signed up through the link" and "I am logged into the
-- account the link created" are different claims.
--
-- ORGADMIN lists every account in THIS organisation with its edition. An
-- account created by the event link may sit in a DIFFERENT organisation, in
-- which case it will not appear here - use the account switcher at the
-- bottom-left of Snowsight, which spans organisations.
-- ===========================================================================
-- USE ROLE ORGADMIN;
-- SHOW ORGANIZATION ACCOUNTS;

USE ROLE ACCOUNTADMIN;

-- A brand-new trial ships with COMPUTE_WH. If this line errors, run
-- SHOW WAREHOUSES and substitute whatever exists.
USE WAREHOUSE COMPUTE_WH;


-- --- 0. Prerequisites. Without cross-region, a model hosted elsewhere reads
-- ---    as "unknown model", which looks exactly like "not entitled".
ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE ACCOUNTADMIN;


-- --- 1. IDENTITY. Send this row back - it is what the CLI profile needs.
-- --- ACCOUNT_LOCATOR + REGION build the connection string; ORG is what the
-- --- Snowsight URL shows. Confusing the two cost a 404 on the last account.
SELECT CURRENT_ORGANIZATION_NAME() AS ORG,
       CURRENT_ACCOUNT()           AS ACCOUNT_LOCATOR,
       CURRENT_REGION()            AS REGION,
       CURRENT_USER()              AS USERNAME,
       CURRENT_ROLE()              AS ROLE;


-- --- 2. THE CANARY, and it runs before Claude on purpose.
-- --- A non-Claude model separates the two failure modes that look identical:
-- ---   this PASSES, Claude fails  -> Cortex is entitled; cross-region or the
-- ---                                 model name is the problem. Fixable.
-- ---   this FAILS                 -> the account has no Cortex at all. The
-- ---                                 signup flow was wrong. Only a new
-- ---                                 account fixes it; no grant does.
SELECT AI_COMPLETE('mistral-7b', 'Reply with exactly: OK') AS canary_non_claude;


-- --- 3. The model the entire product depends on.
SELECT AI_COMPLETE('claude-sonnet-5', 'Reply with exactly: OK') AS claude_sonnet_5;


-- --- 4. Embeddings - the prerequisite for Cortex Search. Expect 768.
SELECT ARRAY_SIZE(SNOWFLAKE.CORTEX.EMBED_TEXT_768(
         'snowflake-arctic-embed-m', 'monitoring interval')) AS embed_dims;


-- --- 5. AI_PARSE_DOCUMENT - the PDF reader. SHOW returns rows rather than
-- --- raising, so this cannot abort the worksheet. 0 rows = not available.
SHOW FUNCTIONS LIKE 'AI_PARSE_DOCUMENT%' IN SCHEMA SNOWFLAKE.CORTEX;


-- --- 6. Confirm the cross-region setting actually took.
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;


-- --- 7. Which Claude models this account can actually see. If step 3 failed
-- --- with "unknown model", the answer is in here.
SELECT MODEL_NAME, MODEL_TYPE
  FROM SNOWFLAKE.INFORMATION_SCHEMA.CORTEX_FUNCTIONS_AVAILABILITY
 WHERE MODEL_NAME ILIKE '%claude%'
 ORDER BY MODEL_NAME;


-- ===========================================================================
-- READING THE RESULT
--   All pass                   -> rebuild immediately:
--                                 $HO_SF sql -f sql/26_new_account_setup.sql
--                                 then HO_SF=./tools/sfx ./tools/deploy_new_account
--   Canary passes, Claude not  -> entitled; fix cross-region or the model name
--                                 using step 7's list.
--   Canary fails               -> not entitled. Must be the "AI Data Cloud"
--                                 trial, NOT "Cortex Code CLI".
-- ===========================================================================
