"""Semantic mode: how "tell it ..." is turned into an agent prompt.

The app shows a "Semantic mode" pill on every terminal. It changes one thing:
how the voice agent processes the words the user wants sent to Claude Code or
Codex in that terminal.

- On: the model rewrites the user's rough words into a clean, well-structured
  prompt (grammar fixed, organized into short sentences or bullets, every
  technical detail kept, nothing added), then types and sends it.
- Off: the words go in as said, apart from dropping the "tell it" lead-in and
  obvious filler; no restructuring.

Either way the prompt is sent immediately. Nothing hovers over the terminal;
this module only remembers which terminal (if any) has the mode on and
produces the system notices that tell the model how to behave.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, Optional


@dataclass
class SemanticSession:
    surface_id: Optional[str] = None

    @property
    def active(self) -> bool:
        return bool(self.surface_id)

    def targets(self, surface_id: Optional[str]) -> bool:
        return self.active and surface_id is not None and surface_id == self.surface_id

    def enable(self, surface_id: str) -> str:
        """Turn the mode on for one terminal (moving it if it was on elsewhere).
        Returns the system notice that tells the model how to compose now."""
        self.surface_id = surface_id
        return (
            "[Semantic mode is now ON for the focused terminal. This is a system notice, not the user speaking. "
            "From now on, when the user asks you to tell or ask the coding agent something in that terminal, rewrite their words into a "
            "clean, well-structured prompt before calling compose_and_type: fix grammar, organize into short sentences or bullets, keep every "
            "technical detail and every name they used, add nothing they did not say. Then send it at once, as usual. "
            'Say exactly one short sentence now: "Semantic mode on."]'
        )

    def disable(self) -> str:
        self.surface_id = None
        return (
            "[Semantic mode is now OFF. This is a system notice, not the user speaking. Prompts for the coding agent go in as the user said "
            "them again: drop only the lead-in and filler, do not restructure. "
            'Say exactly: "Semantic mode off."]'
        )

    def snapshot(self) -> Dict[str, Any]:
        return {"type": "semantic_mode", "surface_id": self.surface_id, "enabled": self.active}
