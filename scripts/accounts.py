#!/usr/bin/env python3
"""Antigravity Multi-Account Manager.

Manages multiple Antigravity Google accounts, tokens, and OAuth authorization.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from typing import Any

CONFIG_DIR = Path.home() / ".config" / "omarchy"
ACCOUNTS_FILE = CONFIG_DIR / "antigravity-accounts.json"
PENDING_OAUTH_FILE = CONFIG_DIR / ".antigravity-oauth-pending.json"
PI_AUTH_FILE = Path.home() / ".config" / "pi" / "auth.json"

# Public Antigravity / Google Cloud Code desktop client credentials
CLIENT_ID = os.environ.get("ANTIGRAVITY_CLIENT_ID") or base64.b64decode(
    "MTA3MTAwNjA2MDU5MS10bWhzc2luMmgyMWxjcmUyMzV2dG9sb2poNGc0MDNlc"
    "C5hcHBzLmdvb2dsZXVzZXJjb250ZW50LmNvbQ=="
).decode("ascii")

CLIENT_SECRET = os.environ.get("ANTIGRAVITY_CLIENT_SECRET") or base64.b64decode(
    "R09DU1BYLUs1OEZXUjQ" + "4NkxkTEoxbUxCOHNYQzR6NnFEQWY="
).decode("ascii")
TOKEN_URL = "https://oauth2.googleapis.com/token"
AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
REDIRECT_URI = "http://localhost:51121/oauth-callback"
PORT = 51121
SCOPES = [
    "https://www.googleapis.com/auth/aicode",
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/userinfo.profile",
    "https://www.googleapis.com/auth/cclog",
    "https://www.googleapis.com/auth/experimentsandconfigs",
]


def ensure_config_dir() -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)


def load_accounts_data() -> dict[str, Any]:
    ensure_config_dir()
    data: dict[str, Any] = {"version": 1, "accounts": [], "activeEmail": ""}
    if ACCOUNTS_FILE.is_file():
        try:
            with open(ACCOUNTS_FILE, "r", encoding="utf-8") as f:
                loaded = json.load(f)
                if isinstance(loaded, dict) and "accounts" in loaded:
                    data = loaded
        except Exception as e:
            print(f"[warn] Failed to read accounts file: {e}", file=sys.stderr)

    accounts = data.get("accounts", [])
    if accounts and not data.get("activeEmail"):
        data["activeEmail"] = accounts[0].get("email", "")

    return data


def save_accounts_data(data: dict[str, Any]) -> None:
    ensure_config_dir()
    tmp_fd, tmp_path = tempfile.mkstemp(dir=CONFIG_DIR, prefix=".antigravity-accounts-", suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.chmod(tmp_path, 0o600)
        shutil.move(tmp_path, ACCOUNTS_FILE)
    except Exception:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise


def load_pi_auth() -> dict[str, Any]:
    if PI_AUTH_FILE.is_file():
        try:
            with open(PI_AUTH_FILE, "r", encoding="utf-8") as f:
                loaded = json.load(f)
                if isinstance(loaded, dict):
                    return loaded
        except Exception as e:
            print(f"[warn] Failed to read Pi auth file: {e}", file=sys.stderr)
    return {}


def sync_account_to_pi(account: dict[str, Any]) -> None:
    """Sync the active account's OAuth credentials into ~/.config/pi/auth.json."""
    if not account or not account.get("refreshToken"):
        return

    try:
        refresh_account_token(account)
    except Exception as e:
        print(f"[warn] Token refresh before Pi sync failed: {e}", file=sys.stderr)

    pi_auth = load_pi_auth()
    pi_auth["antigravity"] = {
        "type": "oauth",
        "refresh": account.get("refreshToken", ""),
        "access": account.get("accessToken", ""),
        "expires": account.get("expiresAt", 0),
        "projectId": account.get("projectId") or "aicode-consumers",
        "email": account.get("email", ""),
    }

    PI_AUTH_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp_fd, tmp_path = tempfile.mkstemp(dir=PI_AUTH_FILE.parent, prefix=".pi-auth-", suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
            json.dump(pi_auth, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.chmod(tmp_path, 0o600)
        shutil.move(tmp_path, PI_AUTH_FILE)
    except Exception:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise


def auto_import_pi_account() -> dict[str, Any] | None:
    pi_auth = load_pi_auth()
    agy = pi_auth.get("antigravity")
    if not isinstance(agy, dict):
        return None

    email = agy.get("email")
    refresh_token = agy.get("refresh")
    if not email or not refresh_token:
        return None

    return {
        "email": email,
        "refreshToken": refresh_token,
        "accessToken": agy.get("access", ""),
        "expiresAt": agy.get("expires", 0),
        "projectId": agy.get("projectId") or "aicode-consumers",
        "tier": "Google AI Pro",
        "enabled": True,
    }


def refresh_token(refresh_token_str: str) -> dict[str, Any]:
    """Request a fresh access token from Google OAuth."""
    payload = urllib.parse.urlencode({
        "client_id": CLIENT_ID,
        "client_secret": CLIENT_SECRET,
        "refresh_token": refresh_token_str,
        "grant_type": "refresh_token",
    }).encode("utf-8")

    req = urllib.request.Request(
        TOKEN_URL,
        data=payload,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode("utf-8"))


def refresh_account_token(account: dict[str, Any], force: bool = False) -> str:
    """Ensure account has a valid access token. Refreshes if expired or force=True."""
    now_ms = int(time.time() * 1000)
    expires_at = account.get("expiresAt", 0)
    access_token = account.get("accessToken", "")

    # Refresh if within 5 minutes of expiration or missing
    if not force and access_token and (expires_at - now_ms > 300_000):
        return access_token

    refresh_token_str = account.get("refreshToken", "")
    if not refresh_token_str:
        raise ValueError(f"No refresh token available for {account.get('email')}")

    res = refresh_token(refresh_token_str)
    new_access = res.get("access_token", "")
    expires_in = res.get("expires_in", 3599)
    account["accessToken"] = new_access
    account["expiresAt"] = now_ms + (expires_in * 1000)
    return new_access


def fetch_user_email(access_token: str) -> str:
    """Fetch the authenticated user's email via Google UserInfo API."""
    req = urllib.request.Request(
        "https://www.googleapis.com/oauth2/v1/userinfo?alt=json",
        headers={"Authorization": f"Bearer {access_token}"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        userinfo = json.loads(resp.read().decode("utf-8"))
        return userinfo.get("email", "")


def send_notification(title: str, message: str) -> None:
    if shutil.which("notify-send"):
        try:
            subprocess.run(["notify-send", "-a", "Antigravity", title, message], check=False)
        except Exception:
            pass


def save_pending_oauth(data: dict[str, Any]) -> None:
    try:
        PENDING_OAUTH_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(PENDING_OAUTH_FILE, "w", encoding="utf-8") as f:
            json.dump(data, f)
        os.chmod(PENDING_OAUTH_FILE, 0o600)
    except Exception as e:
        print(f"[warn] Failed to save pending OAuth state: {e}", file=sys.stderr)


def load_pending_oauth() -> dict[str, Any] | None:
    if not PENDING_OAUTH_FILE.exists():
        return None
    try:
        with open(PENDING_OAUTH_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def clear_pending_oauth() -> None:
    try:
        if PENDING_OAUTH_FILE.exists():
            PENDING_OAUTH_FILE.unlink()
    except Exception:
        pass


def free_port(port: int) -> None:
    """Kill any orphaned processes holding the callback port."""
    if shutil.which("fuser"):
        try:
            subprocess.run(["fuser", "-k", f"{port}/tcp"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2)
            time.sleep(0.3)
        except Exception:
            pass


class ReusableHTTPServer(http.server.HTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def cmd_list(args: argparse.Namespace) -> int:
    data = load_accounts_data()
    accounts = data.get("accounts", [])
    active_email = data.get("activeEmail", "")

    now_ms = int(time.time() * 1000)

    if args.json:
        result = {
            "accounts": [
                {
                    "email": a.get("email"),
                    "tier": a.get("tier", "Google AI Pro"),
                    "enabled": a.get("enabled", True),
                    "isActive": a.get("email") == active_email,
                    "expiresInSec": max(0, int((a.get("expiresAt", 0) - now_ms) / 1000)),
                    "projectId": a.get("projectId", "aicode-consumers"),
                }
                for a in accounts
            ],
            "activeEmail": active_email,
        }
        print(json.dumps(result, indent=2))
        return 0

    if not accounts:
        print("No Antigravity accounts configured.")
        return 0

    print(f"\nAntigravity Accounts ({len(accounts)} configured):")
    print("-" * 65)
    print(f"{'Email':<36} {'Tier':<16} {'Status':<12}")
    print("-" * 65)
    for a in accounts:
        email = a.get("email", "")
        tier = a.get("tier", "Google AI Pro")
        is_active = " [Current]" if email == active_email else ""
        expires_at = a.get("expiresAt", 0)
        rem_sec = int((expires_at - now_ms) / 1000)
        status = f"Valid ({rem_sec//60}m)" if rem_sec > 0 else "Expired"
        print(f"{email + is_active:<36} {tier:<16} {status:<12}")
    print("-" * 65 + "\n")
    return 0


def cmd_add(args: argparse.Namespace) -> int:
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).decode("ascii").rstrip("=")
    state = secrets.token_urlsafe(24)

    # Persist pending verifier & state for manual paste fallback or callback retry
    save_pending_oauth({
        "verifier": verifier,
        "state": state,
        "createdAt": int(time.time()),
    })

    params = {
        "client_id": CLIENT_ID,
        "redirect_uri": REDIRECT_URI,
        "response_type": "code",
        "scope": " ".join(SCOPES),
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "access_type": "offline",
        "prompt": "select_account consent",
    }
    auth_link = f"{AUTH_URL}?{urllib.parse.urlencode(params)}"

    if args.manual:
        print("\n=== Manual Google OAuth Login ===")
        print("1. Open the following URL in your browser:\n")
        print(auth_link)
        print("\n2. Authorize the account and copy the redirect URL (or authorization code):")
        try:
            redirect_input = input("Enter code or redirected URL: ").strip()
        except KeyboardInterrupt:
            print("\nCancelled.")
            clear_pending_oauth()
            return 1

        code = redirect_input
        if "code=" in redirect_input:
            parsed = urllib.parse.urlparse(redirect_input)
            query = urllib.parse.parse_qs(parsed.query)
            code = query.get("code", [""])[0]

        if not code:
            print("[error] Invalid code or redirect URL", file=sys.stderr)
            clear_pending_oauth()
            return 1

        ret, _ = exchange_and_save_code(code, verifier)
        clear_pending_oauth()
        return ret

    print(f"\nStarting local OAuth authentication server on port {PORT} ...")
    free_port(PORT)
    server_auth_code = {"code": "", "state": ""}

    class OAuthHandler(http.server.BaseHTTPRequestHandler):
        def log_message(self, format: str, *handler_args: Any) -> None:
            pass  # quiet

        def do_GET(self) -> None:
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path == "/oauth-callback":
                query = urllib.parse.parse_qs(parsed.query)
                code = query.get("code", [""])[0]
                rec_state = query.get("state", [""])[0]
                if code and (not state or rec_state == state):
                    server_auth_code["code"] = code
                    server_auth_code["state"] = rec_state
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.end_headers()
                    self.wfile.write("""<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>Antigravity 授权成功</title>
<style>
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
       display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0;
       background: #121212; color: #fff; text-align: center; }
.card { background: #1e1e1e; padding: 40px; border-radius: 12px; border: 1px solid #333; max-width: 480px; box-shadow: 0 8px 24px rgba(0,0,0,0.5); }
h1 { color: #4CAF50; margin-top: 0; font-size: 24px; }
p { color: #aaa; font-size: 15px; line-height: 1.6; }
</style>
</head>
<body>
<div class="card">
  <h1>✓ Antigravity 授权成功！</h1>
  <p>账号已成功接入 Omarchy 状态栏。</p>
  <p>您可以安全关闭此浏览器标签页并返回桌面。</p>
</div>
</body>
</html>""".encode("utf-8"))
                else:
                    self.send_response(400)
                    self.end_headers()
                    self.wfile.write(b"Authentication failed: invalid state or code")
            else:
                self.send_response(404)
                self.end_headers()

    server: ReusableHTTPServer | None = None
    for bind_host in ["", "127.0.0.1"]:
        try:
            server = ReusableHTTPServer((bind_host, PORT), OAuthHandler)
            server.timeout = 180
            break
        except OSError:
            continue

    if server is None:
        print(f"[warn] Could not bind to port {PORT}. Falling back to manual mode.", file=sys.stderr)
        args.manual = True
        return cmd_add(args)

    print("Opening browser for authorization...")
    opened = False
    for b_cmd in [["xdg-open", auth_link], ["gio", "open", auth_link]]:
        if shutil.which(b_cmd[0]):
            try:
                subprocess.Popen(b_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                opened = True
                break
            except Exception:
                pass
    if not opened:
        webbrowser.open(auth_link)
    print("Waiting for browser callback (timeout: 3 minutes)...")

    while not server_auth_code["code"]:
        server.handle_request()

    code = server_auth_code["code"]
    server.server_close()

    if not code:
        clear_pending_oauth()
        print("[error] Authorization failed or timed out", file=sys.stderr)
        return 1

    ret, _ = exchange_and_save_code(code, verifier)
    clear_pending_oauth()
    return ret


def exchange_and_save_code(code: str, verifier: str) -> tuple[int, str]:
    payload = urllib.parse.urlencode({
        "client_id": CLIENT_ID,
        "client_secret": CLIENT_SECRET,
        "code": code,
        "grant_type": "authorization_code",
        "redirect_uri": REDIRECT_URI,
        "code_verifier": verifier,
    }).encode("utf-8")

    req = urllib.request.Request(
        TOKEN_URL,
        data=payload,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            token_data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        print(f"[error] Failed to exchange code for tokens: {e}", file=sys.stderr)
        return 1, ""

    access_token = token_data.get("access_token", "")
    refresh_token_str = token_data.get("refresh_token", "")
    expires_in = token_data.get("expires_in", 3599)

    if not access_token or not refresh_token_str:
        print("[error] Token response missing access_token or refresh_token", file=sys.stderr)
        return 1, ""

    try:
        email = fetch_user_email(access_token)
    except Exception as e:
        print(f"[warn] Could not fetch user email: {e}", file=sys.stderr)
        email = f"user_{int(time.time())}@gmail.com"

    data = load_accounts_data()
    now_ms = int(time.time() * 1000)

    # Upsert account
    existing = next((a for a in data.get("accounts", []) if a.get("email") == email), None)
    if existing:
        existing["refreshToken"] = refresh_token_str
        existing["accessToken"] = access_token
        existing["expiresAt"] = now_ms + (expires_in * 1000)
        existing["enabled"] = True
        print(f"[ok] Updated existing account: {email}")
    else:
        new_account = {
            "email": email,
            "refreshToken": refresh_token_str,
            "accessToken": access_token,
            "expiresAt": now_ms + (expires_in * 1000),
            "projectId": "aicode-consumers",
            "tier": "Google AI Pro",
            "enabled": True,
        }
        data.setdefault("accounts", []).append(new_account)
        if not data.get("activeEmail"):
            data["activeEmail"] = email
        print(f"[ok] Successfully added new account: {email}")

    save_accounts_data(data)
    send_notification("Antigravity 账号已接入", f"已成功添加账号 {email}")
    return 0, email


def cmd_paste_callback(args: argparse.Namespace) -> int:
    raw_input = args.url_or_code.strip()
    if not raw_input:
        print("[error] URL or code is empty", file=sys.stderr)
        return 1

    code = raw_input
    state_in_url = ""
    if "code=" in raw_input or "http" in raw_input:
        if "?" in raw_input:
            query_str = raw_input.split("?", 1)[1]
        else:
            query_str = raw_input
        parsed = urllib.parse.parse_qs(query_str)
        code = parsed.get("code", [""])[0]
        state_in_url = parsed.get("state", [""])[0]

    if not code:
        print("[error] Could not extract authorization code from input", file=sys.stderr)
        return 1

    pending = load_pending_oauth()
    if not pending or not pending.get("verifier"):
        print("[error] No pending OAuth session found. Please click '打开浏览器授权登录' first.", file=sys.stderr)
        return 1

    verifier = pending["verifier"]
    expected_state = pending.get("state", "")
    if state_in_url and expected_state and state_in_url != expected_state:
        print(f"[warn] OAuth state mismatched (got {state_in_url}, expected {expected_state})", file=sys.stderr)

    ret, email = exchange_and_save_code(code, verifier)
    if ret == 0:
        clear_pending_oauth()
        free_port(PORT)
        print(json.dumps({"ok": True, "email": email}))
        return 0
    return ret


def cmd_cancel_pending(args: argparse.Namespace) -> int:
    clear_pending_oauth()
    free_port(PORT)
    print(json.dumps({"ok": True}))
    return 0


def cmd_add_token(args: argparse.Namespace) -> int:
    email = args.email.strip()
    refresh_token_str = args.refresh_token.strip()
    project_id = args.project_id or "aicode-consumers"
    tier = args.tier or "Google AI Pro"

    print(f"Verifying refresh token for {email}...")
    try:
        res = refresh_token(refresh_token_str)
        access_token = res.get("access_token", "")
        expires_in = res.get("expires_in", 3599)
    except Exception as e:
        print(f"[error] Token verification failed: {e}", file=sys.stderr)
        return 1

    data = load_accounts_data()
    now_ms = int(time.time() * 1000)

    existing = next((a for a in data.get("accounts", []) if a.get("email") == email), None)
    if existing:
        existing["refreshToken"] = refresh_token_str
        existing["accessToken"] = access_token
        existing["expiresAt"] = now_ms + (expires_in * 1000)
        existing["projectId"] = project_id
        existing["tier"] = tier
        existing["enabled"] = True
    else:
        data.setdefault("accounts", []).append({
            "email": email,
            "refreshToken": refresh_token_str,
            "accessToken": access_token,
            "expiresAt": now_ms + (expires_in * 1000),
            "projectId": project_id,
            "tier": tier,
            "enabled": True,
        })
        if not data.get("activeEmail"):
            data["activeEmail"] = email

    save_accounts_data(data)
    print(f"[ok] Successfully saved token for {email}")
    return 0


def cmd_remove(args: argparse.Namespace) -> int:
    email = args.email.strip()
    data = load_accounts_data()
    accounts = data.get("accounts", [])
    before_count = len(accounts)
    data["accounts"] = [a for a in accounts if a.get("email") != email]

    if len(data["accounts"]) == before_count:
        print(f"[error] Account {email} not found", file=sys.stderr)
        return 1

    if data.get("activeEmail") == email:
        data["activeEmail"] = data["accounts"][0]["email"] if data["accounts"] else ""

    save_accounts_data(data)
    print(f"[ok] Removed account: {email}")
    return 0


def cmd_switch(args: argparse.Namespace) -> int:
    email = (args.email or "").strip()
    data = load_accounts_data()
    accounts = data.get("accounts", [])

    if not email:
        if not accounts:
            print("[error] No accounts configured", file=sys.stderr)
            return 1
        omarchy_menu = shutil.which("omarchy-menu-select")
        if omarchy_menu:
            menu_items = []
            for a in accounts:
                em = a.get("email", "")
                tier = a.get("tier", "Google AI Pro")
                is_cur = " [Active]" if em == data.get("activeEmail") else ""
                menu_items.append(f"{em}\t{tier}{is_cur}")
            try:
                proc = subprocess.run(
                    [omarchy_menu, "选择切换的 Antigravity 账号", *menu_items],
                    stdout=subprocess.PIPE,
                    text=True,
                    check=True,
                )
                selected = proc.stdout.strip()
                if not selected:
                    return 0
                email = selected.split("\t")[0].strip()
            except Exception:
                return 0
        else:
            print("[error] Please specify an email to switch", file=sys.stderr)
            return 1

    account = next((a for a in accounts if a.get("email") == email), None)
    if not account:
        print(f"[error] Account {email} not found", file=sys.stderr)
        return 1

    data["activeEmail"] = email
    data["piActiveEmail"] = email
    save_accounts_data(data)

    # Sync to Pi auth.json
    try:
        sync_account_to_pi(account)
    except Exception as e:
        print(f"[warn] Failed to sync to Pi auth: {e}", file=sys.stderr)

    # Sync cache file immediately to prevent old cache from reverting activeEmail
    cache_file = Path.home() / ".cache" / "omarchy" / "agent-usage" / "antigravity-multi-quota.json"
    if cache_file.is_file():
        try:
            with open(cache_file, "r", encoding="utf-8") as f:
                cdata = json.load(f)
            if isinstance(cdata, dict) and "accounts" in cdata:
                cdata["activeEmail"] = email
                active_res = None
                for a in cdata.get("accounts", []):
                    is_act = (a.get("email") == email)
                    a["isActive"] = is_act
                    if is_act:
                        active_res = a
                with open(cache_file, "w", encoding="utf-8") as f:
                    json.dump(cdata, f, indent=2, ensure_ascii=False)

                if active_res:
                    try:
                        from fetch_quota import sync_omarchy_agent_state
                        sync_omarchy_agent_state(active_res)
                    except Exception:
                        pass
        except Exception as e:
            print(f"[warn] Failed to sync cache on switch: {e}", file=sys.stderr)

    send_notification("Antigravity 账号已切换", f"当前活跃: {email} (已同步到 Pi)")
    print(f"[ok] Active account switched to: {email} (synced to Pi)")
    return 0


PID_FILE = CONFIG_DIR / ".antigravity-proxy.pid"
LOG_FILE = Path.home() / ".cache" / "omarchy" / "antigravity-proxy.log"


def is_process_running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def cmd_proxy(args: argparse.Namespace) -> int:
    action = args.action
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)

    if action == "status":
        running = False
        pid = None
        if PID_FILE.is_file():
            try:
                pid = int(PID_FILE.read_text().strip())
                running = is_process_running(pid)
            except Exception:
                pass

        health_data = None
        try:
            with urllib.request.urlopen("http://127.0.0.1:8045/health", timeout=0.5) as resp:
                health_data = json.loads(resp.read())
                running = True
        except Exception:
            if not (pid and running):
                running = False

        if getattr(args, "json", False):
            print(json.dumps({
                "running": running,
                "pid": pid,
                "port": 8045,
                "health": health_data,
            }, indent=2))
            return 0
        else:
            if running:
                print(f"[ok] Proxy running on 127.0.0.1:8045 (PID: {pid})")
            else:
                print("[info] Proxy is not running")
        return 0 if running else 1

    elif action == "stop":
        stopped = False
        if PID_FILE.is_file():
            try:
                pid = int(PID_FILE.read_text().strip())
                if is_process_running(pid):
                    os.kill(pid, 15)
                    time.sleep(0.3)
                    if is_process_running(pid):
                        os.kill(pid, 9)
                    stopped = True
            except Exception:
                pass
            PID_FILE.unlink(missing_ok=True)

        # Fallback: terminate any leftover proxy_server.py
        try:
            for p in Path("/proc").glob("[0-9]*"):
                try:
                    cmdline = (p / "cmdline").read_bytes().replace(b"\x00", b" ").decode()
                    if "proxy_server.py" in cmdline and str(os.getpid()) not in cmdline:
                        os.kill(int(p.name), 9)
                        stopped = True
                except Exception:
                    pass
        except Exception:
            pass

        print("[ok] Proxy stopped")
        return 0

    elif action in ("start", "restart"):
        if action == "restart":
            if PID_FILE.is_file():
                try:
                    pid = int(PID_FILE.read_text().strip())
                    if is_process_running(pid):
                        os.kill(pid, 15)
                        time.sleep(0.5)
                except Exception:
                    pass
                PID_FILE.unlink(missing_ok=True)

        if PID_FILE.is_file():
            try:
                pid = int(PID_FILE.read_text().strip())
                if is_process_running(pid):
                    print(f"[warn] Proxy already running (PID: {pid})")
                    return 0
            except Exception:
                pass

        proxy_script = Path(__file__).resolve().parent / "proxy_server.py"
        log_f = open(LOG_FILE, "a", encoding="utf-8")
        proc = subprocess.Popen(
            [sys.executable, str(proxy_script), "--port", str(args.port), "--host", args.host],
            stdout=log_f,
            stderr=log_f,
            start_new_session=True,
        )
        PID_FILE.write_text(str(proc.pid))
        time.sleep(0.8)

        if is_process_running(proc.pid):
            print(f"[ok] Proxy started on http://{args.host}:{args.port} (PID: {proc.pid})")
            return 0
        else:
            print(f"[error] Proxy failed to start. Check logs at {LOG_FILE}", file=sys.stderr)
            PID_FILE.unlink(missing_ok=True)
            return 1

    return 0


def cmd_toggle(args: argparse.Namespace) -> int:
    email = args.email
    data = load_accounts_data()
    found = False
    new_state = True
    for acc in data.get("accounts", []):
        if acc.get("email") == email:
            current = acc.get("enabled", True)
            new_state = not current
            acc["enabled"] = new_state
            found = True
            break
    if not found:
        print(f"[error] Account not found: {email}", file=sys.stderr)
        return 1
    save_accounts_data(data)
    state_str = "enabled" if new_state else "disabled"
    print(f"[ok] Account {email} is now {state_str}")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    data = load_accounts_data()
    res = {
        "accountCount": len(data.get("accounts", [])),
        "activeEmail": data.get("activeEmail", ""),
    }
    if args.json:
        print(json.dumps(res, indent=2))
    else:
        print(f"Total Accounts:  {res['accountCount']}")
        print(f"Active Account:  {res['activeEmail'] or 'None'}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Antigravity Account Management CLI")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # list
    list_p = subparsers.add_parser("list", help="List all accounts")
    list_p.add_argument("--json", action="store_true", help="Output JSON")

    # add
    add_p = subparsers.add_parser("add", help="Add account via Google OAuth")
    add_p.add_argument("--manual", action="store_true", help="Manual copy-paste flow")

    # add-token
    add_token_p = subparsers.add_parser("add-token", help="Add account via refresh token")
    add_token_p.add_argument("email", help="Account email")
    add_token_p.add_argument("refresh_token", help="Google OAuth refresh token")
    add_token_p.add_argument("--project-id", default="aicode-consumers", help="Project ID")
    add_token_p.add_argument("--tier", default="Google AI Pro", help="Tier label")

    # remove
    rem_p = subparsers.add_parser("remove", help="Remove an account")
    rem_p.add_argument("email", help="Account email to remove")

    # switch
    sw_p = subparsers.add_parser("switch", help="Switch active account")
    sw_p.add_argument("email", nargs="?", default=None, help="Account email (opens menu if omitted)")

    # status
    status_p = subparsers.add_parser("status", help="Show accounts status")
    status_p.add_argument("--json", action="store_true", help="Output JSON")

    # paste-callback
    paste_p = subparsers.add_parser("paste-callback", help="Complete OAuth via pasted redirect URL")
    paste_p.add_argument("url_or_code", help="Redirected URL or auth code")

    # cancel-pending
    cancel_p = subparsers.add_parser("cancel-pending", help="Cancel pending OAuth session and release port")

    # toggle
    toggle_p = subparsers.add_parser("toggle", help="Toggle account enabled/disabled state")
    toggle_p.add_argument("email", help="Account email")

    # proxy
    proxy_p = subparsers.add_parser("proxy", help="Manage background reverse proxy server")
    proxy_p.add_argument("action", choices=["start", "stop", "restart", "status"], help="Action")
    proxy_p.add_argument("--port", type=int, default=8045, help="Port (default: 8045)")
    proxy_p.add_argument("--host", default="127.0.0.1", help="Host (default: 127.0.0.1)")
    proxy_p.add_argument("--json", action="store_true", help="JSON output for status")

    args = parser.parse_args()
    if args.command == "toggle":
        return cmd_toggle(args)
    if args.command == "proxy":
        return cmd_proxy(args)
    if args.command == "list":
        return cmd_list(args)
    if args.command == "add":
        return cmd_add(args)
    if args.command == "paste-callback":
        return cmd_paste_callback(args)
    if args.command == "cancel-pending":
        return cmd_cancel_pending(args)
    if args.command == "add-token":
        return cmd_add_token(args)
    if args.command == "remove":
        return cmd_remove(args)
    if args.command == "switch":
        return cmd_switch(args)
    if args.command == "status":
        return cmd_status(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
