"""The first prompt into a terminal names it with a two-word topic; nothing
names terminals before that."""

from __future__ import annotations

from cmux_voice.tools import VoiceTools, topic_title
from tests.conftest import FakeCmux


def test_topic_title_is_exactly_two_title_case_words():
    assert topic_title("login tests") == "Login Tests"
    assert topic_title("fix the login bug") == "Fix The"
    assert topic_title("API cleanup") == "API Cleanup"
    assert topic_title("Deploy Script.") == "Deploy Script"
    assert topic_title("  ") == "" and topic_title(None) == ""
    assert topic_title("refactor") == "Refactor"


def _renames(fake: FakeCmux):
    return [r["params"] for r in fake.requests if r["method"] == "surface.rename"]


async def test_first_prompt_names_the_terminal_only_once(tools: VoiceTools, fake: FakeCmux):
    res = await tools.compose_and_type("add tests for login", topic="login tests")
    assert res["ok"] and res["named"] == "Login Tests"
    assert _renames(fake) == [{"surface_id": "S-B1", "title": "Login Tests"}]
    res = await tools.compose_and_type("also cover logout", topic="logout flow")
    assert res["ok"] and "named" not in res
    assert len(_renames(fake)) == 1, "later prompts keep the name"


async def test_rename_happens_after_the_prompt_is_sent(tools: VoiceTools, fake: FakeCmux):
    await tools.compose_and_type("hello", topic="Say Hello")
    methods = fake.methods()
    assert methods.index("surface.send_key") < methods.index("surface.rename")


async def test_missing_topic_asks_the_model_to_name_it(tools: VoiceTools, fake: FakeCmux):
    res = await tools.compose_and_type("add tests for login")
    assert res["ok"] and res["name_this_terminal"] is True and "rename_tab" in res["reply"]
    assert _renames(fake) == []
    # The model then names it itself; a later prompt must not ask again.
    await tools.rename_tab("Login Tests")
    res = await tools.compose_and_type("and logout", topic="logout flow")
    assert "name_this_terminal" not in res and "named" not in res


async def test_open_agent_with_first_prompt_names_the_terminal(tools: VoiceTools, fake: FakeCmux, monkeypatch):
    async def ready(surface_id, timeout_s=25.0):
        return True

    monkeypatch.setattr(tools, "_wait_for_agent_prompt", ready)
    res = await tools.open_agent("claude", prompt="write the deploy script", topic="deploy script")
    assert res["ok"] and res["named"] == "Deploy Script"
    assert _renames(fake) == [{"surface_id": "S-B1", "title": "Deploy Script"}]


async def test_open_agent_without_prompt_does_not_name(tools: VoiceTools, fake: FakeCmux, monkeypatch):
    async def ready(surface_id, timeout_s=25.0):
        return True

    monkeypatch.setattr(tools, "_wait_for_agent_prompt", ready)
    res = await tools.open_agent("claude")
    assert res["ok"] and _renames(fake) == []


def test_specs_require_topic_on_compose(tools: VoiceTools):
    compose = next(s for s in tools.specs() if s.name == "compose_and_type")
    assert "topic" in compose.properties and compose.required == ["text", "topic"]
    open_agent = next(s for s in tools.specs() if s.name == "open_agent")
    assert "topic" in open_agent.properties


def test_prompt_forbids_naming_up_front():
    from cmux_voice.prompt import build_system_prompt

    prompt = build_system_prompt()
    assert "never name a new terminal or workspace yourself" in prompt
    assert "exactly two words" in prompt
