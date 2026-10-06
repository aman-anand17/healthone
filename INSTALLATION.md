# INSTALLATION.md — zero to a running app

Three independent goals. Do them in order, or stop after whichever one you
need:

- **Goal A — run the app locally in fixture mode.** Needs only Python. No
  Snowflake account, no credentials. Start here to see the product.
- **Goal B — connect the Snowflake CLI** to an account, so you can deploy SQL
  and run the pipeline.
- **Goal C — connect CoCo CLI**, which is how this project was actually built
  and demonstrated.

---

## The one rule that is not negotiable

> **This project uses `~/.snowflake-ho360/` as its `SNOWFLAKE_HOME`, never
> `~/.snowflake/`.**

`~/.snowflake/` is the CLI's default location, and on a shared or work machine
it may already hold a credential belonging to something else entirely. Keeping
this project's profiles in their own directory means it cannot read or overwrite
that credential, and nothing outside the disposable hackathon account is
reachable from here.

`tools/sfx` pins the variable for you. If you invoke `snow` or `cortex`
directly, export it first:

```bash
export SNOWFLAKE_HOME="$HOME/.snowflake-ho360"      # bash / Git Bash
```
```powershell
$env:SNOWFLAKE_HOME = "$HOME\.snowflake-ho360"      # PowerShell
```

`tools/sfx` has **no default profile** and exits non-zero if `HO_PROFILE` is
unset. That is deliberate: an earlier version defaulted to a profile name and
quietly deployed to an expired account for a while before anyone noticed.

---

## 0. Prerequisites

| Tool | Check | Install if missing |
|---|---|---|
| Python 3.10+ | `python --version` | python.org (tested with 3.12) |
| pip | `python -m pip --version` | ships with Python |
| Git (incl. Git Bash) | `git --version` | git-scm.com — Git Bash also provides `openssl`, needed for key-pair auth |

Commands are given for both Git Bash and PowerShell where they differ.

---

## Goal A — run the app in fixture mode (2 minutes, no Snowflake)

```bash
pip install streamlit
streamlit run app/streamlit_app.py
```

A browser opens at http://localhost:8501. Everything you see comes from
`fixtures/answer_contract.json` (`FIXTURE_MODE` in `app/data_access.py`).
Nothing touches Snowflake. The fixture contains **no PHI at all** — by design,
so fixture mode cannot leak what live mode protects.

If the page is blank, check the terminal for a Python traceback and confirm you
ran the command from the repository root.

---

## Goal B — the Snowflake CLI

### B1. Install

```bash
pip install snowflake-cli
snow --version
```

- The package was formerly `snowflake-cli-labs`; the current name is
  `snowflake-cli`. Do not install both.
- If `snow` is "not recognized" after install: close and reopen the terminal so
  PATH refreshes, or run `python -m snowflake.cli --version`. If only the module
  form works, your Python `Scripts` directory is not on PATH.

### B2. Get the account identifier

In Snowsight: click your name (bottom-left) → account → **copy account
identifier**. It looks like `ORGNAME-ACCOUNTNAME`. The legacy locator form looks
like `xy12345.us-east-1`.

### B3. Create the config directory

```bash
mkdir -p ~/.snowflake-ho360
export SNOWFLAKE_HOME="$HOME/.snowflake-ho360"
```

### B4. Add a connection — password path (quickest)

```bash
snow connection add --connection-name hackathon \
  --account <ORG-ACCOUNT> --user <USERNAME> \
  --warehouse HO_WH --database HEALTHONE --role HO_ADMIN
```

You are prompted for the password; press Enter to skip everything else. The
profile lands in `$SNOWFLAKE_HOME/connections.toml`. **Credentials never go in
the repository** — `.gitignore` blocks `connections.toml`, `config.toml`, `*.p8`
and `*.pub`, and `tools/make_release.py` additionally scans the content of every
published file for key material.

Caveat: if your user has MFA (Duo) enrolled, password auth can trigger a push
notification on *every statement*. If that happens, use key-pair (B5).

### B5. Add a connection — key-pair path (recommended; no MFA prompts)

1. Generate a key pair **into the project's own directory**, in Git Bash:

   ```bash
   mkdir -p ~/.snowflake-ho360
   openssl genrsa 2048 \
     | openssl pkcs8 -topk8 -inform PEM -out ~/.snowflake-ho360/rsa_key.p8 -nocrypt
   openssl rsa -in ~/.snowflake-ho360/rsa_key.p8 -pubout -out ~/.snowflake-ho360/rsa_key.pub
   ```

2. Register the public key on your Snowflake user. Open `rsa_key.pub` and copy
   everything **between** the BEGIN/END lines, then in Snowsight:

   ```sql
   ALTER USER <USERNAME> SET RSA_PUBLIC_KEY='MIIBIjANBgkq...';
   ```

3. Add the connection:

   ```bash
   snow connection add --connection-name hackathon \
     --account <ORG-ACCOUNT> --user <USERNAME> \
     --authenticator SNOWFLAKE_JWT \
     --private-key-file "$HOME/.snowflake-ho360/rsa_key.p8" \
     --warehouse HO_WH --database HEALTHONE --role HO_ADMIN
   ```

### B6. Verify

```bash
HO_PROFILE=hackathon tools/sfx connection test
HO_PROFILE=hackathon tools/sfx sql -q "SELECT CURRENT_USER(), CURRENT_ROLE(), CURRENT_ACCOUNT(), CURRENT_REGION(), CURRENT_VERSION()"
```

Both must succeed before anything is deployed.

