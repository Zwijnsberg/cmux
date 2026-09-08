"""Semantic mode: the hovering brainstorm box over a coding agent's input."""

from __future__ import annotations

from typing import Any, Dict, List

import pytest

from cmux_voice.cmux_client import CmuxClient
from cmux_voice.policy import ConfirmationPolicy
from cmux_voice.semantic import STAGE_DRAFTING, STAGE_FINAL, STAGE_IDLE, SemanticSession
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


# ------------------------------------------------------------------ model


def test_session_replace_is_whole_text_not_append():
    s = SemanticSession()
    s.enable("S-B1", "claude")
    s.replace("Make the login async")
    s.replace("Make the login async and add tests")
    assert s.text == "Make the login async and add tests"
    assert s.stage == STAGE_DRAFTING
    s.finalize("Refactor login to async/await and add unit tests.")
    assert s.stage == STAGE_FINAL
    assert s.take_for_send() == "Refactor login to async/await and add unit tests."
    assert s.text == "" and s.stage == STAGE_IDLE


def test_session_moves_between_terminals_and_resets_box():
    s = SemanticSession()
    s.enable("S-B1", "claude")
    s.replace("half an idea")
    notice = s.enable("S-B2", "codex")
    assert s.surface_id == "S-B2" and s.agent == "codex"
    assert s.text == "" and s.stage == STAGE_IDLE
    assert "Codex" in notice and "Semantic mode on" in notice
    off = s.disable()
    assert not s.active and "Semantic mode off" in off


def test_snapshot_shape():
    s = SemanticSession()
    s.enable("S-B1", "claude")
    s.replace("x")
    snap = s.snapshot("enabled")
    assert snap == {
        "type": "semantic_draft",
        "surface_id": "S-B1",
        "agent": "claude",
        "enabled": True,
        "text": "x",
        "stage": STAGE_DRAFTING,
        "event": "enabled",
    }


# ------------------------------------------------------------------ tools


async def test_tools_refuse_when_mode_is_off(stools: VoiceTools, fake: FakeCmux):
    for res in (await stools.semantic_draft("x"), await stools.semantic_finalize("x"), await stools.semantic_send(), await stools.semantic_clear()):
        assert res["ok"] is False
        assert "Semantic mode is off" in res["say"]
    assert "surface.send_text" not in fake.methods()


async def test_enable_pushes_state_and_returns_notice(stools: VoiceTools, pushed):
    notice = await stools.set_semantic_mode("S-B1", "claude", enabled=True)
    assert "Claude Code" in notice and "semantic_draft" in notice
    assert pushed[-1]["enabled"] is True and pushed[-1]["event"] == "enabled" and pushed[-1]["surface_id"] == "S-B1"
    off = await stools.set_semantic_mode(None, None, enabled=False)
    assert "OFF" in off
    assert pushed[-1]["enabled"] is False and pushed[-1]["event"] == "disabled"


async def test_draft_replaces_box_quietly_and_never_types(stools: VoiceTools, fake: FakeCmux, pushed):
    await stools.set_semantic_mode("S-B1", "claude")
    r1 = await stools.semantic_draft("Login should be async")
    r2 = await stools.semantic_draft("- Login should be async\n- Add tests for it")
    assert r1["ok"] and r2["ok"]
    assert r2["say"] == "" and "Say nothing" in r2["reply"]
    assert pushed[-1]["text"] == "- Login should be async\n- Add tests for it"
    assert pushed[-1]["stage"] == STAGE_DRAFTING
    assert not any(m in fake.methods() for m in ("surface.send_text", "surface.send_key"))


async def test_finalize_asks_ready_to_send(stools: VoiceTools, pushed):
    await stools.set_semantic_mode("S-B1", "claude")
    res = await stools.semantic_finalize("Refactor the login handler to async/await and add unit tests.")
    assert res["ok"] and res["say"] == "Is this ready to send?"
    assert "Is this ready to send?" in res["reply"]
    assert pushed[-1]["stage"] == STAGE_FINAL
    empty = await stools.semantic_finalize("   ")
    assert empty["ok"] is False


