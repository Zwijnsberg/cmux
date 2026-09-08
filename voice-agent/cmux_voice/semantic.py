"""Semantic mode: a spoken brainstorm that becomes one clean prompt.

The app shows a "Semantic mode" button on every terminal. While it is on for a
terminal running Claude Code or Codex, a box hovers over that agent's input.
The user thinks out loud; the model keeps the box current with the *whole*
idea so far (each update replaces the box, never appends), interrupts with a
short question when something is unclear, consolidates the idea once the
user sounds done, and asks "Is this ready to send?". Only then is the text
typed into the agent and submitted, and the box empties.

Nothing reaches the terminal until the user approves the send. This module is
the state; the tools that mutate it live in `tools.py`, and `bot.py` forwards
every change to the app as a `semantic_draft` server message.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, Optional

AGENT_LABELS = {"claude": "Claude Code", "codex": "Codex"}

STAGE_IDLE = "idle"  # box is empty, listening
STAGE_DRAFTING = "drafting"  # partial idea, still being shaped
STAGE_FINAL = "final"  # consolidated prompt, awaiting "ready to send?"


@dataclass
class SemanticSession:
    surface_id: Optional[str] = None
    agent: Optional[str] = None
    text: str = ""
    stage: str = STAGE_IDLE

    # ------------------------------------------------------------- queries

    @property
    def active(self) -> bool:
        return bool(self.surface_id)

    @property
    def agent_label(self) -> str:
        return AGENT_LABELS.get((self.agent or "").lower(), "the agent")

    def targets(self, surface_id: Optional[str]) -> bool:
        return self.active and surface_id is not None and surface_id == self.surface_id

    # ----------------------------------------------------------- lifecycle

    def enable(self, surface_id: str, agent: Optional[str] = None) -> str:
        """Turn the mode on for one terminal (moving it if it was on elsewhere).
        Returns the system notice that tells the model how to behave now."""
        moved = self.active and surface_id != self.surface_id
        if not self.active or moved:
            self.text = ""
            self.stage = STAGE_IDLE
        self.surface_id = surface_id
        self.agent = (agent or self.agent or "").lower() or None
        return (
            "[Semantic mode is now ON for the terminal running "
            f"{self.agent_label}. This is a system notice, not the user speaking. From now on the user is thinking out loud about one prompt "
            "for that agent. Keep the hovering box current with semantic_draft (pass the WHOLE idea so far every time; each call replaces the box), "
            "ask one short question only when something is unclear, and when the idea sounds complete call semantic_finalize and ask "
            '"Is this ready to send?". Never type into that terminal with other tools. '
            'Say exactly one short sentence now: "Semantic mode on. Tell me what you have in mind."]'
        )

    def disable(self) -> str:
        """Turn the mode off; the box is discarded. Returns the model's notice."""
        self.surface_id = None
        self.agent = None
        self.text = ""
        self.stage = STAGE_IDLE
        return (
            "[Semantic mode is now OFF. This is a system notice, not the user speaking. Go back to normal operation: "
            'prompts are sent immediately with compose_and_type again. Say exactly: "Semantic mode off."]'
        )

    def set_agent(self, agent: Optional[str]) -> None:
        self.agent = (agent or "").lower() or None

    # ------------------------------------------------------------ the box

    def replace(self, text: str) -> None:
        """A drafting update: the complete current idea replaces the box."""
        self.text = (text or "").strip()
        self.stage = STAGE_DRAFTING if self.text else STAGE_IDLE

    def finalize(self, text: str) -> None:
        """The consolidated prompt replaces everything in the box."""
        self.text = (text or "").strip()
        self.stage = STAGE_FINAL if self.text else STAGE_IDLE

    def take_for_send(self) -> str:
        """The text to submit; the box empties."""
        text = self.text
        self.text = ""
        self.stage = STAGE_IDLE
        return text

    def clear(self) -> None:
        self.text = ""
        self.stage = STAGE_IDLE

    # ------------------------------------------------------------- export

    def snapshot(self, event: Optional[str] = None) -> Dict[str, Any]:
        """What the app renders. `event` marks a transition ("sent", "cleared",
        "enabled", "disabled") so the UI can animate it."""
        out: Dict[str, Any] = {
            "type": "semantic_draft",
            "surface_id": self.surface_id,
            "agent": self.agent,
            "enabled": self.active,
            "text": self.text,
            "stage": self.stage,
        }
        if event:
            out["event"] = event
        return out
