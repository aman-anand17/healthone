#!/usr/bin/env python3
"""Launch the Streamlit app locally against the ISOLATED Snowflake config.

Exists because the environment variable has to be set before Streamlit imports
data_access, and a launch configuration that just runs `python -m streamlit`
cannot set it. Without SNOWFLAKE_HOME the connector reads the CLI's default
directory, finds no 'hackathon5' profile, and the app silently falls back to
fixture mode - which looks like a working app showing 1 case instead of 33.
"""
import os
import sys
from pathlib import Path

os.environ.setdefault("SNOWFLAKE_HOME", str(Path.home() / ".snowflake-ho360"))
os.environ.setdefault("HO_MODE", "local")
os.environ.setdefault("HO_CONNECTION", "hackathon5")

from streamlit.web import cli as stcli  # noqa: E402

sys.argv = ["streamlit", "run", "app/streamlit_app.py",
            "--server.port", "8501", "--server.headless", "true",
            "--browser.gatherUsageStats", "false"]
sys.exit(stcli.main())
