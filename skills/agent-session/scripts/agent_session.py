#!/usr/bin/env python3
"""agent-session: persistent multi-turn LLM session abstraction over heterogeneous backend CLIs.

Verbs: doctor, list-backends, describe, spawn, send, status, output, cleanup.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from abc import ABC, abstractmethod
from contextlib import contextmanager
from pathlib import Path
from typing import Optional


# ============================================================
# State
# ============================================================

DEFAULT_STATE_DIR = Path.home() / ".cache" / "agent-session"
DEFAULT_TIMEOUT = 600  # seconds


def state_root(state_dir: Optional[str]) -> Path:
    return Path(state_dir) if state_dir else DEFAULT_STATE_DIR


def session_dir(role_id: str, state_dir: Optional[str]) -> Path:
    return state_root(state_dir) / role_id


def read_meta(role_id: str, state_dir: Optional[str]) -> Optional[dict]:
    p = session_dir(role_id, state_dir) / "meta.json"
    if not p.exists():
        return None
    return json.loads(p.read_text())


def write_meta(role_id: str, state_dir: Optional[str], meta: dict) -> None:
    d = session_dir(role_id, state_dir)
    d.mkdir(parents=True, exist_ok=True)
    (d / "meta.json").write_text(json.dumps(meta, indent=2))


def append_log(role_id: str, state_dir: Optional[str], msg: str) -> None:
    d = session_dir(role_id, state_dir)
    d.mkdir(parents=True, exist_ok=True)
    with (d / "log").open("a") as f:
        f.write(f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] {msg}\n")


@contextmanager
def lock(role_id: str, state_dir: Optional[str]):
    """fail-fast lock; rejects concurrent operations on the same role-id."""
    d = session_dir(role_id, state_dir)
    d.mkdir(parents=True, exist_ok=True)
    lf = d / ".lock"
    if lf.exists():
        raise RuntimeError(f"role busy: {role_id} (lock at {lf})")
    lf.write_text(str(os.getpid()))
    try:
        yield
    finally:
        lf.unlink(missing_ok=True)


# ============================================================
# Driver interface
# ============================================================


class Driver(ABC):
    name: str
    family: str  # anthropic | openai | google | local | unknown

    @classmethod
    @abstractmethod
    def detect(cls) -> Optional[str]:
        """Return path to the backend CLI if available, else None."""

    @abstractmethod
    def spawn(
        self,
        role_id: str,
        prompt_file: str,
        model: Optional[str],
        state_dir: Optional[str],
        system_prompt: Optional[str],
    ) -> None: ...

    @abstractmethod
    def send(self, role_id: str, prompt_file: str, state_dir: Optional[str]) -> None: ...

    @abstractmethod
    def status(
        self,
        role_id: str,
        state_dir: Optional[str],
        wait: bool,
        timeout: Optional[int],
    ) -> str: ...

    @abstractmethod
    def cleanup(self, role_id: str, state_dir: Optional[str]) -> None: ...


# ============================================================
# Claude driver
# ============================================================


class ClaudeDriver(Driver):
    name = "claude"
    family = "anthropic"

    @classmethod
    def detect(cls) -> Optional[str]:
        return shutil.which("claude")

    def spawn(self, role_id, prompt_file, model, state_dir, system_prompt):
        sd = session_dir(role_id, state_dir)
        (sd / "input").mkdir(parents=True, exist_ok=True)
        (sd / "output").mkdir(parents=True, exist_ok=True)

        sid = str(uuid.uuid4())

        r0_in = sd / "input" / "r0.md"
        shutil.copy(prompt_file, r0_in)

        cmd = ["claude", "-p", "--session-id", sid]
        if model:
            cmd += ["--model", model]
        if system_prompt:
            cmd += ["--system-prompt", system_prompt]

        meta = {
            "backend": "claude",
            "family": "anthropic",
            "model": model or "default",
            "sid": sid,
            "round_count": 0,
            "state": "spawning",
            "system_prompt": system_prompt,
        }
        write_meta(role_id, state_dir, meta)

        with r0_in.open() as f:
            result = subprocess.run(
                cmd, stdin=f, capture_output=True, text=True, timeout=DEFAULT_TIMEOUT
            )

        (sd / "output" / "r0.txt").write_text(result.stdout)
        if result.returncode != 0:
            append_log(role_id, state_dir, f"spawn rc={result.returncode}\nstderr:\n{result.stderr}")
            meta["state"] = "failed"
            write_meta(role_id, state_dir, meta)
            raise RuntimeError(f"claude spawn failed (rc={result.returncode}): {result.stderr.strip()}")

        meta["round_count"] = 1
        meta["state"] = "active"
        write_meta(role_id, state_dir, meta)

    def send(self, role_id, prompt_file, state_dir):
        sd = session_dir(role_id, state_dir)
        meta = read_meta(role_id, state_dir)
        if not meta:
            raise RuntimeError(f"session not found: {role_id}")
        if meta["state"] != "active":
            raise RuntimeError(f"session not active: {role_id} (state={meta['state']})")

        n = meta["round_count"]  # next round index
        rN_in = sd / "input" / f"r{n}.md"
        shutil.copy(prompt_file, rN_in)

        cmd = ["claude", "-p", "--resume", meta["sid"]]
        if meta.get("model") and meta["model"] != "default":
            cmd += ["--model", meta["model"]]

        with rN_in.open() as f:
            result = subprocess.run(
                cmd, stdin=f, capture_output=True, text=True, timeout=DEFAULT_TIMEOUT
            )

        (sd / "output" / f"r{n}.txt").write_text(result.stdout)
        if result.returncode != 0:
            append_log(role_id, state_dir, f"send r{n} rc={result.returncode}\nstderr:\n{result.stderr}")
            meta["state"] = "error"
            write_meta(role_id, state_dir, meta)
            raise RuntimeError(f"claude send failed (rc={result.returncode}): {result.stderr.strip()}")

        meta["round_count"] = n + 1
        write_meta(role_id, state_dir, meta)

    def status(self, role_id, state_dir, wait, timeout):
        # Claude driver runs synchronously in spawn/send, so status reflects last completed call.
        meta = read_meta(role_id, state_dir)
        if not meta:
            return "error"
        return {"spawning": "running", "active": "done", "failed": "error", "error": "error"}.get(
            meta["state"], "error"
        )

    def cleanup(self, role_id, state_dir):
        sd = session_dir(role_id, state_dir)
        if not sd.exists():
            return
        meta = read_meta(role_id, state_dir)
        if meta and meta.get("sid"):
            sid = meta["sid"]
            projects = Path.home() / ".claude" / "projects"
            if projects.exists():
                for f in projects.rglob(f"{sid}.jsonl"):
                    f.unlink(missing_ok=True)
                for d in projects.rglob(sid):
                    if d.is_dir():
                        shutil.rmtree(d, ignore_errors=True)
        shutil.rmtree(sd, ignore_errors=True)


# ============================================================
# Opencode driver
# ============================================================


class OpencodeDriver(Driver):
    name = "opencode"
    family = "openai"  # default; opencode is multi-provider but most users run GPT

    @classmethod
    def detect(cls) -> Optional[str]:
        # oc-task is the canonical wrapper; raw `opencode` CLI alone isn't enough for sessions.
        path = shutil.which("oc-task")
        if path:
            return path
        # Common install path
        fallback = Path.home() / "workspace" / ".pai" / "skills" / "opencode" / "bin" / "oc-task"
        return str(fallback) if fallback.exists() else None

    def _oc_task(self) -> str:
        path = self.detect()
        if not path:
            raise RuntimeError("oc-task not found; install opencode skill")
        return path

    def _ensure_daemon(self, role_id: str, state_dir: Optional[str], cwd: str) -> dict:
        """Ensure a daemon is running for this role. Stores port/id in meta."""
        meta = read_meta(role_id, state_dir) or {}
        if meta.get("oc_task_port"):
            return meta  # daemon already running

        oc = self._oc_task()
        # `oc-task begin` outputs `export OC_TASK_ID=... ; export OC_TASK_PORT=...`
        result = subprocess.run(
            [oc, "begin", "--yolo", "--cwd", cwd, "--title", f"agent-session-{role_id}"],
            capture_output=True,
            text=True,
            timeout=60,
        )
        if result.returncode != 0:
            raise RuntimeError(f"oc-task begin failed: {result.stderr.strip()}")

        # `oc-task begin` may emit either:
        #   export OC_TASK_ID=... OC_TASK_PORT=...        (one line, multiple pairs)
        #   export OC_TASK_ID=...\nexport OC_TASK_PORT=... (multiple lines)
        # Capture every KEY=VALUE token regardless.
        env: dict[str, str] = {}
        for k, v in re.findall(r"(\w+)=(\S+)", result.stdout):
            env[k] = v.strip('"').strip("'")

        meta["oc_task_id"] = env.get("OC_TASK_ID")
        meta["oc_task_port"] = env.get("OC_TASK_PORT")
        if not (meta["oc_task_id"] and meta["oc_task_port"]):
            raise RuntimeError(f"oc-task begin returned unexpected output:\n{result.stdout}")
        return meta

    def _fetch_message(self, port: str, sid: str) -> str:
        """GET /session/<sid>/message and extract latest assistant text."""
        import urllib.request

        url = f"http://127.0.0.1:{port}/session/{sid}/message"
        with urllib.request.urlopen(url, timeout=30) as resp:
            data = json.loads(resp.read())
        assistant = [m for m in data if m.get("info", {}).get("role") == "assistant"]
        if not assistant:
            return ""
        parts = assistant[-1].get("parts", [])
        return "".join(p.get("text", "") for p in parts if p.get("type") == "text")

    def spawn(self, role_id, prompt_file, model, state_dir, system_prompt):
        sd = session_dir(role_id, state_dir)
        (sd / "input").mkdir(parents=True, exist_ok=True)
        (sd / "output").mkdir(parents=True, exist_ok=True)

        # Build the actual prompt (prepend system_prompt if given; opencode has no separate flag)
        r0_in = sd / "input" / "r0.md"
        prompt_content = Path(prompt_file).read_text()
        if system_prompt:
            r0_in.write_text(f"<system>\n{system_prompt}\n</system>\n\n{prompt_content}")
        else:
            r0_in.write_text(prompt_content)

        meta = {
            "backend": "opencode",
            "family": "openai",
            "model": model or "default",
            "sid": None,
            "round_count": 0,
            "state": "spawning",
            "system_prompt": system_prompt,
        }
        write_meta(role_id, state_dir, meta)

        cwd = os.environ.get("OC_TASK_CWD", os.getcwd())
        meta = self._ensure_daemon(role_id, state_dir, cwd)
        # carry forward meta values set by _ensure_daemon
        meta.setdefault("backend", "opencode")
        meta.setdefault("family", "openai")
        meta.setdefault("model", model or "default")
        meta.setdefault("round_count", 0)
        meta["state"] = "spawning"
        write_meta(role_id, state_dir, meta)

        oc = self._oc_task()
        env = os.environ.copy()
        env["OC_TASK_ID"] = meta["oc_task_id"]
        env["OC_TASK_PORT"] = meta["oc_task_port"]

        spawn_res = subprocess.run(
            [oc, "spawn", str(r0_in), "--agent", "autoaccept"],
            capture_output=True,
            text=True,
            env=env,
            timeout=DEFAULT_TIMEOUT,
        )
        if spawn_res.returncode != 0:
            append_log(role_id, state_dir, f"spawn rc={spawn_res.returncode}\nstderr:\n{spawn_res.stderr}")
            meta["state"] = "failed"
            write_meta(role_id, state_dir, meta)
            raise RuntimeError(f"oc-task spawn failed: {spawn_res.stderr.strip()}")

        opencode_sid = spawn_res.stdout.strip()
        meta["sid"] = opencode_sid
        write_meta(role_id, state_dir, meta)

        # Wait for completion
        wait_res = subprocess.run(
            [oc, "status", opencode_sid, "--wait", "--timeout", "1800", "--no-text"],
            capture_output=True,
            text=True,
            env=env,
            timeout=1800,
        )
        if wait_res.returncode != 0:
            append_log(role_id, state_dir, f"status wait rc={wait_res.returncode}\nstderr:\n{wait_res.stderr}")
            meta["state"] = "error"
            write_meta(role_id, state_dir, meta)
            raise RuntimeError(f"oc-task status wait failed: {wait_res.stderr.strip()}")

        text = self._fetch_message(meta["oc_task_port"], opencode_sid)
        (sd / "output" / "r0.txt").write_text(text)

        meta["round_count"] = 1
        meta["state"] = "active"
        write_meta(role_id, state_dir, meta)

    def send(self, role_id, prompt_file, state_dir):
        sd = session_dir(role_id, state_dir)
        meta = read_meta(role_id, state_dir)
        if not meta:
            raise RuntimeError(f"session not found: {role_id}")
        if meta["state"] != "active":
            raise RuntimeError(f"session not active: {role_id} (state={meta['state']})")

        n = meta["round_count"]
        rN_in = sd / "input" / f"r{n}.md"
        shutil.copy(prompt_file, rN_in)

        oc = self._oc_task()
        env = os.environ.copy()
        env["OC_TASK_ID"] = meta["oc_task_id"]
        env["OC_TASK_PORT"] = meta["oc_task_port"]

        send_res = subprocess.run(
            [oc, "send", meta["sid"], str(rN_in), "--agent", "autoaccept"],
            capture_output=True,
            text=True,
            env=env,
            timeout=1800,
        )
        if send_res.returncode != 0:
            append_log(role_id, state_dir, f"send r{n} rc={send_res.returncode}\nstderr:\n{send_res.stderr}")
            meta["state"] = "error"
            write_meta(role_id, state_dir, meta)
            raise RuntimeError(f"oc-task send failed: {send_res.stderr.strip()}")

        text = self._fetch_message(meta["oc_task_port"], meta["sid"])
        (sd / "output" / f"r{n}.txt").write_text(text)

        meta["round_count"] = n + 1
        write_meta(role_id, state_dir, meta)

    def status(self, role_id, state_dir, wait, timeout):
        meta = read_meta(role_id, state_dir)
        if not meta:
            return "error"
        return {"spawning": "running", "active": "done", "failed": "error", "error": "error"}.get(
            meta["state"], "error"
        )

    def cleanup(self, role_id, state_dir):
        sd = session_dir(role_id, state_dir)
        if not sd.exists():
            return
        meta = read_meta(role_id, state_dir)
        if meta and meta.get("oc_task_id"):
            try:
                oc = self._oc_task()
                subprocess.run(
                    [oc, "end", meta["oc_task_id"]],
                    capture_output=True,
                    text=True,
                    timeout=60,
                )
            except Exception as e:
                append_log(role_id, state_dir, f"cleanup oc-task end failed: {e}")
        shutil.rmtree(sd, ignore_errors=True)


# ============================================================
# Codex driver
# ============================================================


class CodexDriver(Driver):
    name = "codex"
    family = "openai"

    @classmethod
    def detect(cls) -> Optional[str]:
        return shutil.which("codex")

    def _session_cwd(self, role_id: str, state_dir: Optional[str]) -> Path:
        """Each role gets an isolated cwd so `codex exec resume --last` is unambiguous.
        Always returns an absolute path so subsequent commands don't get confused by
        relative-path interactions with subprocess `cwd=` and `--cd`."""
        cwd = session_dir(role_id, state_dir) / "cwd"
        cwd.mkdir(parents=True, exist_ok=True)
        return cwd.resolve()

    def _common_flags(self) -> list[str]:
        # Non-interactive: bypass approvals; sandbox read-only so a role can't damage the host
        return ["--full-auto", "--skip-git-repo-check"]

    def spawn(self, role_id, prompt_file, model, state_dir, system_prompt):
        sd = session_dir(role_id, state_dir)
        (sd / "input").mkdir(parents=True, exist_ok=True)
        (sd / "output").mkdir(parents=True, exist_ok=True)

        cwd = self._session_cwd(role_id, state_dir)

        # Compose prompt (codex has no separate system-prompt flag — prepend if given)
        prompt_content = Path(prompt_file).read_text()
        if system_prompt:
            prompt_content = f"<system>\n{system_prompt}\n</system>\n\n{prompt_content}"

        r0_in = sd / "input" / "r0.md"
        r0_in.write_text(prompt_content)
        r0_out = sd / "output" / "r0.txt"

        meta = {
            "backend": "codex",
            "family": "openai",
            "model": model or "default",
            "sid": None,  # not needed — cwd-scoped --last finds it
            "round_count": 0,
            "state": "spawning",
            "system_prompt": system_prompt,
            "cwd": str(cwd),
        }
        write_meta(role_id, state_dir, meta)

        # spawn: use --cd (codex exec supports it). Don't also set subprocess cwd= or
        # codex would try to resolve the same path twice.
        cmd = ["codex", "exec", *self._common_flags(),
               "--cd", str(cwd),
               "--output-last-message", str(r0_out.resolve())]
        if model:
            cmd += ["-m", model]

        result = subprocess.run(
            cmd, input=prompt_content, capture_output=True, text=True, timeout=DEFAULT_TIMEOUT,
        )
        if result.returncode != 0:
            append_log(role_id, state_dir, f"spawn rc={result.returncode}\nstderr:\n{result.stderr}")
            meta["state"] = "failed"
            write_meta(role_id, state_dir, meta)
            raise RuntimeError(f"codex exec failed (rc={result.returncode}): {result.stderr.strip()}")

        if not r0_out.exists() or r0_out.stat().st_size == 0:
            append_log(role_id, state_dir, f"spawn empty output\nstdout:\n{result.stdout}")
            meta["state"] = "error"
            write_meta(role_id, state_dir, meta)
            raise RuntimeError("codex exec produced no output")

        meta["round_count"] = 1
        meta["state"] = "active"
        write_meta(role_id, state_dir, meta)

    def send(self, role_id, prompt_file, state_dir):
        sd = session_dir(role_id, state_dir)
        meta = read_meta(role_id, state_dir)
        if not meta:
            raise RuntimeError(f"session not found: {role_id}")
        if meta["state"] != "active":
            raise RuntimeError(f"session not active: {role_id} (state={meta['state']})")

        n = meta["round_count"]
        rN_in = sd / "input" / f"r{n}.md"
        shutil.copy(prompt_file, rN_in)
        rN_out = sd / "output" / f"r{n}.txt"

        cwd = Path(meta.get("cwd") or self._session_cwd(role_id, state_dir))

        # send: `codex exec resume` does NOT accept --cd; use subprocess cwd= so that
        # `--last` resolves to the session created in this exact directory by spawn.
        prompt_content = rN_in.read_text()
        cmd = ["codex", "exec", "resume", "--last", *self._common_flags(),
               "--output-last-message", str(rN_out.resolve())]
        if meta.get("model") and meta["model"] != "default":
            cmd += ["-m", meta["model"]]

        result = subprocess.run(
            cmd, input=prompt_content, capture_output=True, text=True,
            cwd=str(cwd), timeout=DEFAULT_TIMEOUT,
        )
        if result.returncode != 0:
            append_log(role_id, state_dir, f"send r{n} rc={result.returncode}\nstderr:\n{result.stderr}")
            meta["state"] = "error"
            write_meta(role_id, state_dir, meta)
            raise RuntimeError(f"codex exec resume failed (rc={result.returncode}): {result.stderr.strip()}")

        if not rN_out.exists() or rN_out.stat().st_size == 0:
            raise RuntimeError("codex exec resume produced no output")

        meta["round_count"] = n + 1
        write_meta(role_id, state_dir, meta)

    def status(self, role_id, state_dir, wait, timeout):
        meta = read_meta(role_id, state_dir)
        if not meta:
            return "error"
        return {"spawning": "running", "active": "done", "failed": "error", "error": "error"}.get(
            meta["state"], "error"
        )

    def cleanup(self, role_id, state_dir):
        sd = session_dir(role_id, state_dir)
        if not sd.exists():
            return
        # codex sessions live under ~/.codex/sessions or similar; we don't reach in to delete them
        # (they get GC'd by codex itself or stay harmless). Just nuke our state dir.
        shutil.rmtree(sd, ignore_errors=True)


# ============================================================
# Registry
# ============================================================


DRIVERS: list[type[Driver]] = [ClaudeDriver, OpencodeDriver, CodexDriver]


def get_driver_for_backend(name: str) -> Optional[type[Driver]]:
    return next((d for d in DRIVERS if d.name == name), None)


def get_driver_for_session(role_id: str, state_dir: Optional[str]) -> Optional[Driver]:
    meta = read_meta(role_id, state_dir)
    if not meta:
        return None
    cls = get_driver_for_backend(meta["backend"])
    return cls() if cls else None


# ============================================================
# Commands
# ============================================================


def cmd_doctor(args) -> int:
    print("Detected backends:")
    available: list[type[Driver]] = []
    for d in DRIVERS:
        path = d.detect()
        if path:
            available.append(d)
            print(f"  ✓ {d.name:<10} {path}")
        else:
            print(f"  ✗ {d.name:<10} not installed  — see references/backend-{d.name}.md")
    families = {d.family for d in available}
    print()
    print(f"Available backends: {len(available)}")
    print(f"Distinct model families: {len(families)}" + (f" ({', '.join(sorted(families))})" if families else ""))
    if len(families) >= 2:
        print("Multi-model capability: ✓")
    else:
        print("Multi-model capability: ✗ (need ≥2 distinct families for cross-model debate)")
    return 0


def cmd_list_backends(args) -> int:
    for d in DRIVERS:
        if d.detect():
            print(d.name)
    return 0


def cmd_describe(args) -> int:
    meta = read_meta(args.role_id, args.state_dir)
    if not meta:
        print(f"session not found: {args.role_id}", file=sys.stderr)
        return 2
    out = {
        "role_id": args.role_id,
        "backend": meta.get("backend"),
        "family": meta.get("family"),
        "model": meta.get("model"),
        "round_count": meta.get("round_count", 0),
        "state": meta.get("state"),
    }
    print(json.dumps(out, indent=2))
    return 0


def cmd_spawn(args) -> int:
    sd = session_dir(args.role_id, args.state_dir)
    if sd.exists() and not args.force:
        print(f"session already exists: {args.role_id} (use --force to overwrite)", file=sys.stderr)
        return 2
    if sd.exists() and args.force:
        shutil.rmtree(sd, ignore_errors=True)

    cls = get_driver_for_backend(args.backend)
    if not cls:
        print(f"unknown backend: {args.backend} (run `agent-session list-backends`)", file=sys.stderr)
        return 2
    if not cls.detect():
        print(f"backend not installed: {args.backend} — see references/backend-{args.backend}.md", file=sys.stderr)
        return 2

    with lock(args.role_id, args.state_dir):
        cls().spawn(
            args.role_id,
            args.prompt_file,
            args.model,
            args.state_dir,
            args.system_prompt,
        )
    return 0


def cmd_send(args) -> int:
    drv = get_driver_for_session(args.role_id, args.state_dir)
    if not drv:
        print(f"session not found: {args.role_id}", file=sys.stderr)
        return 2
    with lock(args.role_id, args.state_dir):
        drv.send(args.role_id, args.prompt_file, args.state_dir)
    return 0


def cmd_status(args) -> int:
    drv = get_driver_for_session(args.role_id, args.state_dir)
    if not drv:
        print("error")
        return 0
    print(drv.status(args.role_id, args.state_dir, args.wait, args.timeout))
    return 0


def cmd_output(args) -> int:
    sd = session_dir(args.role_id, args.state_dir)
    meta = read_meta(args.role_id, args.state_dir)
    if not meta:
        print(f"session not found: {args.role_id}", file=sys.stderr)
        return 2
    n = args.round if args.round is not None else meta["round_count"] - 1
    f = sd / "output" / f"r{n}.txt"
    if not f.exists():
        print(f"output round not found: r{n}", file=sys.stderr)
        return 2
    sys.stdout.write(f.read_text())
    return 0


def cmd_cleanup(args) -> int:
    drv = get_driver_for_session(args.role_id, args.state_dir)
    if not drv:
        # idempotent — also remove any stale dir
        shutil.rmtree(session_dir(args.role_id, args.state_dir), ignore_errors=True)
        return 0
    drv.cleanup(args.role_id, args.state_dir)
    return 0


# ============================================================
# CLI
# ============================================================


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="agent-session")
    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("doctor", help="health check (read-only)")
    sub.add_parser("list-backends", help="list detected backends, one per line")

    p_describe = sub.add_parser("describe", help="describe a session")
    p_describe.add_argument("--role-id", required=True)
    p_describe.add_argument("--state-dir")

    p_spawn = sub.add_parser("spawn", help="create a session and run first turn")
    p_spawn.add_argument("--backend", required=True)
    p_spawn.add_argument("--role-id", required=True)
    p_spawn.add_argument("--prompt-file", required=True)
    p_spawn.add_argument("--model")
    p_spawn.add_argument("--state-dir")
    p_spawn.add_argument("--system-prompt")
    p_spawn.add_argument("--force", action="store_true")

    p_send = sub.add_parser("send", help="continue an existing session")
    p_send.add_argument("--role-id", required=True)
    p_send.add_argument("--prompt-file", required=True)
    p_send.add_argument("--state-dir")

    p_status = sub.add_parser("status", help="get session status")
    p_status.add_argument("--role-id", required=True)
    p_status.add_argument("--state-dir")
    p_status.add_argument("--wait", action="store_true")
    p_status.add_argument("--timeout", type=int)

    p_output = sub.add_parser("output", help="read assistant message")
    p_output.add_argument("--role-id", required=True)
    p_output.add_argument("--state-dir")
    p_output.add_argument("--round", type=int)

    p_cleanup = sub.add_parser("cleanup", help="close session and remove state")
    p_cleanup.add_argument("--role-id", required=True)
    p_cleanup.add_argument("--state-dir")

    return p


HANDLERS = {
    "doctor": cmd_doctor,
    "list-backends": cmd_list_backends,
    "describe": cmd_describe,
    "spawn": cmd_spawn,
    "send": cmd_send,
    "status": cmd_status,
    "output": cmd_output,
    "cleanup": cmd_cleanup,
}


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return HANDLERS[args.command](args)
    except RuntimeError as e:
        print(str(e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
