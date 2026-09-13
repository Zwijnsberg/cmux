"""Semantic mode: a per-terminal switch between verbatim and rewritten prompts."""

from __future__ import annotations

from typing import Any, Dict, List

import pytest

from cmux_voice.cmux_client import CmuxClient
from cmux_voice.policy import ConfirmationPolicy
from cmux_voice.semantic import SemanticSession
from cmux_voice.tools import ALLOWED_METHODS, VoiceTools
from tests.conftest import FakeCmux


@pytest.fixture
def pushed() -> List[Dict[str, Any]]:
    return []


@pytest.fixture
def stools(fake: FakeCmux, pushed: List[Dict[str, Any]]) -> VoiceTools:
    async def on_semantic(snapshot: Dict[str, Any]) -> None:
        pushed.append(snapshot)

    client = CmuxClient(fake.path, allowed_methods=ALLOWED_METHODS, connect_timeout_s=2.0, call_timeout_s=5.0)
    t = VoiceTools(client, ConfirmationPolicy(ttl_seconds=5.0), on_semantic=on_semantic)
    yield t
    client.close()


def test_session_moves_between_terminals():
    s = SemanticSession()
    on = s.enable("S-B1")
    assert s.targets("S-B1") and not s.targets("S-B2")
    assert "rewrite" in on and "Semantic mode on." in on
    s.enable("S-B2")
    assert s.targets("S-B2") and not s.targets("S-B1")
    off = s.disable()
    assert not s.active and "Semantic mode off." in off
    assert s.snapshot() == {"type": "semantic_mode", "surface_id": None, "enabled": False}


async def test_enable_pushes_state_and_returns_notice(stools: VoiceTools, pushed):
    notice = await stools.set_semantic_mode("S-B1", enabled=True)
    assert "compose_and_type" in notice and "rewrite" in notice
    assert pushed[-1] == {"type": "semantic_mode", "surface_id": "S-B1", "enabled": True}
    off = await stools.set_semantic_mode(None, enabled=False)
    assert "OFF" in off and "do not restructure" in off
    assert pushed[-1]["enabled"] is False


async def test_compose_and_type_sends_immediately_in_either_mode(stools: VoiceTools, fake: FakeCmux):
    # Off: the model passes the words through; the tool types and submits.
    res = await stools.compose_and_type("add tests for login")
    assert res["ok"] and res["sent"] is True
    # On for the focused terminal (S-B1): the model rewrote before calling; the tool still sends at once.
    await stools.set_semantic_mode("S-B1")
    res = await stools.compose_and_type("Add unit tests for the login handler.")
    assert res["ok"] and res["sent"] is True
    typed = [r for r in fake.requests if r["method"] == "surface.send_text"]
    keys = [r for r in fake.requests if r["method"] == "surface.send_key"]
    assert [t["params"]["text"] for t in typed] == ["add tests for login", "Add unit tests for the login handler."]
    assert len(keys) == 2 and all(k["params"]["key"] == "enter" for k in keys)


def test_no_draft_tools_remain(stools: VoiceTools):
    names = {s.name for s in stools.specs()}
    assert not any(n.startswith("semantic_") for n in names), "the hovering box and its tools are gone"


def test_prompt_documents_both_modes():
    from cmux_voice.prompt import build_system_prompt

    prompt = build_system_prompt()
    assert "Off (the default): send what they said, verbatim" in prompt
    assert "On: rewrite their rough words into a clean, well-structured prompt" in prompt
    assert "Is this ready to send?" not in prompt and "semantic_draft" not in prompt
