#!/usr/bin/env python3
"""Antigravity Multi-Account Reverse Proxy Server.

Exposes Anthropic Messages API (/v1/messages) and OpenAI Chat API (/v1/chat/completions)
backed by a pool of Google Antigravity accounts with automatic 429 failover.
"""

from __future__ import annotations

import argparse
import copy
import http.server
import json
import os
from pathlib import Path
import re
import socketserver
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any

# Resolve accounts manager from same directory
SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

try:
    from accounts import (
        load_accounts_data,
        refresh_account_token,
    )
except ImportError:
    from scripts.accounts import (
        load_accounts_data,
        refresh_account_token,
    )

ANTIGRAVITY_BASE_URL = os.environ.get(
    "ANTIGRAVITY_BASE_URL", "https://daily-cloudcode-pa.googleapis.com"
)
USER_AGENT = (
    "antigravity/cli/1.1.23 (aidev_client; os_type=linux; arch=amd64; cl=974125021; auth_method=consumer)"
)

# Model ID mapping to Antigravity runtime models
MODEL_MAP: dict[str, str] = {
    "gemini-3.8-flash-high": "gemini-3.8-flash-high",
    "gemini-3.8-flash": "gemini-3.8-flash-low",
    "gemini-3.8-flash-low": "gemini-3.8-flash-low",
    "gemini-3.7-flash-high": "gemini-3.7-flash-high",
    "gemini-3.7-flash": "gemini-3.7-flash-low",
    "gemini-3.7-flash-low": "gemini-3.7-flash-low",
    "gemini-3.5-flash-high": "gemini-3-flash-agent",
    "gemini-3.5-flash": "gemini-3.5-flash-low",
    "gemini-3.1-pro-high": "gemini-pro-agent",
    "gemini-3.1-pro": "gemini-3.1-pro-low",
    "claude-sonnet-4-6": "claude-sonnet-4-6",
    "claude-opus-4-6": "claude-opus-4-6-thinking",
    "gpt-oss-120b": "gpt-oss-120b-medium",
}

DEFAULT_THINKING_BUDGETS: dict[str, int] = {
    "gemini-3.8-flash-high": 16000,
    "gemini-3.7-flash-high": 16000,
    "gemini-3-flash-agent": 10000,
    "claude-sonnet-4-6": 1024,
    "claude-opus-4-6-thinking": 8192,
    "gpt-oss-120b-medium": 8192,
}