Note: `HO_WH`, `HEALTHONE` and `HO_ADMIN` do not exist until
`sql/26_new_account_setup.sql` has run. For the very first connection test, use
your own default role and no database or warehouse, or expect harmless "object
does not exist" warnings.

### B7. Check Cortex entitlement before depending on it

This is the single thing most likely to stop you, and it is not a permissions
problem when it happens.

```bash
HO_PROFILE=hackathon tools/sfx sql -f sql/33_probe_new_account.sql
```

The probe deliberately includes a **non-Claude canary model**. If that fails
too, the account is not entitled to Cortex at all and no grant, parameter or
role will fix it — it is a tier restriction (`399258 — not available for trial
accounts`). Three accounts refused Cortex during this build before one was
entitled. The signup flow matters: choose the **AI Data Cloud** option.

If Cortex is unavailable, the project still deploys and runs — see
`HO_NO_CORTEX=1` in B8.

### B8. Deploy the whole thing

Two commands. The first is the only one needing ACCOUNTADMIN.

```bash
HO_PROFILE=hackathon tools/sfx sql -f sql/26_new_account_setup.sql
HO_SF=./tools/sfx HO_PROFILE=hackathon tools/deploy_new_account
```

Ordered by dependency, every step idempotent, so re-running is safe. It
finishes by running the test suites and printing a pass/fail line per suite.
Add `HO_NO_CORTEX=1` on an account without Cortex — the extraction engine falls
back to its deterministic backend and the app reports that it has, rather than
failing.

---

## Goal C — CoCo CLI (Cortex Code)

This project ships its own CoCo skill, and the demo is driven entirely from
CoCo. Install per the official documentation:

**https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code-cli**

Built and verified here with **v1.1.104**. On Windows the installer puts the
binary under `%LOCALAPPDATA%\cortex\`, which may not be on PATH; the demo script
addresses it by full path.

### C1. Point CoCo at this project's profiles, then confirm

```powershell
$env:SNOWFLAKE_HOME = "$HOME\.snowflake-ho360"
cortex connections list
```

**Set `SNOWFLAKE_HOME` before launching `cortex`, every time.** CoCo reads
`~/.snowflake/connections.toml` by default. `connections list` is the check that
it is looking where you think: it should list this project's profiles and
nothing else.

### C2. Register the skill

```powershell
cortex skill add ".cortex/skills/patient-evidence-review"
cortex skill list          # appears under [EXTERNAL]
```

### C3. Run something

```powershell
cortex exec -c hackathon --allowed "sql" --max-turns 10 `
  "Call HEALTHONE.RULES.SP_INGEST_EXTRACT_ALL('<actor>', TRUE) and report the backend, the document count and the chunk count."
```

**`--allowed "sql"` is required.** In `exec` mode interactive approvals are
auto-rejected, so the built-in SQL tool is blocked unless you name it. The tool
is called `sql`, not `sql_execute`. That cost two failed runs to discover.

Saved output from real sessions, with the exact commands that produced it, is
in [`coco/README.md`](coco/README.md).

---

## Troubleshooting

**`AI function ... is not available for trial accounts` (399258)** — a tier
restriction, not permissions. See B7. Verified by applying
`GRANT USE AI FUNCTIONS ON ACCOUNT` first: the privilege landed and the error
did not change by one character.

**`unknown model` from `AI_COMPLETE`** — Claude models in Cortex are
region-gated. Check `SELECT CURRENT_REGION()`. The model this project runs on is
`claude-sonnet-5`. If no Claude model answers, cross-region inference must be
enabled by ACCOUNTADMIN:
`ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';`
That is an account-level decision — raise it, do not set it silently.

**MFA push on every statement** — your user has Duo enrolled and you are on
password auth. Switch to key-pair (B5). Do not disable MFA.

**`connection test` fails or hangs** — usually one of:
- Wrong account identifier (most common). Use the exact string from Snowsight;
  replace any `.` in the org form with `-`.
- A corporate proxy or SSL interception blocking
  `*.snowflakecomputing.com:443`. Set `HTTPS_PROXY` if your machine needs one.
  If you see certificate errors, talk to IT — do not disable certificate
  verification.

**`Incorrect username or password` with correct credentials** — usually the
account identifier points at the wrong account or region, not a bad password.

**`JWT token is invalid`** — the public key is not registered on that user, the
private-key path in the connection is wrong, or the key body was pasted with the
BEGIN/END lines included.

**`Object does not exist or not authorized`** — wrong role. Check
`SELECT CURRENT_ROLE()` and that `GRANT ROLE HO_ADMIN TO USER <you>` ran;
`sql/26_new_account_setup.sql` does it from `CURRENT_USER()`.

**CoCo cannot see your connection** — `SNOWFLAKE_HOME` was not exported before
launching it. `cortex connections list` tells you what it can actually see.

**The app errors with `AttributeError` on a function that exists** — Streamlit
in Snowflake caches Python modules, and a deploy is not atomic across files.
Redeploy, then restart the app from Snowsight.

**The Rule library page is slow** — read from
`RULES.CORROBORATION_SNAPSHOT`, not `RULES.V_PROPOSAL_CORROBORATION`. The view
costs ~25s (a Python UDF plus regex per proposal). `sql/37` explains why a
materialized view is impossible here.

**Warehouse or credit errors mid-build** — resource monitors cap the warehouses
and, separately, the whole account; the account-level monitor is the only one
that sees serverless spend. `sql/30_cost_controls.sql` is idempotent and is also
how you shut everything down.