async def test_send_types_into_the_semantic_terminal_and_empties_box(stools: VoiceTools, fake: FakeCmux, pushed):
    await stools.set_semantic_mode("S-B2", "codex")  # not the focused terminal on purpose
    await stools.semantic_finalize("Add a retry to the fetch helper.")
    res = await stools.semantic_send()
    assert res["ok"] and res["say"] == "Sent." and res["reply"].startswith("Say nothing")
    typed = [r for r in fake.requests if r["method"] == "surface.send_text"]
    keys = [r for r in fake.requests if r["method"] == "surface.send_key"]
    assert typed[-1]["params"] == {"surface_id": "S-B2", "text": "Add a retry to the fetch helper."}
    assert keys[-1]["params"] == {"surface_id": "S-B2", "key": "enter"}
    assert pushed[-1]["event"] == "sent" or [p for p in pushed if p.get("event") == "sent"]
    assert stools.semantic.text == "" and stools.semantic.stage == STAGE_IDLE
    assert stools.semantic.active, "sending keeps the mode on for the next idea"


async def test_send_with_empty_box_fails(stools: VoiceTools, fake: FakeCmux):
    await stools.set_semantic_mode("S-B1", "claude")
    res = await stools.semantic_send()
    assert res["ok"] is False and "empty" in res["say"]
    assert "surface.send_text" not in fake.methods()


async def test_send_failure_keeps_the_text(pushed):
    def responder(method: str, params: Dict[str, Any]) -> Any:
        if method == "surface.send_text":
            raise ValueError("surface_not_found")
        return FakeCmux.default_responder(None, method, params)  # type: ignore[arg-type]

    fake = FakeCmux(responder)
    try:
        async def on_semantic(snapshot):
            pushed.append(snapshot)

        client = CmuxClient(fake.path, allowed_methods=ALLOWED_METHODS, connect_timeout_s=2.0, call_timeout_s=5.0)
        t = VoiceTools(client, ConfirmationPolicy(), on_semantic=on_semantic)
        await t.set_semantic_mode("S-GONE", "claude")
        await t.semantic_finalize("keep me")
        res = await t.semantic_send()
        assert res["ok"] is False
        assert t.semantic.text == "keep me" and t.semantic.stage == STAGE_FINAL
        assert pushed[-1]["text"] == "keep me"
        client.close()
    finally:
        fake.close()


async def test_clear_empties_box(stools: VoiceTools, pushed):
    await stools.set_semantic_mode("S-B1", "claude")
    await stools.semantic_draft("something")
    res = await stools.semantic_clear()
    assert res["ok"] and res["say"] == "Cleared."
    assert pushed[-1]["event"] == "cleared" and pushed[-1]["text"] == ""


async def test_compose_and_type_becomes_the_draft_while_mode_is_on(stools: VoiceTools, fake: FakeCmux):
    # The focused terminal in the sample tree is S-B1.
    await stools.set_semantic_mode("S-B1", "claude")
    res = await stools.compose_and_type("Please add tests for login.")
    assert res["ok"] and res["say"] == "Is this ready to send?"
    assert stools.semantic.text == "Please add tests for login." and stools.semantic.stage == STAGE_FINAL
    assert "surface.send_text" not in fake.methods()


async def test_compose_and_type_still_sends_to_other_terminals(stools: VoiceTools, fake: FakeCmux):
    await stools.set_semantic_mode("S-B2", "codex")
    res = await stools.compose_and_type("Run the tests.")  # focused terminal S-B1 is not the semantic one
    assert res["ok"] and res["say"] == "Done."
    typed = [r for r in fake.requests if r["method"] == "surface.send_text"]
    assert typed[-1]["params"]["surface_id"] == "S-B1"


def test_specs_include_semantic_tools(stools: VoiceTools):
    names = {s.name for s in stools.specs()}
    assert {"semantic_draft", "semantic_finalize", "semantic_send", "semantic_clear"} <= names
    draft = next(s for s in stools.specs() if s.name == "semantic_draft")
    assert draft.required == ["text"] and "WHOLE idea" in draft.description


# --------------------------------------------------------------- bot glue


def test_bot_notice_for_box_buttons():
    import bot

    ok = bot.semantic_command_notice("send", {"ok": True, "say": "Sent."})
    assert "pressed Send" in ok and "Say nothing" in ok
    bad = bot.semantic_command_notice("clear", {"ok": False, "say": "Semantic mode is off."})
    assert "failed" in bad and "Semantic mode is off." in bad


def test_prompt_documents_semantic_mode():
    from cmux_voice.prompt import build_system_prompt

    prompt = build_system_prompt()
    assert "semantic_draft" in prompt and "Is this ready to send?" in prompt
    assert "never call compose_and_type" in prompt
