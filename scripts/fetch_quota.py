#!/usr/bin/env python3
"""Fetch Antigravity Quotas and Usage for Multiple Accounts.

Queries Google Cloud Code API for all configured Antigravity accounts,
formats remaining quotas and reset countdowns, maintains smart local cache,
and synchronizes with Omarchy's native agent status.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import urllib.error
import urllib.request
from typing import Any

# Import accounts manager from same directory
try:
    from accounts import (
        load_accounts_data,
        refresh_account_token,
        save_accounts_data,
    )
except ImportError:
    from scripts.accounts import (
        load_accounts_data,
        refresh_account_token,
        save_accounts_data,
    )

CACHE_DIR = Path.home() / ".cache" / "omarchy" / "agent-usage"
CACHE_FILE = CACHE_DIR / "antigravity-multi-quota.json"
OMARCHY_AGENT_DIR = Path.home() / ".local" / "state" / "omarchy" / "agents" / "usage"
OMARCHY_AGENT_FILE = OMARCHY_AGENT_DIR / "antigravity.json"

API_ENDPOINTS = [
    "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
    "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
]

SUMMARY_API_ENDPOINTS = [
    "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:retrieveUserQuotaSummary",
    "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
    "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
]


def ensure_dirs() -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    OMARCHY_AGENT_DIR.mkdir(parents=True, exist_ok=True)


def parse_iso_datetime(iso_str: str | None) -> dt.datetime | None:
    if not iso_str:
        return None
    try:
        ts = dt.datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=dt.timezone.utc)
        return ts
    except Exception:
        return None


def format_reset_delta(reset_time_str: str | None, remaining_fraction: float) -> str:
    if not reset_time_str:
        return "100% Available" if remaining_fraction >= 0.999 else "n/a"

    ts = parse_iso_datetime(reset_time_str)
    if not ts:
        return reset_time_str

    now = dt.datetime.now(dt.timezone.utc)
    delta = ts - now
    total_sec = int(delta.total_seconds())

    if total_sec <= 0:
        return "Ready now"

    mins = total_sec // 60
    hours = mins // 60
    days = hours // 24

    if days > 0:
        return f"in {days}d {hours % 24}h"
    elif hours > 0:
        return f"in {hours}h {mins % 60}m"
    else:
        return f"in {max(1, mins)}m"


def query_cloudcode_models(access_token: str) -> dict[str, Any]:
    """Query Cloud Code API for available models and quota info."""
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
        "User-Agent": "antigravity",
    }
    last_err: Exception | None = None

    for endpoint in API_ENDPOINTS:
        req = urllib.request.Request(endpoint, data=b"{}", headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=12) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                if isinstance(data, dict) and "models" in data:
                    return data
        except urllib.error.HTTPError as e:
            last_err = e
            if e.code in (401, 403):
                raise  # Re-raise auth errors for token refresh
        except Exception as e:
            last_err = e
            continue

    if last_err:
        raise last_err
    return {}


def query_cloudcode_quota_summary(access_token: str) -> dict[str, Any]:
    """Query Cloud Code API for user quota summary (weekly + 5h buckets)."""
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
        "User-Agent": "antigravity",
    }
    for endpoint in SUMMARY_API_ENDPOINTS:
        req = urllib.request.Request(endpoint, data=b"{}", headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                if isinstance(data, dict) and "groups" in data:
                    return data
        except Exception:
            continue
    return {}


def classify_family(model_id: str) -> str:
    m = model_id.lower()
    if "claude" in m:
        return "claude"
    if "gpt" in m:
        return "gpt_oss"
    if "flash" in m:
        return "gemini_flash"
    if "pro" in m:
        return "gemini_pro"
    return "other"


def collect_account_quota(account: dict[str, Any]) -> dict[str, Any]:
    """Collect quota for a single account."""
    email = account.get("email", "")
    tier = account.get("tier", "Google AI Pro")

    # Refresh token if needed
    try:
        access_token = refresh_account_token(account, force=False)
    except Exception as e:
        return {
            "email": email,
            "tier": tier,
            "error": f"Token refresh failed: {e}",
            "overallRemaining": 0.0,
            "overallResetFormatted": "Auth error",
            "weeklyRemaining": 0.0,
            "weeklyPercent": 0.0,
            "weeklyResetFormatted": "Auth error",
            "fiveHourRemaining": 0.0,
            "fiveHourPercent": 0.0,
            "fiveHourResetFormatted": "Auth error",
            "quotaGroups": {},
            "families": {},
            "models": [],
        }

    # Fetch models
    try:
        raw_data = query_cloudcode_models(access_token)
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            # Try forced refresh once
            try:
                access_token = refresh_account_token(account, force=True)
                raw_data = query_cloudcode_models(access_token)
            except Exception as retry_err:
                return {
                    "email": email,
                    "tier": tier,
                    "error": f"API request failed after refresh: {retry_err}",
                    "overallRemaining": 0.0,
                    "overallResetFormatted": "Auth error",
                    "weeklyRemaining": 0.0,
                    "weeklyPercent": 0.0,
                    "weeklyResetFormatted": "Auth error",
                    "fiveHourRemaining": 0.0,
                    "fiveHourPercent": 0.0,
                    "fiveHourResetFormatted": "Auth error",
                    "quotaGroups": {},
                    "families": {},
                    "models": [],
                }
        else:
            return {
                "email": email,
                "tier": tier,
                "error": f"API HTTP {e.code}",
                "overallRemaining": 0.0,
                "overallResetFormatted": f"HTTP {e.code}",
                "weeklyRemaining": 0.0,
                "weeklyPercent": 0.0,
                "weeklyResetFormatted": f"HTTP {e.code}",
                "fiveHourRemaining": 0.0,
                "fiveHourPercent": 0.0,
                "fiveHourResetFormatted": f"HTTP {e.code}",
                "quotaGroups": {},
                "families": {},
                "models": [],
            }
    except Exception as e:
        return {
            "email": email,
            "tier": tier,
            "error": f"Network error: {e}",
            "overallRemaining": 0.0,
            "overallResetFormatted": "Network error",
            "weeklyRemaining": 0.0,
            "weeklyPercent": 0.0,
            "weeklyResetFormatted": "Network error",
            "fiveHourRemaining": 0.0,
            "fiveHourPercent": 0.0,
            "fiveHourResetFormatted": "Network error",
            "quotaGroups": {},
            "families": {},
            "models": [],
        }

    raw_models = raw_data.get("models", {})
    parsed_models: list[dict[str, Any]] = []

    # Buckets per family
    family_buckets: dict[str, list[dict[str, Any]]] = {
        "claude": [],
        "gemini_pro": [],
        "gemini_flash": [],
        "gpt_oss": [],
    }

    for model_id, model_info in raw_models.items():
        if not isinstance(model_info, dict):
            continue
        if model_info.get("isInternal") or str(model_id).startswith("chat_"):
            continue

        display_name = model_info.get("displayName") or model_id
        qi = model_info.get("quotaInfo") or {}
        rem_raw = qi.get("remainingFraction")
        remaining = float(rem_raw) if isinstance(rem_raw, (int, float)) else 1.0
        remaining = max(0.0, min(1.0, remaining))
        reset_time = qi.get("resetTime")

        family_key = classify_family(model_id)
        entry = {
            "id": model_id,
            "displayName": display_name,
            "family": family_key,
            "remainingFraction": round(remaining, 4),
            "remainingPercent": round(remaining * 100, 1),
            "resetTime": reset_time,
            "resetFormatted": format_reset_delta(reset_time, remaining),
        }
        parsed_models.append(entry)

        if family_key in family_buckets:
            family_buckets[family_key].append(entry)

    # Compute family summaries
    family_meta = {
        "claude": "Claude 4.6 (Thinking)",
        "gemini_pro": "Gemini 3 Pro",
        "gemini_flash": "Gemini 3 Flash",
        "gpt_oss": "GPT-OSS 120B",
    }

    families: dict[str, Any] = {}
    family_min_remaining_list: list[float] = []
    overall_next_reset: str | None = None
    overall_min_rem = 1.0

    for f_key, f_name in family_meta.items():
        m_list = family_buckets.get(f_key, [])
        if not m_list:
            families[f_key] = {
                "name": f_name,
                "remaining": 1.0,
                "remainingPercent": 100.0,
                "reset": None,
                "resetFormatted": "100% Full",
            }
            continue

        # Find min remaining fraction in family
        min_rem = min(m["remainingFraction"] for m in m_list)
        # Find next reset among models that have used quota, or first valid reset
        used_resets = [m["resetTime"] for m in m_list if m["remainingFraction"] < 0.999 and m["resetTime"]]
        all_resets = [m["resetTime"] for m in m_list if m["resetTime"]]
        reset_candidates = used_resets if used_resets else all_resets
        best_reset = sorted(reset_candidates)[0] if reset_candidates else None

        families[f_key] = {
            "name": f_name,
            "remaining": min_rem,
            "remainingPercent": round(min_rem * 100, 1),
            "reset": best_reset,
            "resetFormatted": format_reset_delta(best_reset, min_rem),
        }
        family_min_remaining_list.append(min_rem)
        if min_rem < overall_min_rem:
            overall_min_rem = min_rem
            overall_next_reset = best_reset

    if not family_min_remaining_list:
        overall_min_rem = 1.0

    # Fetch grouped quota summary (weekly + 5h)
    summary_raw = query_cloudcode_quota_summary(access_token)
    groups = summary_raw.get("groups", [])

    weekly_mins: list[float] = []
    weekly_resets: list[str] = []
    five_hour_mins: list[float] = []
    five_hour_resets: list[str] = []
    quota_groups: dict[str, Any] = {}

    for g in groups:
        g_name = g.get("displayName", "")
        key = "gemini" if "gemini" in g_name.lower() else "claude"
        group_item: dict[str, Any] = {
            "name": g_name,
            "weeklyRemaining": 1.0,
            "weeklyPercent": 100.0,
            "weeklyReset": None,
            "weeklyResetFormatted": "100% Available",
            "fiveHourRemaining": 1.0,
            "fiveHourPercent": 100.0,
            "fiveHourReset": None,
            "fiveHourResetFormatted": "100% Available",
        }
        for b in g.get("buckets", []):
            win = b.get("window", "")
            bid = b.get("bucketId") or ""
            rem_val = b.get("remainingFraction")
            rem = float(rem_val) if isinstance(rem_val, (int, float)) else 1.0
            rem = max(0.0, min(1.0, rem))
            rst = b.get("resetTime")

            if win == "weekly" or "weekly" in bid:
                group_item["weeklyRemaining"] = round(rem, 4)
                group_item["weeklyPercent"] = round(rem * 100, 1)
                group_item["weeklyReset"] = rst
                group_item["weeklyResetFormatted"] = format_reset_delta(rst, rem)
                weekly_mins.append(rem)
                if rst:
                    weekly_resets.append(rst)
            elif win == "5h" or "5h" in bid:
                group_item["fiveHourRemaining"] = round(rem, 4)
                group_item["fiveHourPercent"] = round(rem * 100, 1)
                group_item["fiveHourReset"] = rst
                group_item["fiveHourResetFormatted"] = format_reset_delta(rst, rem)
                five_hour_mins.append(rem)
                if rst:
                    five_hour_resets.append(rst)
        quota_groups[key] = group_item

    # Compute overall weekly and 5h
    if weekly_mins:
        min_weekly = min(weekly_mins)
        best_w_reset = sorted(weekly_resets)[0] if weekly_resets else None
    else:
        min_weekly = overall_min_rem
        best_w_reset = None

    if five_hour_mins:
        min_five_hour = min(five_hour_mins)
        best_f_reset = sorted(five_hour_resets)[0] if five_hour_resets else None
    else:
        min_five_hour = overall_min_rem
        best_f_reset = overall_next_reset

    final_min_rem = min(overall_min_rem, min_five_hour)
    final_reset = overall_next_reset or best_f_reset

    # Extract specific Claude and Gemini group stats
    claude_group = quota_groups.get("claude", {})
    c_5h_rem = claude_group.get("fiveHourRemaining", families.get("claude", {}).get("remaining", 1.0))
    c_5h_pct = claude_group.get("fiveHourPercent", families.get("claude", {}).get("remainingPercent", 100.0))
    c_5h_rst = claude_group.get("fiveHourResetFormatted", families.get("claude", {}).get("resetFormatted", "充裕"))
    c_w_rem = claude_group.get("weeklyRemaining", 1.0)
    c_w_pct = claude_group.get("weeklyPercent", 100.0)
    c_w_rst = claude_group.get("weeklyResetFormatted", "充裕")

    gemini_group = quota_groups.get("gemini", {})
    g_5h_rem = gemini_group.get("fiveHourRemaining", families.get("gemini_pro", {}).get("remaining", 1.0))
    g_5h_pct = gemini_group.get("fiveHourPercent", families.get("gemini_pro", {}).get("remainingPercent", 100.0))
    g_5h_rst = gemini_group.get("fiveHourResetFormatted", families.get("gemini_pro", {}).get("resetFormatted", "充裕"))
    g_w_rem = gemini_group.get("weeklyRemaining", 1.0)
    g_w_pct = gemini_group.get("weeklyPercent", 100.0)
    g_w_rst = gemini_group.get("weeklyResetFormatted", "充裕")

    return {
        "email": email,
        "tier": tier,
        "claudeFiveHourRemaining": round(c_5h_rem, 4),
        "claudeFiveHourPercent": round(c_5h_pct, 1),
        "claudeFiveHourResetFormatted": c_5h_rst,
        "claudeWeeklyRemaining": round(c_w_rem, 4),
        "claudeWeeklyPercent": round(c_w_pct, 1),
        "claudeWeeklyResetFormatted": c_w_rst,
        "geminiFiveHourRemaining": round(g_5h_rem, 4),
        "geminiFiveHourPercent": round(g_5h_pct, 1),
        "geminiFiveHourResetFormatted": g_5h_rst,
        "geminiWeeklyRemaining": round(g_w_rem, 4),
        "geminiWeeklyPercent": round(g_w_pct, 1),
        "geminiWeeklyResetFormatted": g_w_rst,
        "overallRemaining": round(final_min_rem, 4),
        "overallPercent": round(final_min_rem * 100, 1),
        "overallResetTime": final_reset,
        "overallResetFormatted": format_reset_delta(final_reset, final_min_rem),
        "weeklyRemaining": round(min_weekly, 4),
        "weeklyPercent": round(min_weekly * 100, 1),
        "weeklyResetTime": best_w_reset,
        "weeklyResetFormatted": format_reset_delta(best_w_reset, min_weekly),
        "fiveHourRemaining": round(min_five_hour, 4),
        "fiveHourPercent": round(min_five_hour * 100, 1),
        "fiveHourResetTime": best_f_reset,
        "fiveHourResetFormatted": format_reset_delta(best_f_reset, min_five_hour),
        "quotaGroups": quota_groups,
        "families": families,
        "models": parsed_models,
    }


def sync_omarchy_agent_state(active_account_data: dict[str, Any]) -> None:
    """Sync active account limits into ~/.local/state/omarchy/agents/usage/antigravity.json."""
    ensure_dirs()
    families = active_account_data.get("families", {})

    limits = []
    for f_key in ["claude", "gemini_pro", "gemini_flash", "gpt_oss"]:
        f_info = families.get(f_key)
        if not f_info:
            continue
        remaining = float(f_info.get("remaining", 1.0))
        used_fraction = round(max(0.0, min(1.0, 1.0 - remaining)), 4)
        limits.append({
            "label": f_info.get("name", f_key),
            "title": f_info.get("name", f_key),
            "percent": used_fraction,
            "resetsAt": f_info.get("reset") or "",
        })

    record = {
        "schemaVersion": 1,
        "id": "antigravity",
        "name": "Antigravity",
        "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "ready": True,
        "hasLocalStats": True,
        "hasPromptStats": False,
        "tierLabel": active_account_data.get("tier", "Google AI Pro"),
        "usageStatusText": "",
        "authHelpText": "Antigravity AI usage",
        "limits": limits,
    }

    tmp_fd, tmp_path = tempfile.mkstemp(dir=OMARCHY_AGENT_DIR, prefix=".antigravity-agent-", suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
            json.dump(record, f, indent=2)
            f.write("\n")
        os.chmod(tmp_path, 0o644)
        os.replace(tmp_path, OMARCHY_AGENT_FILE)
    except Exception as e:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        print(f"[warn] Failed to update Omarchy agent state: {e}", file=sys.stderr)


def fetch_all_quotas(force: bool = False, cache_ttl: int = 300) -> dict[str, Any]:
    ensure_dirs()
    now_ts = time.time()

    # Check cache
    if not force and CACHE_FILE.is_file():
        try:
            mtime = CACHE_FILE.stat().st_mtime
            if now_ts - mtime < cache_ttl:
                with open(CACHE_FILE, "r", encoding="utf-8") as f:
                    cached = json.load(f)
                    if isinstance(cached, dict) and "accounts" in cached:
                        return cached
        except Exception:
            pass

    data = load_accounts_data()
    accounts = [a for a in data.get("accounts", []) if a.get("enabled", True)]
    active_email = data.get("activeEmail", "")

    collected_accounts: list[dict[str, Any]] = []

    for acc in accounts:
        acc_email = acc.get("email", "")
        quota_res = collect_account_quota(acc)
        quota_res["isActive"] = (acc_email == active_email)
        collected_accounts.append(quota_res)

    # Save updated access tokens in accounts data
    try:
        save_accounts_data(data)
    except Exception:
        pass

    result = {
        "accounts": collected_accounts,
        "activeEmail": active_email,
        "updatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
    }

    # Find active account to sync with Omarchy agent
    active_res = next((a for a in collected_accounts if a.get("isActive")), None)
    if not active_res and collected_accounts:
        active_res = collected_accounts[0]
    if active_res:
        sync_omarchy_agent_state(active_res)

    # Write cache
    tmp_fd, tmp_path = tempfile.mkstemp(dir=CACHE_DIR, prefix=".quota-", suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
            json.dump(result, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.chmod(tmp_path, 0o644)
        os.replace(tmp_path, CACHE_FILE)
    except Exception as e:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        print(f"[warn] Failed to cache quota: {e}", file=sys.stderr)

    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch Antigravity multi-account quotas")
    parser.add_argument("--json", action="store_true", help="Print structured JSON output")
    parser.add_argument("--force", action="store_true", help="Bypass cache and force fresh fetch")
    parser.add_argument("--cache-ttl", type=int, default=300, help="Cache TTL in seconds (default 300)")

    args = parser.parse_args()
    data = fetch_all_quotas(force=args.force, cache_ttl=args.cache_ttl)

    if args.json:
        print(json.dumps(data, indent=2, ensure_ascii=False))
        return 0

    accounts = data.get("accounts", [])
    print(f"\nAntigravity Multi-Account Quota Overview ({len(accounts)} accounts):")
    print("=" * 80)
    for a in accounts:
        email = a.get("email", "")
        pi_flag = " [Pi Active]" if a.get("isPiActive") else ""
        active_flag = " *" if a.get("isActive") else ""
        print(f"\nAccount: {email}{pi_flag}{active_flag} ({a.get('tier')})")
        print(f"Overall Remaining: {a.get('overallPercent')}% ({a.get('overallResetFormatted')})")
        print("-" * 50)
        families = a.get("families", {})
        for f_key, f_info in families.items():
            bar_len = 20
            rem = f_info.get("remaining", 1.0)
            filled = int(rem * bar_len)
            bar = "[" + "#" * filled + "-" * (bar_len - filled) + "]"
            pct = f_info.get("remainingPercent", 100.0)
            rst = f_info.get("resetFormatted", "")
            print(f"  {f_info.get('name', f_key):<24} {bar} {pct:>5.1f}% ({rst})")
    print("=" * 80 + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