class AccountPool:
    """Manages rotation, cooldowns, and automatic failover across accounts."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.cooldowns: dict[str, float] = {}  # email -> timestamp
        self.fail_counts: dict[str, int] = {}
        self.success_counts: dict[str, int] = {}
        self.current_index = 0

    def get_candidate_accounts(self) -> list[dict[str, Any]]:
        with self.lock:
            data = load_accounts_data()
            accounts = [a for a in data.get("accounts", []) if a.get("enabled", True)]
            if not accounts:
                return []

            active_email = data.get("activeEmail", "")
            strategy = data.get("proxyStrategy", "priority")  # "priority" or "round-robin"
            now = time.time()

            # Partition into available (not cooling down) and cooling down
            available = []
            cooling = []
            for acc in accounts:
                email = acc.get("email", "")
                cool_until = self.cooldowns.get(email, 0)
                if cool_until <= now:
                    available.append(acc)
                else:
                    cooling.append((cool_until, acc))

            cooling.sort(key=lambda x: x[0])
            cooling_accs = [acc for _, acc in cooling]

            if strategy == "round-robin" and available:
                idx = self.current_index % len(available)
                self.current_index = (self.current_index + 1) % len(available)
                sorted_available = available[idx:] + available[:idx]
            else:
                # In priority mode: activeEmail first, then others
                if active_email:
                    available_active = [a for a in available if a.get("email") == active_email]
                    available_others = [a for a in available if a.get("email") != active_email]
                    sorted_available = available_active + available_others
                else:
                    sorted_available = available

            return sorted_available + cooling_accs

    def mark_429(self, email: str, retry_delay: float = 300.0) -> None:
        with self.lock:
            cooldown_time = time.time() + max(30.0, retry_delay)
            self.cooldowns[email] = cooldown_time
            self.fail_counts[email] = self.fail_counts.get(email, 0) + 1
            print(
                f"[AccountPool] Account {email} rate-limited (429). Cooldown for {int(retry_delay)}s.",
                file=sys.stderr,
            )

    def mark_success(self, email: str) -> None:
        with self.lock:
            self.cooldowns.pop(email, None)
            self.success_counts[email] = self.success_counts.get(email, 0) + 1

    def status(self) -> dict[str, Any]:
        with self.lock:
            data = load_accounts_data()
            now = time.time()
            res = []
            for acc in data.get("accounts", []):
                email = acc.get("email", "")
                cool_until = self.cooldowns.get(email, 0)
                res.append({
                    "email": email,
                    "enabled": acc.get("enabled", True),
                    "isActive": email == data.get("activeEmail"),
                    "coolingDown": cool_until > now,
                    "cooldownRemainingSec": max(0, int(cool_until - now)),
                    "successCount": self.success_counts.get(email, 0),
                    "failCount": self.fail_counts.get(email, 0),
                })
            return {"activeEmail": data.get("activeEmail"), "accounts": res}


pool = AccountPool()


META_SCHEMA_KEYWORDS = {
    "$schema",
    "$id",
    "$anchor",
    "$dynamicAnchor",
    "$vocabulary",
    "$comment",
    "$defs",
    "definitions",
}

CUSTOM_TOOL_SCHEMA_ALLOW = {
    "type",
    "description",
    "properties",
    "required",
    "items",
    "enum",
}


def strip_meta_schema(schema: Any) -> Any:
    """Remove metadata that Cloud Code Assist rejects from JSON Schema keyword positions."""
    if not isinstance(schema, dict):
        if isinstance(schema, list):
            return [strip_meta_schema(x) for x in schema]
        return schema

    out: dict[str, Any] = {}
    for k, v in schema.items():
        if k in META_SCHEMA_KEYWORDS:
            continue
        if k == "const":
            out["enum"] = [v]
            continue
        out[k] = strip_meta_schema(v)
    return out


def normalize_custom_tool_type(value: Any) -> Any:
    if isinstance(value, str):
        return value
    if not isinstance(value, list):
        return None
    for entry in value:
        if isinstance(entry, str) and entry != "null":
            return entry
    return None


def normalize_custom_tool_schema(schema: Any) -> Any:
    """Protobuf Schema filter for Cloud Code Claude / GPT-OSS custom tool bridge."""
    if not isinstance(schema, dict):
        if isinstance(schema, list):
            return [normalize_custom_tool_schema(x) for x in schema]
        return schema

    out: dict[str, Any] = {}
    for k, v in schema.items():
        if k not in CUSTOM_TOOL_SCHEMA_ALLOW:
            continue
        if k == "type":
            t = normalize_custom_tool_type(v)
            if t is not None:
                out["type"] = t
            continue
        if k == "properties" and isinstance(v, dict):
            out["properties"] = {
                prop_k: normalize_custom_tool_schema(prop_v)
                for prop_k, prop_v in v.items()
            }
            continue
        if k == "enum" and isinstance(v, list):
            if not all(isinstance(x, str) for x in v):
                continue
        out[k] = normalize_custom_tool_schema(v)
    return out


THOUGHT_SIGNATURE_CACHE: dict[str, str] = {}


def remember_thought_signature(call_id: str, sig: str) -> None:
    if not call_id or not sig:
        return
    if len(THOUGHT_SIGNATURE_CACHE) > 500:
        for k in list(THOUGHT_SIGNATURE_CACHE.keys())[:100]:
            THOUGHT_SIGNATURE_CACHE.pop(k, None)
    THOUGHT_SIGNATURE_CACHE[call_id] = sig


def gemini_requires_thought_signature(runtime_model: str) -> bool:
    if not runtime_model.startswith("gemini-"):
        return False
    m = re.match(r"^gemini-(\d+)", runtime_model)
    if m:
        return int(m.group(1)) >= 3
    return True


def convert_anthropic_to_gemini(data: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    """Convert Anthropic /v1/messages payload to Antigravity format."""
    raw_model = data.get("model", "gemini-3.8-flash-high")
    runtime_model = MODEL_MAP.get(raw_model, raw_model)

    contents: list[dict[str, Any]] = []
    tool_id_to_name: dict[str, str] = {}
    requires_sig = gemini_requires_thought_signature(runtime_model)
    dropped_tool_call_ids: dict[str, dict[str, Any]] = {}

    # 1. System instruction
    system_instruction = None
    sys_field = data.get("system")
    if sys_field:
        if isinstance(sys_field, str):
            system_instruction = {"parts": [{"text": sys_field}]}
        elif isinstance(sys_field, list):
            texts = [b.get("text", "") for b in sys_field if isinstance(b, dict) and b.get("text")]
            if texts:
                system_instruction = {"parts": [{"text": "\n\n".join(texts)}]}

    # 2. Messages
    for msg in data.get("messages", []):
        role = msg.get("role", "user")
        gemini_role = "model" if role == "assistant" else "user"
        content = msg.get("content")
        parts: list[dict[str, Any]] = []

        if isinstance(content, str):
            if content.strip():
                parts.append({"text": content})
        elif isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                btype = block.get("type")
                if btype == "text":
                    t = block.get("text", "")
                    if t:
                        parts.append({"text": t})
                elif btype == "image":
                    src = block.get("source", {})
                    img_data = block.get("data") or src.get("data", "")
                    media_type = block.get("mimeType") or src.get("media_type", "image/png")
                    if img_data:
                        parts.append({"inlineData": {"mimeType": media_type, "data": img_data}})
                elif btype == "tool_use":
                    call_id = block.get("id", "")
                    call_name = block.get("name", "")
                    call_args = block.get("input") or {}
                    if call_id and call_name:
                        tool_id_to_name[call_id] = call_name

                    sig = (
                        block.get("thoughtSignature")
                        or THOUGHT_SIGNATURE_CACHE.get(call_id)
                    )
                    if requires_sig and not sig:
                        # Gemini 3+ rejects unsigned functionCall parts with 400 INVALID_ARGUMENT.
                        # Drop from model turn and convert subsequent tool_result into user Observation.
                        dropped_tool_call_ids[call_id] = {
                            "name": call_name,
                            "args": call_args,
                        }
                    else:
                        fc_part: dict[str, Any] = {
                            "functionCall": {
                                "name": call_name,
                                "id": call_id,
                                "args": call_args,
                            }
                        }
                        if sig:
                            fc_part["thoughtSignature"] = sig
                        parts.append(fc_part)
                elif btype == "tool_result":
                    tool_id = block.get("tool_use_id", "")
                    tool_name = tool_id_to_name.get(tool_id, "tool")
                    raw_res = block.get("content", "")
                    is_err = block.get("is_error", False)

                    text_pieces: list[str] = []
                    image_parts: list[dict[str, Any]] = []

                    if isinstance(raw_res, list):
                        for b in raw_res:
                            if not isinstance(b, dict):
                                continue
                            if b.get("type") == "text":
                                t = b.get("text", "")
                                if t:
                                    text_pieces.append(t)
                            elif b.get("type") == "image":
                                img_data = b.get("data") or b.get("source", {}).get("data", "")
                                mime = b.get("mimeType") or b.get("source", {}).get("media_type", "image/png")
                                if img_data:
                                    image_parts.append({"inlineData": {"mimeType": mime, "data": img_data}})
                    elif isinstance(raw_res, str):
                        if raw_res:
                            text_pieces.append(raw_res)
                    elif raw_res is not None:
                        text_pieces.append(str(raw_res))

                    res_str = "\n".join(text_pieces)
                    if not res_str and is_err:
                        res_str = "Tool failed"

                    if tool_id in dropped_tool_call_ids:
                        info = dropped_tool_call_ids[tool_id]
                        name = info.get("name") or tool_name
                        args_val = info.get("args", {})
                        args_str = json.dumps(args_val) if args_val else ""
                        label = f"`{name}` ({args_str})" if args_str and args_str != "{}" else f"`{name}`"
                        obs_text = f"[Observation from {label}:\n{res_str}]" if res_str else f"[Observation from {label}]"
                        parts.append({"text": obs_text})
                    else:
                        resp_content = {"error": res_str} if is_err else {"output": res_str}
                        parts.append({
                            "functionResponse": {
                                "name": tool_name,
                                "id": tool_id,
                                "response": resp_content,
                            }
                        })
                    parts.extend(image_parts)

        if parts:
            # Merge adjacent turns with same role
            if contents and contents[-1]["role"] == gemini_role:
                contents[-1]["parts"].extend(parts)
            else:
                contents.append({"role": gemini_role, "parts": parts})

    # 3. Generation Config
    gen_config: dict[str, Any] = {}
    if "max_tokens" in data:
        gen_config["maxOutputTokens"] = data["max_tokens"]
    if "temperature" in data:
        gen_config["temperature"] = data["temperature"]
    if "top_p" in data:
        gen_config["topP"] = data["top_p"]

    thinking_req = data.get("thinking")
    max_out = gen_config.get("maxOutputTokens", 8192)
    if isinstance(thinking_req, dict) and thinking_req.get("type") == "enabled":
        budget = thinking_req.get("budget_tokens") or DEFAULT_THINKING_BUDGETS.get(runtime_model, 4000)
        safe_budget = max(100, min(budget, max_out - 200)) if max_out > 300 else 100
        gen_config["thinkingConfig"] = {"thinkingBudget": safe_budget, "includeThoughts": True}
    elif runtime_model in DEFAULT_THINKING_BUDGETS and runtime_model.endswith("-high"):
        budget = DEFAULT_THINKING_BUDGETS[runtime_model]
        safe_budget = max(100, min(budget, max_out - 200)) if max_out > 300 else 100
        gen_config["thinkingConfig"] = {
            "thinkingBudget": safe_budget,
            "includeThoughts": True,
        }

    # 4. Tools
    tools_payload = None
    anthropic_tools = data.get("tools", [])
    if anthropic_tools and isinstance(anthropic_tools, list):
        is_legacy_parameters = (
            runtime_model.startswith("claude-")
            or runtime_model.startswith("gpt-oss-")
        )
        func_decls = []
        for t in anthropic_tools:
            if not isinstance(t, dict):
                continue
            raw_schema = t.get("input_schema") or {}
            decl: dict[str, Any] = {
                "name": t.get("name"),
                "description": t.get("description", ""),
            }
            if is_legacy_parameters:
                decl["parameters"] = normalize_custom_tool_schema(raw_schema)
            else:
                decl["parametersJsonSchema"] = strip_meta_schema(raw_schema)
            func_decls.append(decl)
        if func_decls:
            tools_payload = [{"functionDeclarations": func_decls}]

    req_inner: dict[str, Any] = {"contents": contents}
    if gen_config:
        req_inner["generationConfig"] = gen_config
    if system_instruction:
        req_inner["systemInstruction"] = system_instruction
    if tools_payload:
        req_inner["tools"] = tools_payload

    # Align with pi-antigravity pure CLI wire envelope
    agent_id = str(uuid.uuid4())
    trajectory_id = str(uuid.uuid4())
    step = max(1, len(contents))
    now = int(time.time() * 1000)
    request_id = f"agent/{agent_id}/{now}/{trajectory_id}/{step}"
    session_id = str(int.from_bytes(os.urandom(8), "little", signed=True))

    is_claude = runtime_model.startswith("claude-")
    is_non_gemini = is_claude or runtime_model.startswith("gpt-oss-")

    req_inner["sessionId"] = session_id
    req_inner["labels"] = {
        "last_step_index": str(max(0, step - 1)),
        "request_id": f"{trajectory_id}-{max(0, step - 1)}",
        "trajectory_id": trajectory_id,
        "used_claude": "true" if is_claude else "false",
        "used_claude_conservative": "true" if is_claude else "false",
        "used_non_gemini_model": "true" if is_non_gemini else "false",
    }

    envelope = {
        "project": "aicode-consumers",
        "model": runtime_model,
        "request": req_inner,
        "requestType": "agent",
        "userAgent": "antigravity",
        "requestId": request_id,
    }
    return runtime_model, envelope


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def send_json(self, status_code: int, data: Any) -> None:
        payload = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def do_GET(self) -> None:
        url_path = self.path.split("?")[0]
        norm_path = re.sub(r"^(?:/v1)+", "/v1", url_path).rstrip("/")

        if norm_path in ("/", "/health", "/status", "health", "status"):
            status = {
                "status": "ok",
                "service": "Antigravity Multi-Account Proxy",
                "pool": pool.status(),
            }
            self.send_json(200, status)
            return

        if norm_path in ("/v1/models", "/models", "models"):
            models_list = [
                {"id": k, "object": "model", "owned_by": "antigravity"}
                for k in MODEL_MAP.keys()
            ]
            self.send_json(200, {"data": models_list, "object": "list"})
            return

        if norm_path.startswith("/v1/models/") or norm_path.startswith("/models/"):
            mid = norm_path.split("/")[-1]
            self.send_json(200, {"id": mid, "object": "model", "owned_by": "antigravity"})
            return

        self.send_error(404, "Not Found")

    def do_POST(self) -> None:
        url_path = self.path.split("?")[0]
        norm_path = re.sub(r"^(?:/v1)+", "/v1", url_path).rstrip("/")
        if norm_path in ("/v1/messages", "/messages"):
            self.handle_anthropic_messages()
            return

        self.send_error(404, "Endpoint not supported")

    def handle_anthropic_messages(self) -> None:
        content_length = int(self.headers.get("Content-Length", 0))
        body_bytes = self.rfile.read(content_length)
        try:
            req_data = json.loads(body_bytes.decode("utf-8"))
        except Exception as e:
            self.send_error(400, f"Invalid JSON: {e}")
            return

        stream = req_data.get("stream", False)
        runtime_model, google_envelope = convert_anthropic_to_gemini(req_data)

        # Attempt through accounts with automatic 429 failover
        candidate_accounts = pool.get_candidate_accounts()
        if not candidate_accounts:
            self.send_error(503, "No enabled Antigravity accounts configured")
            return

        last_error_code = 500
        last_error_text = "All accounts failed"

        for acc in candidate_accounts:
            email = acc.get("email", "")
            try:
                access_token = refresh_account_token(acc)
            except Exception as e:
                print(f"[Proxy] Failed refreshing token for {email}: {e}", file=sys.stderr)
                continue

            google_envelope["project"] = acc.get("projectId") or "aicode-consumers"
            upstream_url = f"{ANTIGRAVITY_BASE_URL}/v1internal:streamGenerateContent?alt=sse"

            headers = {
                "Authorization": f"Bearer {access_token}",
                "Content-Type": "application/json",
                "User-Agent": USER_AGENT,
            }

            req = urllib.request.Request(
                upstream_url,
                data=json.dumps(google_envelope).encode("utf-8"),
                headers=headers,
                method="POST",
            )

            try:
                upstream_resp = urllib.request.urlopen(req, timeout=120)
            except urllib.error.HTTPError as e:
                err_text = e.read().decode("utf-8", errors="replace")
                print(f"[Proxy] Upstream HTTP {e.code} for {email}: {err_text[:300]}", file=sys.stderr)
                last_error_code = e.code
                last_error_text = err_text

                if e.code == 429:
                    # Parse retryDelay if present
                    retry_delay = 300.0
                    try:
                        err_json = json.loads(err_text)
                        for d in err_json.get("error", {}).get("details", []):
                            if "retryDelay" in d:
                                dur_str = d["retryDelay"].rstrip("s")
                                retry_delay = float(dur_str)
                    except Exception:
                        pass
                    pool.mark_429(email, retry_delay)
                    continue  # Try next account!
                elif e.code in (401, 403):
                    pool.mark_429(email, 60.0)
                    continue
                else:
                    break  # Client payload error, stop retrying
            except Exception as e:
                print(f"[Proxy] Connection error for {email}: {e}", file=sys.stderr)
                last_error_text = str(e)
                continue

            # If we reached here, upstream accepted the request!
            pool.mark_success(email)
            self.relay_anthropic_response(upstream_resp, stream, req_data.get("model", runtime_model))
            return

        # If all candidates failed:
        err_msg = {
            "type": "error",
            "error": {
                "type": "rate_limit_error" if last_error_code == 429 else "api_error",
                "message": f"Proxy upstream error ({last_error_code}): {last_error_text}",
            },
        }
        self.send_json(last_error_code, err_msg)

    def relay_anthropic_response(
        self, upstream_resp: Any, is_stream: bool, requested_model: str
    ) -> None:
        """Translate Google SSE stream to Anthropic format (SSE or JSON)."""
        msg_id = f"msg_{uuid.uuid4().hex[:24]}"

        if is_stream:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()

            def send_event(event_type: str, data: dict[str, Any]) -> None:
                payload = f"event: {event_type}\ndata: {json.dumps(data)}\n\n".encode("utf-8")
                self.wfile.write(payload)
                self.wfile.flush()

            # 1. message_start
            send_event(
                "message_start",
                {
                    "type": "message_start",
                    "message": {
                        "id": msg_id,
                        "type": "message",
                        "role": "assistant",
                        "content": [],
                        "model": requested_model,
                        "stop_reason": None,
                        "stop_sequence": None,
                        "usage": {"input_tokens": 0, "output_tokens": 0},
                    },
                },
            )

            current_block_type: str | None = None
            current_block_index = -1
            tool_calls_count = 0
            stop_reason = "end_turn"
            output_tokens = 0

            def close_current_block() -> None:
                nonlocal current_block_type
                if current_block_type is not None:
                    send_event("content_block_stop", {"type": "content_block_stop", "index": current_block_index})
                    current_block_type = None

            for line_bytes in upstream_resp:
                line = line_bytes.decode("utf-8", errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                data_str = line[5:].strip()
                if not data_str or data_str == "[DONE]":
                    continue

                try:
                    chunk = json.loads(data_str)
                except Exception:
                    continue

                resp_obj = chunk.get("response", chunk)
                usage = resp_obj.get("usageMetadata", {})
                if "candidatesTokenCount" in usage:
                    output_tokens = usage["candidatesTokenCount"]

                candidates = resp_obj.get("candidates", [])
                if not candidates:
                    continue
                cand = candidates[0]
                finish_reason = cand.get("finishReason")
                if finish_reason == "MAX_TOKENS":
                    stop_reason = "max_tokens"
                elif finish_reason == "OTHER":
                    stop_reason = "tool_use"

                for part in cand.get("content", {}).get("parts", []):
                    if "functionCall" in part:
                        fc = part["functionCall"]
                        close_current_block()
                        current_block_index += 1
                        tool_calls_count += 1
                        stop_reason = "tool_use"
                        call_id = fc.get("id") or f"toolu_{uuid.uuid4().hex[:20]}"
                        call_name = fc.get("name", "")
                        call_args = fc.get("args") or {}
                        sig = part.get("thoughtSignature")
                        if sig and call_id:
                            remember_thought_signature(call_id, sig)

                        send_event(
                            "content_block_start",
                            {
                                "type": "content_block_start",
                                "index": current_block_index,
                                "content_block": {
                                    "type": "tool_use",
                                    "id": call_id,
                                    "name": call_name,
                                    "input": {},
                                },
                            },
                        )
                        send_event(
                            "content_block_delta",
                            {
                                "type": "content_block_delta",
                                "index": current_block_index,
                                "delta": {
                                    "type": "input_json_delta",
                                    "partial_json": json.dumps(call_args),
                                },
                            },
                        )
                        close_current_block()
                    elif part.get("thought") is True or (part.get("text") and "thoughtSignature" in part):
                        t_text = part.get("text", "")
                        if t_text:
                            if current_block_type != "thinking":
                                close_current_block()
                                current_block_index += 1
                                current_block_type = "thinking"
                                send_event(
                                    "content_block_start",
                                    {
                                        "type": "content_block_start",
                                        "index": current_block_index,
                                        "content_block": {"type": "thinking", "thinking": ""},
                                    },
                                )
                            send_event(
                                "content_block_delta",
                                {
                                    "type": "content_block_delta",
                                    "index": current_block_index,
                                    "delta": {"type": "thinking_delta", "thinking": t_text},
                                },
                            )
                    elif "text" in part:
                        text_val = part.get("text", "")
                        if text_val:
                            if current_block_type != "text":
                                close_current_block()
                                current_block_index += 1
                                current_block_type = "text"
                                send_event(
                                    "content_block_start",
                                    {
                                        "type": "content_block_start",
                                        "index": current_block_index,
                                        "content_block": {"type": "text", "text": ""},
                                    },
                                )
                            send_event(
                                "content_block_delta",
                                {
                                    "type": "content_block_delta",
                                    "index": current_block_index,
                                    "delta": {"type": "text_delta", "text": text_val},
                                },
                            )

            close_current_block()

            # message_delta
            send_event(
                "message_delta",
                {
                    "type": "message_delta",
                    "delta": {"stop_reason": stop_reason, "stop_sequence": None},
                    "usage": {"output_tokens": output_tokens},
                },
            )
            # message_stop
            send_event("message_stop", {"type": "message_stop"})
            self.close_connection = True

        else:
            # Non-streaming response aggregation
            full_text = []
            tool_calls = []
            stop_reason = "end_turn"
            input_tokens = 0
            output_tokens = 0

            for line_bytes in upstream_resp:
                line = line_bytes.decode("utf-8", errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                data_str = line[5:].strip()
                if not data_str or data_str == "[DONE]":
                    continue
                try:
                    chunk = json.loads(data_str)
                except Exception:
                    continue

                resp_obj = chunk.get("response", chunk)
                usage = resp_obj.get("usageMetadata", {})
                if "promptTokenCount" in usage:
                    input_tokens = usage["promptTokenCount"]
                if "candidatesTokenCount" in usage:
                    output_tokens = usage["candidatesTokenCount"]

                for cand in resp_obj.get("candidates", []):
                    if cand.get("finishReason") == "MAX_TOKENS":
                        stop_reason = "max_tokens"
                    elif cand.get("finishReason") == "OTHER":
                        stop_reason = "tool_use"

                    for part in cand.get("content", {}).get("parts", []):
                        if "text" in part and not part.get("thought"):
                            full_text.append(part["text"])
                        elif "functionCall" in part:
                            fc = part["functionCall"]
                            call_id = fc.get("id") or f"toolu_{uuid.uuid4().hex[:20]}"
                            sig = part.get("thoughtSignature")
                            if sig and call_id:
                                remember_thought_signature(call_id, sig)
                            tool_calls.append({
                                "type": "tool_use",
                                "id": call_id,
                                "name": fc.get("name"),
                                "input": fc.get("args") or {},
                            })
                            stop_reason = "tool_use"

            content_blocks = []
            if full_text and "".join(full_text).strip():
                content_blocks.append({"type": "text", "text": "".join(full_text)})
            content_blocks.extend(tool_calls)

            anthropic_resp = {
                "id": msg_id,
                "type": "message",
                "role": "assistant",
                "model": requested_model,
                "content": content_blocks,
                "stop_reason": stop_reason,
                "usage": {"input_tokens": input_tokens, "output_tokens": output_tokens},
            }
            self.send_json(200, anthropic_resp)


class ThreadingServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def run_server(host: str = "127.0.0.1", port: int = 8045) -> None:
    server = ThreadingServer((host, port), ProxyHandler)
    print(f"🚀 Antigravity Multi-Account Proxy listening on http://{host}:{port}")
    print(f"👉 Anthropic endpoint: http://{host}:{port}/v1/messages")
    print(f"📊 Health & status:    http://{host}:{port}/health")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down proxy server...")
        server.shutdown()


def main() -> int:
    parser = argparse.ArgumentParser(description="Antigravity Multi-Account Proxy Server")
    parser.add_argument("--host", default="127.0.0.1", help="Bind host (default: 127.0.0.1)")
    parser.add_argument("--port", "-p", type=int, default=8045, help="Bind port (default: 8045)")
    args = parser.parse_args()

    run_server(args.host, args.port)
    return 0


if __name__ == "__main__":
    sys.exit(main())
