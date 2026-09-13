"""Creating a terminal lands the user in it: pane focus plus the keyboard cursor,
so nobody has to say "switch to the new terminal" afterwards."""

from __future__ import annotations

from cmux_voice.tools import VoiceTools
from tests.conftest import FakeCmux


def _after(fake: FakeCmux, method: str):
    """Requests issued after the first call to `method`."""
    methods = fake.methods()
    return fake.requests[methods.index(method) + 1 :]


async def test_split_focuses_the_new_terminal_and_its_keyboard(tools: VoiceTools, fake: FakeCmux):
    res = await tools.split("right")
    assert res["ok"] and res["surface_id"] == "S-NEW"
    after = _after(fake, "surface.split")
    assert {"method": "surface.focus", "params": {"surface_id": "S-NEW"}} in after
    assert {"method": "surface.focus_input", "params": {"surface_id": "S-NEW"}} in after


async def test_browser_split_focuses_without_stealing_the_keyboard(tools: VoiceTools, fake: FakeCmux):
    res = await tools.split("down", kind="browser", url="github.com")
    assert res["ok"]
    after = _after(fake, "browser.open_split")
    assert {"method": "surface.focus", "params": {"surface_id": "S-NEW"}} in after
    assert "surface.focus_input" not in [r["method"] for r in after]


async def test_new_terminal_tab_lands_in_it(tools: VoiceTools, fake: FakeCmux):
    res = await tools.new_tab("terminal")
    assert res["ok"] and res["surface_id"] == "S-NEW"
    after = _after(fake, "surface.create")
    assert {"method": "surface.focus", "params": {"surface_id": "S-NEW"}} in after
    assert {"method": "surface.focus_input", "params": {"surface_id": "S-NEW"}} in after


async def test_new_workspace_is_selected_and_its_terminal_focused(tools: VoiceTools, fake: FakeCmux):
    res = await tools.create_workspace("notes")
    assert res["ok"] and res["workspace_id"] == "WS-NEW"
    after = _after(fake, "workspace.create")
    assert {"method": "workspace.select", "params": {"workspace_id": "WS-NEW"}} in after
    assert {"method": "surface.focus_input", "params": {}} in after


async def test_focus_failure_does_not_fail_the_creation():
    def responder(method, params):
        if method in {"surface.focus", "surface.focus_input"}:
            raise ValueError("surface_not_found")
        return FakeCmux.default_responder(None, method, params)  # type: ignore[arg-type]

    fake = FakeCmux(responder)
    try:
        from cmux_voice.cmux_client import CmuxClient
        from cmux_voice.policy import ConfirmationPolicy
        from cmux_voice.tools import ALLOWED_METHODS

        client = CmuxClient(fake.path, allowed_methods=ALLOWED_METHODS, connect_timeout_s=2.0, call_timeout_s=5.0)
        t = VoiceTools(client, ConfirmationPolicy())
        res = await t.split("right")
        assert res["ok"], "the split happened; focus is best effort"
        client.close()
    finally:
        fake.close()
