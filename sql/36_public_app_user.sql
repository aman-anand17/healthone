-- ===========================================================================
-- THE SERVICE USER THAT LETS THE APP BE PUBLIC, AND THE JUDGE LOGIN.
--
-- WHY THIS FILE EXISTS NOW AND NOT IN AUGUST: HO_PUBLIC_APP was created BY HAND
-- on account #2. It was in no SQL file, so when that trial expired the service
-- user went with it and the rebuild produced an account with no way to serve a
-- public app. That is the same class of mistake as sql/10 creating masking
-- policies and never attaching them: work that only exists in a session is work
-- that will be lost. Anything the product needs belongs in a file.
--
-- STREAMLIT IN SNOWFLAKE HAS NO ANONYMOUS ACCESS. That is a platform fact, not
-- a configuration we have got wrong, and it shapes everything below. There are
-- exactly two ways to give someone who has no Snowflake account a working link:
--
--   A. A LOGIN they can use. Section 2 - a judge user with a password. The
--      link is the real Snowflake app, which is the most honest demo, but the
--      judge has to sign in.
--   B. A PUBLIC app that authenticates AS a service user. Section 1 - this
--      user, used by Streamlit Community Cloud, which holds the credential in
--      its own encrypted secrets store and shows the app to anonymous
--      visitors. See submission/PUBLIC_DEPLOY.md.
--
-- Both are provided because they fail in different ways: A needs the judge to
-- accept a login, B needs the repository to be on GitHub first.
-- ===========================================================================

USE ROLE ACCOUNTADMIN;

-- ===========================================================================
-- 1. HO_PUBLIC_APP - the service identity behind a public deployment.
--
-- KEY-PAIR, NOT A PASSWORD, and that choice is the point: the PUBLIC half of
-- the key pair is in this file and is safe to commit, because a public key
-- cannot be used to authenticate. The private half never leaves
-- ~/.snowflake-ho360/keys/ and is blocked by .gitignore. A password here would
-- have had to be invented, pasted into Community Cloud, and then either
-- committed (disclosed) or kept only in someone's head (lost on the next
-- account, exactly as this user itself was).
--
-- HO_REVIEWER, NEVER ACCOUNTADMIN. The product's central claim is that a
-- reviewer sees masked patient data and must break the glass deliberately. An
-- admin role would show every name in clear and demonstrate the opposite of
-- what the app says about itself to the person evaluating it.
-- ===========================================================================
CREATE USER IF NOT EXISTS HO_PUBLIC_APP
  TYPE = SERVICE
  DEFAULT_ROLE      = HO_REVIEWER
  DEFAULT_WAREHOUSE = HO_WH
  DEFAULT_NAMESPACE = HEALTHONE.APP
  COMMENT = 'Service identity for the publicly hosted Streamlit app. Key-pair only, HO_REVIEWER only, so PHI stays masked for anonymous visitors.';

-- Re-applied unconditionally: CREATE USER IF NOT EXISTS leaves an existing
-- user's key untouched, and a stale key is indistinguishable from a wrong one.
ALTER USER HO_PUBLIC_APP SET RSA_PUBLIC_KEY =
'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAlmW5NlW3fsfWt0UhgWP1eRJJrxPHJVn7RqmQdJZuWPKcvZ86EFUr+5jsl2I1+3VGjXwpwzpk1vTtHTwFeXRjcou2m2XnBUOi3SnilfsdI6gtwJIYTGQ0zztO5kGCaAdnEyUcYPD4OF34xyg8tofqNakscv2X6zeurgq8EZx3hg8z0riloSJp+Iws5QQM9ZPZvIJjfQEzanuGcdgKIdrHuVFr6rPpi8h9C0ar9yYwZtluYBD8Q3EnVd4QkQi+N7HRvk4TMatgdQsxqVodWodOM90r9YpXMHL/yY6TOiDhia5XIN2yI9lLkEWn976roFuCQsPph4LCYrAmwG4U/yaSVQIDAQAB';

GRANT ROLE HO_REVIEWER TO USER HO_PUBLIC_APP;

-- The row-access policy filters on USER_NAME. Without an assignment this user
-- sees zero patients and the public app looks broken - which happened once
-- already and is why SEC.V_SESSION_DIAGNOSTIC exists. sql/29 inserts a
-- wildcard row; this is belt and braces for the named user.
USE ROLE HO_ADMIN;
MERGE INTO HEALTHONE.SEC.REVIEWER_ASSIGNMENT t
USING (SELECT 'HO_PUBLIC_APP' AS USER_NAME, '*' AS PRIMARY_CLINIC) s
   ON t.USER_NAME = s.USER_NAME AND t.PRIMARY_CLINIC = s.PRIMARY_CLINIC
WHEN NOT MATCHED THEN INSERT (USER_NAME, PRIMARY_CLINIC)
     VALUES (s.USER_NAME, s.PRIMARY_CLINIC);

-- ===========================================================================
-- 2. THE JUDGE LOGIN - ONE STATEMENT TO RUN BY HAND.
--
-- Still not automated, and still for the same reason: it needs a password, and
-- a password committed to a repository is a password that has been disclosed.
-- This repository is going to GitHub. Run this yourself, once:
--
--   USE ROLE ACCOUNTADMIN;
--   CREATE USER IF NOT EXISTS JUDGE_HO360
--     PASSWORD = '<choose one, do not reuse anything>'
--     DEFAULT_ROLE      = HO_REVIEWER
--     DEFAULT_WAREHOUSE = HO_WH
--     DEFAULT_NAMESPACE = HEALTHONE.APP
--     MUST_CHANGE_PASSWORD = FALSE
--     COMMENT = 'Read-mostly login for hackathon judges. Sees the app as a
--                Clinical Case Reviewer, with PHI masked.';
--   GRANT ROLE HO_REVIEWER TO USER JUDGE_HO360;
--
-- Then hand out the app URL, the username JUDGE_HO360, and that password.
-- After the event:  DROP USER JUDGE_HO360;
-- ===========================================================================

-- Prove the service user can actually do the job, rather than assuming it.
USE ROLE ACCOUNTADMIN;
SHOW GRANTS TO USER HO_PUBLIC_APP;
