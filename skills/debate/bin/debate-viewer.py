#!/usr/bin/env python3
"""Debate Viewer — Textual TUI that watches a debate's agent-session state dir
and renders each role's output as a colored markdown panel as files appear.

Usage:
    debate-viewer.py <sessions-dir>

<sessions-dir> is the `--state-dir` passed to `agent-session` calls (i.e.
$DEBATE_DIR/sessions in the SKILL.md flow). Each role's output lives at
<sessions-dir>/<role-id>/output/r<n>.txt; the viewer polls those files and
renders new content.

Dependencies: textual, rich. Install via:
    uv venv ~/.cache/agent-session/debate-viewer-venv --python 3.12
    source ~/.cache/agent-session/debate-viewer-venv/bin/activate
    uv pip install textual rich
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from rich.markdown import Markdown
from rich.panel import Panel
from rich.rule import Rule
from rich.text import Text
from textual.app import App, ComposeResult
from textual.widgets import Footer, Header, RichLog


# Per-role rendering style. Unknown role-ids fall back to white.
AGENT_STYLES: dict[str, tuple[str, str]] = {
    "defender": ("cyan", "Defender"),
    "role-a": ("yellow", "Role A"),
    "role-b": ("green", "Role B"),
    "wildcard": ("magenta", "Wildcard"),
}


class DebateViewer(App):
    """Watch a multi-agent debate in real-time."""

    TITLE = "Debate Viewer"
    CSS = """
    RichLog {
        background: $surface;
        padding: 1 2;
    }
    """
    BINDINGS = [
        ("q", "quit", "Quit"),
        ("pageup", "scroll_page_up", "Page Up"),
        ("pagedown", "scroll_page_down", "Page Down"),
        ("home", "scroll_home", "Top"),
        ("end", "scroll_end", "Bottom"),
        ("up", "scroll_up", "Up"),
        ("down", "scroll_down", "Down"),
    ]

    def __init__(self, sessions_dir: Path):
        super().__init__()
        self.sessions_dir = sessions_dir
        self.seen_files: dict[str, int] = {}
        self.round_announced: set[str] = set()

    def compose(self) -> ComposeResult:
        yield Header()
        yield RichLog(highlight=False, markup=True, auto_scroll=True, wrap=True)
        yield Footer()

    def on_mount(self) -> None:
        self.chat_log = self.query_one(RichLog)
        self.chat_log.focus()  # so wheel + page keys land on RichLog
        self.chat_log.write(
            Text(f"Watching {self.sessions_dir}\n", style="dim italic")
        )
        self.chat_log.write(
            Text("Waiting for debate to start...\n", style="dim italic")
        )
        self.set_interval(0.5, self._poll_files)

    # ---- Scroll actions (App-level wrappers around RichLog methods) ----

    def action_scroll_page_up(self) -> None: self.chat_log.scroll_page_up()
    def action_scroll_page_down(self) -> None: self.chat_log.scroll_page_down()
    def action_scroll_home(self) -> None: self.chat_log.scroll_home()
    def action_scroll_end(self) -> None: self.chat_log.scroll_end()
    def action_scroll_up(self) -> None: self.chat_log.scroll_up()
    def action_scroll_down(self) -> None: self.chat_log.scroll_down()

    # ---- Polling ----

    def _poll_files(self) -> None:
        if not self.sessions_dir.exists():
            return

        # agent-session writes per-role outputs at:
        #     <sessions-dir>/<role-id>/output/r<n>.txt
        candidates: list[tuple[Path, str, str]] = []  # (path, role-id, round-num)
        for role_dir in self.sessions_dir.iterdir():
            if not role_dir.is_dir():
                continue
            out_dir = role_dir / "output"
            if not out_dir.is_dir():
                continue
            for fpath in out_dir.glob("r*.txt"):
                round_num = fpath.stem[1:] if fpath.stem.startswith("r") else "?"
                candidates.append((fpath, role_dir.name, round_num))

        candidates.sort(key=lambda t: t[0].stat().st_mtime)

        for fpath, role_id, round_num in candidates:
            key = str(fpath)
            last_size = self.seen_files.get(key, 0)
            current_size = fpath.stat().st_size
            if current_size <= last_size:
                continue

            full_content = fpath.read_text()
            self.seen_files[key] = current_size

            if not full_content.strip():
                continue

            # Round header (printed once per round, on the first new file we see)
            round_label = f"round-{round_num}"
            if round_label not in self.round_announced:
                self.round_announced.add(round_label)
                self.chat_log.write(Text(""))
                self.chat_log.write(Rule(f" Round {round_num} ", style="bold white"))
                self.chat_log.write(Text(""))

            color, display_name = AGENT_STYLES.get(role_id, ("white", role_id))
            clean = self._strip_ansi(full_content.strip())

            try:
                body = Markdown(clean)
            except Exception:
                body = Text(clean)

            panel = Panel(
                body,
                title=f"[bold]{display_name}[/bold] · Round {round_num}",
                title_align="left",
                border_style=color,
                padding=(1, 2),
            )
            self.chat_log.write(panel)

    # ---- Helpers ----

    @staticmethod
    def _strip_ansi(text: str) -> str:
        return re.sub(r"\x1b\[[0-9;]*m", "", text)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <sessions-dir>", file=sys.stderr)
        return 2
    sessions_dir = Path(sys.argv[1]).resolve()
    if not sessions_dir.exists():
        print(f"sessions-dir does not exist: {sessions_dir}", file=sys.stderr)
        return 2
    DebateViewer(sessions_dir).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
