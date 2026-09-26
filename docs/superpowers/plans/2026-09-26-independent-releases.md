# Independent Python and Plugin Releases Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drop the handshake's upper version bound so that a Python-only or plugin-only release talks to the counterpart the user already has, while incompatible pairs still fail the handshake.

**Architecture:** Each side keeps only a floor — `MIN_RUBY` in `compat.py`, `MIN_PYTHON` in `compat.rb` — and rejects a counterpart older than it; `MAX_RUBY` / `MAX_PYTHON` and the "too new" branches disappear. The newer side of a pair knows what changed, so the newer side rejects the older one. `get_version` on both sides drops its `max_*` fields, and `docs/release.md` switches to one shared version line with one-sided releases.

**Tech Stack:** Python 3.10+ (FastMCP, asyncio, pytest + pytest-asyncio, `uv`); Ruby 3.2 inside SketchUp (minitest, stdlib).

**Spec:** `docs/superpowers/specs/2026-09-26-independent-releases-design.md`

## Global Constraints

- Handshake wire format unchanged: `hello` keeps `params.client_version`; its reply keeps `server_version` and `client_id`.
- Floors stay put: `MIN_RUBY = "0.3.0"` (`src/sketchup_mcp/compat.py`), `MIN_PYTHON   = "0.3.0"` (`mcp_for_sketchup/mcp_for_sketchup/core/compat.rb`).
- No version bump and no release: `__version__` / `pyproject.toml` stay `0.3.1`; `SERVER_VERSION = "0.3.1"`.
- Message texts exactly as spec §5.4 (the code blocks below carry them verbatim).
- Never run an auto-formatter over handlers or tests — literal source-guard tests pin handler source text.
- Stage files by explicit path; never `git add -A` / `git add .` — `docs/superpowers/` and the repo root hold untracked files that must stay untracked.
- Commit messages in English, conventional-commit style.
- Python tests: `uv run pytest <path> -v`; Ruby tests: `ruby test/<file>.rb` (one test: `-n <test_name>`), full suite `ruby test/run_all.rb`.

## Review Focus

1. A released 0.3.x plugin still sends `max_compatible_python` (a developer's master client against the installed 0.3.1 plugin): `get_version` must ignore it — no `max_*` keys in its output, verdict from `min_compatible_python` alone. Pinned in Task 1.
2. The plugin's `min_compatible_python` is present but not a string (`3`, `null`): `get_version` returns `compatible=false` with the "sent no valid" text instead of raising. Pinned in Task 1.
3. A future client sends extra `hello` params: the plugin validates only `client_version` and completes the handshake. Pinned in Task 2.
4. A future plugin adds fields to the `hello` result: the client ignores them and connects. Pinned in Task 1.
5. `msg_python_missing` must carry the same `uvx sketchup-mcp2@latest` hint as `msg_python_too_old`, so nobody updates one message and forgets the other. Pinned in Task 2.

## File Structure

| File | Change |
|---|---|
| `src/sketchup_mcp/compat.py` | floors-only `check_ruby_version`; delete `MAX_RUBY`, `_msg_ruby_too_new`; new messages and comments |
| `src/sketchup_mcp/tools.py` (`get_version`, lines 805–886) | payload without `max_*`; floors-only two-way verdict |
| `examples/smoke_check.py` (header lines 7–9, step 25 lines 327–343) | step 25 without `max` |
| `tests/test_compat.py`, `tests/test_version_tool.py`, `tests/test_connection.py` | tests for the above |
| `mcp_for_sketchup/mcp_for_sketchup/core/compat.rb` | floors-only `check_python_version`; delete `MAX_PYTHON`, `msg_python_too_new`; `UPGRADE_CLIENT_HINT` |
| `mcp_for_sketchup/mcp_for_sketchup/handlers/system.rb` | payload without `max_compatible_python` |
| `test/test_compat.rb`, `test/test_system.rb`, `test/test_server_handshake.rb`, `test/test_version_pair.rb` | tests for the above; comment fix |
| `docs/release.md`, `CLAUDE.md`, `README.md` | the new rule and release process |

Tasks 1 and 2 are independent; Task 3 needs both (it records the final test counts).

---

### Task 1: Python side — floors-only handshake check and `get_version`

**Files:**
- Modify: `src/sketchup_mcp/compat.py`
- Modify: `src/sketchup_mcp/tools.py:805-886`
- Modify: `examples/smoke_check.py:7-9,327-343`
- Test: `tests/test_compat.py`, `tests/test_version_tool.py`, `tests/test_connection.py`

**Interfaces:**
- Consumes: the Ruby `get_version` payload keys `ruby_version` and `min_compatible_python` (Task 2 keeps both; released plugins also send `max_compatible_python`, which this task ignores). `compat.rb` must keep `SERVER_VERSION` and `MIN_PYTHON` as double-quoted string constants on their own lines — `test_in_repo_pair_is_compatible` reads them with a regex.
- Produces: `compat.MIN_RUBY: str` (unchanged value `"0.3.0"`); `compat.check_ruby_version(server_version: str | None) -> None` raising `IncompatibleVersionError` only for missing / unparseable / older-than-`MIN_RUBY`; `compat.MAX_RUBY` no longer exists. The `get_version` tool returns JSON with exactly the keys `python_version`, `ruby_version`, `min_compatible_ruby`, `ruby_min_compatible_python`, `compatible`, `error`.

- [ ] **Step 1: Write the failing compat tests**

In `tests/test_compat.py`, replace the import block at the top:

```python
"""Tests for sketchup_mcp.compat — version parsing and Ruby compatibility check."""
import pytest

from sketchup_mcp import compat
from sketchup_mcp.errors import IncompatibleVersionError
```

with:

```python
"""Tests for sketchup_mcp.compat — version parsing and Ruby compatibility check."""
import re
from pathlib import Path

import pytest

from sketchup_mcp import compat
from sketchup_mcp.errors import IncompatibleVersionError
```

Then replace everything from the line `# -------- check_ruby_version --------` down to (not including) `def test_python_version_matches_installed_metadata():` with:

```python
# -------- check_ruby_version --------

def test_at_min_passes(monkeypatch):
    monkeypatch.setattr(compat, "MIN_RUBY", "0.1.0")
    compat.check_ruby_version("0.1.0")


def test_newer_plugin_accepted(monkeypatch):
    """No upper bound: a plugin released after this client (a plugin-only
    hotfix) passes — the newer side of a pair decides."""
    monkeypatch.setattr(compat, "MIN_RUBY", "0.1.0")
    compat.check_ruby_version("99.0.0")


def test_too_old_raises_with_reinstall_hint(monkeypatch):
    monkeypatch.setattr(compat, "MIN_RUBY", "0.1.0")
    with pytest.raises(IncompatibleVersionError) as exc:
        compat.check_ruby_version("0.0.3")
    msg = str(exc.value)
    assert "0.0.3" in msg and "too old" in msg
    assert "needs plugin v0.1.0 or newer" in msg  # names the floor
    assert "latest mcp_for_sketchup .rbz" in msg
    assert "get_version" in msg  # diagnostic pointer


def test_none_raises_with_pre_dates_hint():
    with pytest.raises(IncompatibleVersionError) as exc:
        compat.check_ruby_version(None)
    msg = str(exc.value)
    assert "pre-dates" in msg
    assert "latest mcp_for_sketchup .rbz" in msg
    assert "get_version" in msg


def test_unparseable_raises_clear_message():
    with pytest.raises(IncompatibleVersionError) as exc:
        compat.check_ruby_version("v1")
    msg = str(exc.value)
    assert "unparseable" in msg
    assert "v1" in msg


_COMPAT_RB = (
    Path(__file__).resolve().parent.parent
    / "mcp_for_sketchup" / "mcp_for_sketchup" / "core" / "compat.rb"
)


def _ruby_const(name: str) -> str:
    """Read a string constant such as ``SERVER_VERSION = "0.3.1"`` from compat.rb."""
    source = _COMPAT_RB.read_text(encoding="utf-8")
    m = re.search(rf'^\s*{name}\s*=\s*"([^"]*)"', source, re.M)
    assert m, f"{name} not found in {_COMPAT_RB}"
    return m.group(1)


def test_in_repo_pair_is_compatible():
    """The client and the plugin in this commit must accept each other.

    Replaces the old MAX pinning tests: it catches a mistyped floor and a
    floor that names a counterpart version this commit does not have yet."""
    server_version = _ruby_const("SERVER_VERSION")
    min_python = _ruby_const("MIN_PYTHON")
    assert compat.parse(compat.MIN_RUBY) <= compat.parse(server_version), (
        f"MIN_RUBY {compat.MIN_RUBY} rejects the in-repo plugin v{server_version}"
    )
    assert compat.parse(min_python) <= compat.parse(compat.CLIENT_VERSION), (
        f"compat.rb MIN_PYTHON {min_python} rejects the in-repo client "
        f"v{compat.CLIENT_VERSION}"
    )


```

This deletes `test_at_max_passes`, `test_too_new_raises_with_upgrade_hint`, `test_min_le_max_invariant` and `test_max_ruby_matches_python_version`. Leave `test_python_version_matches_installed_metadata` and the parse tests untouched.

- [ ] **Step 2: Run the compat tests to verify they fail**

Run: `uv run pytest tests/test_compat.py -v`
Expected: FAIL in `test_newer_plugin_accepted` (IncompatibleVersionError "…is newer than sketchup-mcp2…"), `test_too_old_raises_with_reinstall_hint` (assert on `needs plugin v0.1.0 or newer`) and `test_none_raises_with_pre_dates_hint` (assert on `latest mcp_for_sketchup .rbz`). `test_in_repo_pair_is_compatible` already PASSES — it is a guard, not a driver.

- [ ] **Step 3: Implement the floors-only check in `compat.py`**

Apply these five replacements in `src/sketchup_mcp/compat.py`.

3a. Module docstring — replace:

```python
"""Python↔Ruby version compatibility — single source of truth (Python side).

Mirrored in mcp_for_sketchup/mcp_for_sketchup/core/compat.rb. Both files are updated together
by docs/release.md step 1 at release time.
"""
```

with:

```python
"""Python↔Ruby version compatibility — single source of truth (Python side).

Mirrored in mcp_for_sketchup/mcp_for_sketchup/core/compat.rb. Each side
declares only the OLDEST counterpart it works with; there is no upper bound.
The newer side of a pair knows what changed, so the newer side rejects the
older one. docs/release.md §1 says when the floors move.
"""
```

3b. Policy comment and constants — replace:

```python
# Bumped together with CLIENT_VERSION at release time. See docs/release.md.
# Policy: MAX_* tracks the new release; MIN_* moves only on a release
# that breaks wire/handler contract with the previous counterpart.
# 0.3.0 moved both floors on the batch-1+2 handler-contract break (absolute
# transform position, stricter validation, changed response shapes). 0.3.1 is
# packaging and copy only, so neither floor moved and both 0.3.1 artifacts
# declare 0.3.0..0.3.1. That does NOT make a mixed pair work: each side's MAX_*
# tracks its own release, so an installed 0.3.0 plugin rejects a 0.3.1 client at
# the handshake, and a 0.3.0 client rejects a 0.3.1 plugin. The Python package
# and the .rbz are upgraded together — see docs/release.md.
MIN_RUBY = "0.3.0"
MAX_RUBY = "0.3.1"
```

with:

```python
# Oldest SketchUp plugin this client works with. It moves only when this client
# needs a newer plugin: a contract break raises both floors to that release (as
# 0.3.0 did for the absolute transform position, stricter validation and
# changed response shapes), and a one-sided requirement — say, a new tool that
# calls a new Ruby handler — raises this one alone. A hotfix leaves it put,
# which is what lets a Python-only or plugin-only release talk to the
# counterpart the user already has. Releases up to 0.3.1 still cap the
# counterpart at their own version, so the first release under this rule ships
# both sides.
MIN_RUBY = "0.3.0"
```

3c. `check_ruby_version` docstring — replace:

```python
    """Raise IncompatibleVersionError if the SketchUp plugin version is
    outside [MIN_RUBY, MAX_RUBY] or absent (handshake reply missing
    ``server_version``)."""
```

with:

```python
    """Raise IncompatibleVersionError if the SketchUp plugin version is
    older than MIN_RUBY, unparseable, or absent (handshake reply missing
    ``server_version``). A newer plugin always passes: there is no upper
    bound."""
```

3d. The upper-bound branch — replace:

```python
    if rv < parse(MIN_RUBY):
        raise IncompatibleVersionError(_msg_ruby_too_old(server_version))
    if rv > parse(MAX_RUBY):
        raise IncompatibleVersionError(_msg_ruby_too_new(server_version))
```

with:

```python
    if rv < parse(MIN_RUBY):
        raise IncompatibleVersionError(_msg_ruby_too_old(server_version))
```

3e. Messages — replace everything from `def _msg_ruby_too_old(rv: str) -> str:` to the end of the file (that span holds `_msg_ruby_too_old` with its long comment, `_msg_ruby_too_new` and `_msg_ruby_missing`) with:

```python
def _msg_ruby_too_old(rv: str) -> str:
    # Names the floor and points at the latest plugin: with no upper bound,
    # any plugin at or above MIN_RUBY works, and the newest one is the safe
    # advice.
    return (
        f"SketchUp plugin v{rv} is too old for sketchup-mcp2 v{CLIENT_VERSION} "
        f"(needs plugin v{MIN_RUBY} or newer). "
        "Install the latest mcp_for_sketchup .rbz from the GitHub releases page. "
        "Call `get_version` to inspect handshake state."
    )


def _msg_ruby_missing() -> str:
    return (
        "SketchUp plugin pre-dates version-compat checking. "
        "Install the latest mcp_for_sketchup .rbz from the GitHub releases page. "
        "Call `get_version` to inspect handshake state."
    )
```

- [ ] **Step 4: Run the compat tests to verify they pass**

Run: `uv run pytest tests/test_compat.py -v`
Expected: PASS (all). Other Python test files still reference `compat.MAX_RUBY`; the next steps fix them.

- [ ] **Step 5: Rewrite the `get_version` tool tests**

Replace the whole content of `tests/test_version_tool.py` with:

```python
"""Tests for the get_version MCP tool — registration, payload shape on
compatible/incompatible Ruby responses, and that it always returns a
payload (never raises) even when the underlying call fails."""
import json

import pytest

from sketchup_mcp import compat
from sketchup_mcp.app import mcp

PAYLOAD_KEYS = {
    "python_version",
    "ruby_version",
    "min_compatible_ruby",
    "ruby_min_compatible_python",
    "compatible",
    "error",
}


def _extract_payload(result) -> dict:
    # FastMCP's call_tool returns (content_blocks, structured_dict).
    # Extract text from the first content block.
    blocks = result[0] if isinstance(result, tuple) else result
    text = blocks[0].text if hasattr(blocks[0], "text") else blocks[0]["text"]
    return json.loads(text)


async def _get_version_with_ruby_payload(monkeypatch, ruby_payload: dict) -> dict:
    """Run the tool against a mocked Ruby get_version response."""
    from sketchup_mcp import tools

    async def fake_raw_call(ctx, tool_name, /, **kwargs):
        assert tool_name == "get_version"
        return {
            "content": [{"type": "text", "text": json.dumps(ruby_payload)}],
            "isError": False,
        }

    monkeypatch.setattr(tools, "_raw_call", fake_raw_call)
    return _extract_payload(await mcp.call_tool("get_version", {}))


def test_get_version_is_registered():
    # FastMCP exposes the tool registry; the exact attribute name has
    # historically been _tool_manager._tools. We use the public call_tool
    # path to be robust to internal renames.
    names = set()
    for tool in (mcp._tool_manager._tools if hasattr(mcp, "_tool_manager") else mcp._tools).values():
        names.add(tool.name if hasattr(tool, "name") else tool.fn.__name__)
    assert "get_version" in names


@pytest.mark.asyncio
async def test_get_version_compatible_payload(monkeypatch):
    """A plugin at the client's floor that admits this client: compatible,
    and the payload carries no max_* fields."""
    payload = await _get_version_with_ruby_payload(monkeypatch, {
        "ruby_version": compat.MIN_RUBY,
        "min_compatible_python": compat.CLIENT_VERSION,
    })
    assert set(payload) == PAYLOAD_KEYS
    assert payload["python_version"] == compat.CLIENT_VERSION
    assert payload["ruby_version"] == compat.MIN_RUBY
    assert payload["min_compatible_ruby"] == compat.MIN_RUBY
    assert payload["ruby_min_compatible_python"] == compat.CLIENT_VERSION
    assert payload["compatible"] is True
    assert payload["error"] is None


@pytest.mark.asyncio
async def test_get_version_newer_plugin_is_compatible(monkeypatch):
    """No upper bound: a plugin far newer than the client (a plugin-only
    hotfix) is compatible as long as its floor admits the client."""
    payload = await _get_version_with_ruby_payload(monkeypatch, {
        "ruby_version": "99.0.0",
        "min_compatible_python": compat.CLIENT_VERSION,
    })
    assert payload["compatible"] is True
    assert payload["error"] is None


@pytest.mark.asyncio
async def test_get_version_incompatible_payload(monkeypatch):
    """A plugin older than MIN_RUBY: compatible=false, the error names the floor."""
    monkeypatch.setattr(compat, "MIN_RUBY", "1.0.0")
    payload = await _get_version_with_ruby_payload(monkeypatch, {
        "ruby_version": "0.0.3",
        "min_compatible_python": "0.0.3",
    })
    assert payload["compatible"] is False
    assert payload["ruby_version"] == "0.0.3"
    assert "too old" in payload["error"]
    assert "needs plugin v1.0.0 or newer" in payload["error"]


@pytest.mark.asyncio
async def test_get_version_handles_connection_error(monkeypatch):
    """If get_connection raises ConnectionError, the tool still returns a
    payload (with ruby_version=None, compatible=false)."""
    from sketchup_mcp import tools

    async def failing_raw_call(ctx, tool_name, /, **kwargs):
        raise ConnectionError("not running")

    monkeypatch.setattr(tools, "_raw_call", failing_raw_call)
    payload = _extract_payload(await mcp.call_tool("get_version", {}))
    assert payload["python_version"] == compat.CLIENT_VERSION
    assert payload["ruby_version"] is None
    assert payload["compatible"] is False
    assert "not running" in payload["error"].lower() or "connect" in payload["error"].lower()


@pytest.mark.asyncio
async def test_get_version_returns_payload_on_unknown_tool_error(monkeypatch):
    """Pre-handshake Ruby plugin returns -32601 'unknown tool: get_version'.
    The tool MUST still return a payload (compatible=false, ruby_version=null,
    error=<msg>), NOT raise — preserves the 'always returns a payload'
    contract for the diagnostic tool."""
    from sketchup_mcp import tools
    from sketchup_mcp.errors import SketchUpError

    async def unknown_tool_raw_call(ctx, tool_name, /, **kwargs):
        raise SketchUpError(-32601, "unknown tool: get_version")

    monkeypatch.setattr(tools, "_raw_call", unknown_tool_raw_call)
    payload = _extract_payload(await mcp.call_tool("get_version", {}))
    assert payload["python_version"] == compat.CLIENT_VERSION
    assert payload["ruby_version"] is None
    assert payload["compatible"] is False
    assert "unknown tool" in payload["error"]


@pytest.mark.asyncio
async def test_two_way_compat_drift_detected(monkeypatch):
    """Python's floor admits the plugin, but the plugin's floor
    (min_compatible_python) is above this client. The two-way verdict must
    report compatible=false and name the plugin's requirement."""
    monkeypatch.setattr(compat, "MIN_RUBY", "1.0.0")
    payload = await _get_version_with_ruby_payload(monkeypatch, {
        "ruby_version": "1.0.0",
        "min_compatible_python": "2.0.0",
    })
    assert payload["compatible"] is False
    assert payload["ruby_version"] == "1.0.0"
    assert payload["error"] == (
        "SketchUp plugin v1.0.0 requires sketchup-mcp2 v2.0.0 or newer."
    )


@pytest.mark.asyncio
async def test_get_version_missing_min_compatible_python(monkeypatch):
    """A plugin that advertises no floor: compatible=false, no exception."""
    payload = await _get_version_with_ruby_payload(monkeypatch, {
        "ruby_version": compat.MIN_RUBY,
    })
    assert payload["compatible"] is False
    assert payload["error"] == (
        f"SketchUp plugin v{compat.MIN_RUBY} sent no valid "
        f"min_compatible_python (None)."
    )


@pytest.mark.asyncio
async def test_get_version_non_string_min_compatible_python(monkeypatch):
    """Review focus 2: a non-string floor must not raise out of the tool."""
    payload = await _get_version_with_ruby_payload(monkeypatch, {
        "ruby_version": compat.MIN_RUBY,
        "min_compatible_python": 3,
    })
    assert payload["compatible"] is False
    assert payload["error"] == (
        f"SketchUp plugin v{compat.MIN_RUBY} sent no valid "
        f"min_compatible_python (3)."
    )


@pytest.mark.asyncio
async def test_get_version_ignores_released_plugin_max(monkeypatch):
    """Review focus 1: plugins up to 0.3.1 also send max_compatible_python.
    The tool ignores it — even a max that excludes this client — and never
    echoes a max_* field."""
    payload = await _get_version_with_ruby_payload(monkeypatch, {
        "ruby_version": compat.MIN_RUBY,
        "min_compatible_python": compat.CLIENT_VERSION,
        "max_compatible_python": "0.0.1",
    })
    assert set(payload) == PAYLOAD_KEYS
    assert payload["compatible"] is True
    assert payload["error"] is None
```

- [ ] **Step 6: Run the tool tests to verify they fail**

Run: `uv run pytest tests/test_version_tool.py -v`
Expected: FAIL — every test that reaches `_payload` errors with `AttributeError: module 'sketchup_mcp.compat' has no attribute 'MAX_RUBY'` (surfaced by FastMCP as a tool error); `test_get_version_is_registered` passes.

- [ ] **Step 7: Rewrite `get_version` in `tools.py`**

In `src/sketchup_mcp/tools.py`, replace the whole `get_version` function (from `@mcp.tool()` above `async def get_version(ctx: Context) -> str:` through its final line `return _payload(ruby_version, ruby_min, ruby_max, compatible, error_msg)`) with:

```python
@mcp.tool()
async def get_version(ctx: Context) -> str:
    """Return the server version and Python↔Ruby compatibility verdict.

    Useful as a runtime sanity probe — always returns a payload, even
    when the connection or other tools surface errors. The result is a
    JSON string with fields: python_version, ruby_version,
    min_compatible_ruby, ruby_min_compatible_python, compatible (bool),
    error (string | null).
    """
    def _payload(ruby_version, ruby_min, compatible, error_msg):
        return json.dumps({
            "python_version": compat.CLIENT_VERSION,
            "ruby_version": ruby_version,
            "min_compatible_ruby": compat.MIN_RUBY,
            "ruby_min_compatible_python": ruby_min,
            "compatible": compatible,
            "error": error_msg,
        })

    try:
        raw = await _raw_call(ctx, "get_version")
    except ConnectionError as e:
        return _payload(None, None, False,
                        f"SketchUp not running or extension not started: {e}")
    except SketchUpError as e:
        # Covers old Ruby returning -32601 "unknown tool: get_version"
        # and any other JSON-RPC error envelope. Version compatibility is
        # validated once at connect-time in ``_handshake``; once a
        # connection survives that, tool-level errors here come from the
        # Ruby handler itself (not from per-request version checks).
        return _payload(None, None, False, str(e))

    # Defensive parse: any unexpected shape (missing keys, non-list content,
    # non-string text, invalid JSON, non-dict payload) must STILL produce a
    # payload — the tool's contract is "always returns a payload even on
    # mismatch / error", so a KeyError/IndexError/TypeError/JSONDecodeError
    # escaping here would violate it.
    try:
        ruby_payload = json.loads(raw["content"][0]["text"])
        if not isinstance(ruby_payload, dict):
            raise TypeError(
                f"ruby payload is {type(ruby_payload).__name__}, expected dict"
            )
    except (KeyError, IndexError, TypeError, json.JSONDecodeError) as e:
        return _payload(None, None, False,
                        f"unexpected get_version response shape: {e}")
    ruby_version = ruby_payload.get("ruby_version")
    # Plugins up to 0.3.1 also send max_compatible_python. Ignore it: those
    # plugins reject any newer client at the handshake, so a client that got
    # this far is inside their range anyway.
    ruby_min = ruby_payload.get("min_compatible_python")

    # Two-way compatibility: each side's floor must admit the counterpart.
    # There is no upper bound — the newer side of a pair decides.
    try:
        compat.check_ruby_version(ruby_version)
        python_accepts_ruby, py_error = True, None
    except IncompatibleVersionError as e:
        python_accepts_ruby, py_error = False, str(e)

    try:
        ruby_accepts_python = (
            compat.parse(ruby_min) <= compat.parse(compat.CLIENT_VERSION)
        )
        ruby_error = None if ruby_accepts_python else (
            f"SketchUp plugin v{ruby_version} requires sketchup-mcp2 "
            f"v{ruby_min} or newer."
        )
    except ValueError:
        ruby_accepts_python = False
        ruby_error = (
            f"SketchUp plugin v{ruby_version} sent no valid "
            f"min_compatible_python ({ruby_min!r})."
        )

    compatible = python_accepts_ruby and ruby_accepts_python
    return _payload(ruby_version, ruby_min, compatible, py_error or ruby_error)
```

- [ ] **Step 8: Run the tool tests to verify they pass**

Run: `uv run pytest tests/test_version_tool.py -v`
Expected: PASS (10 tests).

- [ ] **Step 9: Update the connection tests**

Replace every `compat.MAX_RUBY` in `tests/test_connection.py` with `compat.MIN_RUBY` (8 occurrences, all in `hello` fixtures and one assertion):

```bash
sed -i 's/compat\.MAX_RUBY/compat.MIN_RUBY/g' tests/test_connection.py
grep -c 'compat.MAX_RUBY' tests/test_connection.py   # expect 0
```

Then insert these two tests directly after `test_handshake_happy_path_populates_server_version_and_client_id` (the module sets `pytestmark = pytest.mark.asyncio`, so no decorator is needed):

```python
async def test_handshake_accepts_plugin_newer_than_client():
    """No upper bound: a plugin released after this client (a plugin-only
    hotfix) completes the handshake."""
    script = [hello_success("99.0.0", client_id=3)]
    async with FakeServer(script) as fs:
        conn = SketchUpConnection(host=fs.host, port=fs.port, timeout=2.0)
        await conn.connect()
        assert conn._server_version == "99.0.0"
        assert conn._client_id == 3
        await conn.disconnect()


async def test_handshake_ignores_extra_result_fields():
    """Review focus 4: a future plugin may add fields to the hello result;
    the client must still connect."""
    body = json.dumps({
        "jsonrpc": "2.0",
        "result": {
            "server_version": compat.MIN_RUBY,
            "client_id": 5,
            "server_package_version": "99.0.0",
        },
        "id": 0,
    }).encode("utf-8")
    async with FakeServer([encode_frame(body)]) as fs:
        conn = SketchUpConnection(host=fs.host, port=fs.port, timeout=2.0)
        await conn.connect()
        assert conn._server_version == compat.MIN_RUBY
        assert conn._client_id == 5
        await conn.disconnect()
```

- [ ] **Step 10: Run the connection tests**

Run: `uv run pytest tests/test_connection.py -v`
Expected: PASS (both new tests included).

- [ ] **Step 11: Update `examples/smoke_check.py`**

11a. In the module docstring, replace:

```
  2. Ruby SketchUp plugin is installed and started via Plugins → MCP Server →
     Start. The plugin version must satisfy the handshake range declared in
     src/sketchup_mcp/compat.py (MIN_RUBY..MAX_RUBY); step 25 verifies this.
```

with:

```
  2. Ruby SketchUp plugin is installed and started via Plugins → MCP Server →
     Start. The plugin version must be at least MIN_RUBY from
     src/sketchup_mcp/compat.py; step 25 verifies this.
```

11b. Replace step 25 (keep the 8-space indentation):

```python
        step = 25; print(f"[{step}] version handshake — matched pair must report compatible=true")
        # smoke_check.py talks to Ruby directly (no FastMCP), so this returns
        # the raw handlers/system.rb output. Replicate the two-way verdict
        # that src/sketchup_mcp/tools.py::get_version computes.
        ruby_payload = parse(await call(conn, "get_version"))
        ruby_version = ruby_payload["ruby_version"]
        ruby_min_py = ruby_payload["min_compatible_python"]
        ruby_max_py = ruby_payload["max_compatible_python"]
        print(f"    python={compat.CLIENT_VERSION} ruby={ruby_version}")
        print(f"    ruby advertises python compat: {ruby_min_py}..{ruby_max_py}")
        compat.check_ruby_version(ruby_version)
        client = compat.parse(compat.CLIENT_VERSION)
        assert compat.parse(ruby_min_py) <= client <= compat.parse(ruby_max_py), (
            f"Ruby advertised range {ruby_min_py}..{ruby_max_py} rejects "
            f"client {compat.CLIENT_VERSION}"
        )
        print("    matched-pair: compatible=true")
```

with:

```python
        step = 25; print(f"[{step}] version handshake — in-repo pair must report compatible=true")
        # smoke_check.py talks to Ruby directly (no FastMCP), so this returns
        # the raw handlers/system.rb output. Replicate the two-way verdict
        # that src/sketchup_mcp/tools.py::get_version computes: each side's
        # floor must admit the other; there is no upper bound.
        ruby_payload = parse(await call(conn, "get_version"))
        ruby_version = ruby_payload["ruby_version"]
        ruby_min_py = ruby_payload["min_compatible_python"]
        print(f"    python={compat.CLIENT_VERSION} ruby={ruby_version}")
        print(f"    ruby needs python >= {ruby_min_py}")
        compat.check_ruby_version(ruby_version)
        assert compat.parse(ruby_min_py) <= compat.parse(compat.CLIENT_VERSION), (
            f"plugin v{ruby_version} requires client >= {ruby_min_py}, "
            f"this is {compat.CLIENT_VERSION}"
        )
        print("    in-repo pair: compatible=true")
```

11c. Check that the script still compiles:

Run: `uv run python -m py_compile examples/smoke_check.py && echo OK`
Expected: `OK`

- [ ] **Step 12: Run the full Python suite**

Run: `uv run pytest tests/ -q`
Expected: all pass — `181 passed` (177 before: −4 deleted in `test_compat.py`, +2 there, +4 in `test_version_tool.py`, +2 in `test_connection.py`). If the baseline was not 177, the delta must still be +4. Also confirm no Python reference to the removed constant survives:

Run: `git grep -n -E 'MAX_RUBY|max_compatible' -- src tests examples`
Expected: no output.

- [ ] **Step 13: Commit**

```bash
git add src/sketchup_mcp/compat.py src/sketchup_mcp/tools.py examples/smoke_check.py \
        tests/test_compat.py tests/test_version_tool.py tests/test_connection.py
git commit -m "feat: accept a newer plugin at the handshake (floors only, Python side)"
```

---

### Task 2: Ruby side — floors-only handshake check and `get_version`

**Files:**
- Modify: `mcp_for_sketchup/mcp_for_sketchup/core/compat.rb`
- Modify: `mcp_for_sketchup/mcp_for_sketchup/handlers/system.rb`
- Test: `test/test_compat.rb`, `test/test_system.rb`, `test/test_server_handshake.rb`
- Modify (comment only): `test/test_version_pair.rb:1-11`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `MCPforSketchUp::Core::Compat::MIN_PYTHON` (unchanged value `"0.3.0"`, still a double-quoted string constant on its own line — Task 1's `test_in_repo_pair_is_compatible` reads it, and `SERVER_VERSION`, with a regex); `Compat::UPGRADE_CLIENT_HINT` (String); `Compat.check_python_version(client_version)` raising `StructuredError(-32001)` only for nil / unparseable / older-than-`MIN_PYTHON`; `MAX_PYTHON` and `msg_python_too_new` no longer exist. `Handlers::System.get_version(_params)` returns exactly `{ruby_version:, min_compatible_python:}`.

- [ ] **Step 1: Write the failing compat tests**

In `test/test_compat.rb`, replace everything from the line `  # -------- check_python_version --------` to the end of the file with:

```ruby
  # -------- check_python_version --------

  # Safe swap of MIN_PYTHON per-test. The defined?-guard in the ensure block
  # keeps a failed setup from masking the original error with a secondary
  # NameError.
  def with_min(min)
    orig_min = MCPforSketchUp::Core::Compat::MIN_PYTHON
    MCPforSketchUp::Core::Compat.send(:remove_const, :MIN_PYTHON)
    MCPforSketchUp::Core::Compat.const_set(:MIN_PYTHON, min)
    yield
  ensure
    if MCPforSketchUp::Core::Compat.const_defined?(:MIN_PYTHON, false)
      MCPforSketchUp::Core::Compat.send(:remove_const, :MIN_PYTHON)
    end
    MCPforSketchUp::Core::Compat.const_set(:MIN_PYTHON, orig_min) if defined?(orig_min)
  end

  def test_at_min_passes
    with_min("0.1.0") do
      MCPforSketchUp::Core::Compat.check_python_version("0.1.0")  # no raise
    end
  end

  # No upper bound: a client released after this plugin (a Python-only
  # hotfix) passes — the newer side of a pair decides.
  def test_newer_client_accepted
    with_min("0.1.0") do
      MCPforSketchUp::Core::Compat.check_python_version("99.0.0")  # no raise
    end
  end

  def test_too_old_raises_with_upgrade_hint
    with_min("0.1.0") do
      err = assert_raises(MCPforSketchUp::Core::StructuredError) do
        MCPforSketchUp::Core::Compat.check_python_version("0.0.3")
      end
      assert_equal(-32001, err.code)
      assert_includes err.message, "0.0.3"
      assert_includes err.message, "too old"
      assert_includes err.message, "needs client v0.1.0 or newer"
      assert_includes err.message, "uvx sketchup-mcp2@latest"
      assert_includes err.message, "get_version"
    end
  end

  def test_nil_raises_with_pre_dates_hint
    err = assert_raises(MCPforSketchUp::Core::StructuredError) do
      MCPforSketchUp::Core::Compat.check_python_version(nil)
    end
    assert_equal(-32001, err.code)
    assert_includes err.message, "pre-dates"
    # Review focus 5: both client-facing messages share one upgrade hint.
    assert_includes err.message, "uvx sketchup-mcp2@latest",
      "must carry the same upgrade hint as the too-old message"
  end

  def test_unparseable_raises_clear_message
    err = assert_raises(MCPforSketchUp::Core::StructuredError) do
      MCPforSketchUp::Core::Compat.check_python_version("v1")
    end
    assert_equal(-32001, err.code)
    assert_includes err.message, "unparseable"
    assert_includes err.message, "v1"
  end
end
```

This deletes `with_range`, `test_at_max_passes`, `test_too_new_points_forward_and_backward`, `test_min_le_max_invariant` and `test_max_python_matches_server_version`. The parse tests above the section stay untouched.

- [ ] **Step 2: Run the compat tests to verify they fail**

Run: `ruby test/test_compat.rb`
Expected: 3 failures/errors — `test_newer_client_accepted` (StructuredError "…is newer than SketchUp plugin…"), `test_too_old_raises_with_upgrade_hint` (missing `needs client v0.1.0 or newer`), `test_nil_raises_with_pre_dates_hint` (missing `uvx sketchup-mcp2@latest`).

- [ ] **Step 3: Write the failing `get_version` handler test**

In `test/test_system.rb`, replace:

```ruby
    assert_equal MCPforSketchUp::Core::Compat::MIN_PYTHON,      result[:min_compatible_python]
    assert_equal MCPforSketchUp::Core::Compat::MAX_PYTHON,      result[:max_compatible_python]
  end
```

with:

```ruby
    assert_equal MCPforSketchUp::Core::Compat::MIN_PYTHON,      result[:min_compatible_python]
    assert_equal %i[min_compatible_python ruby_version], result.keys.sort,
      "no upper bound: get_version must not advertise max_compatible_python"
  end
```

- [ ] **Step 4: Write the handshake tests**

In `test/test_server_handshake.rb`, insert directly after `test_hello_with_compatible_version_succeeds`:

```ruby
  # No upper bound: a client released after this plugin (a Python-only
  # hotfix) completes the handshake.
  def test_hello_with_newer_client_version_succeeds
    newer = "99.0.0"
    sock = FakeSocket.new(read_chunks: [hello_frame(version: newer)])
    fs = FakeServer.new([sock])
    srv = run_one_tick(fs)
    frames = all_frames(sock.written)
    assert_equal 1, frames.size
    refute frames[0].key?("error"),
      "newer client must not be rejected: #{frames[0]["error"].inspect}"
    assert_equal MCPforSketchUp::Core::Compat::SERVER_VERSION, frames[0]["result"]["server_version"]
    refute sock.closed?
    state = srv.instance_variable_get(:@clients).values.first
    assert state.handshaked
    assert_equal newer, state.client_version
  end

  # Review focus 3: a future client may send extra hello params; the plugin
  # validates only client_version and must still complete the handshake.
  def test_hello_with_extra_params_succeeds
    params = { "client_version" => COMPAT_PYTHON, "client_package_version" => "99.0.0" }
    sock = FakeSocket.new(read_chunks: [hello_frame(params_override: params)])
    fs = FakeServer.new([sock])
    run_one_tick(fs)
    frames = all_frames(sock.written)
    assert_equal 1, frames.size
    refute frames[0].key?("error")
    refute sock.closed?
  end
```

- [ ] **Step 5: Run the handler and handshake tests to verify the expected failures**

Run: `ruby test/test_system.rb; ruby test/test_server_handshake.rb`
Expected: `test_get_version_returns_compat_metadata` FAILS (keys include `max_compatible_python`); in the second file `test_hello_with_newer_client_version_succeeds` FAILS (`-32001` "…is newer than…"), while `test_hello_with_extra_params_succeeds` already PASSES (a pin, not a driver).

- [ ] **Step 6: Implement the floors-only check in `compat.rb`**

Apply these four replacements in `mcp_for_sketchup/mcp_for_sketchup/core/compat.rb`.

6a. Constants — replace:

```ruby
      SERVER_VERSION = "0.3.1"
      MIN_PYTHON   = "0.3.0"
      MAX_PYTHON   = "0.3.1"
```

with:

```ruby
      SERVER_VERSION = "0.3.1"

      # Oldest sketchup-mcp2 client this plugin works with — mirror of
      # compat.py::MIN_RUBY. There is no upper bound: the newer side of a pair
      # knows what changed, so the newer side rejects the older one. Moves only
      # when this plugin needs a newer client (a contract break raises both
      # floors to that release, as in 0.3.0; a one-sided requirement raises this
      # one alone). A hotfix leaves it put. Releases up to 0.3.1 still cap the
      # counterpart at their own version, so the first release under this rule
      # ships both sides.
      MIN_PYTHON   = "0.3.0"

      # Shared by every message that tells the user to upgrade the client.
      # `uvx` — the setup README documents — keeps running its cached version
      # until asked for `@latest`; the pip command covers pip installs.
      UPGRADE_CLIENT_HINT =
        "Upgrade the client: run `uvx sketchup-mcp2@latest` once " \
        "(or `uv pip install --upgrade sketchup-mcp2` for a pip install), " \
        "then restart the MCP client."
```

6b. Method comment — replace:

```ruby
      # Raise MCPforSketchUp::Core::StructuredError(-32001) if client_version is nil,
      # unparseable, or outside [MIN_PYTHON, MAX_PYTHON].
```

with:

```ruby
      # Raise MCPforSketchUp::Core::StructuredError(-32001) if client_version is nil,
      # unparseable, or older than MIN_PYTHON. A newer client always passes.
```

6c. The upper-bound branch — replace:

```ruby
        min = parse(MIN_PYTHON)
        max = parse(MAX_PYTHON)
        if (cv <=> min) < 0
          raise MCPforSketchUp::Core::StructuredError.new(-32001, msg_python_too_old(client_version))
        end
        if (cv <=> max) > 0
          raise MCPforSketchUp::Core::StructuredError.new(-32001, msg_python_too_new(client_version))
        end
      end
```

with:

```ruby
        min = parse(MIN_PYTHON)
        if (cv <=> min) < 0
          raise MCPforSketchUp::Core::StructuredError.new(-32001, msg_python_too_old(client_version))
        end
      end
```

6d. Messages — replace everything from the comment line `      # Names MAX_PYTHON alone, never the MIN..MAX range — mirror of` through the `end` that closes `def self.msg_python_missing` (this span holds `msg_python_too_old` with its comment, `msg_python_too_new` with its T-14 comment, and `msg_python_missing`) with:

```ruby
      # Names the floor — mirror of compat.py::_msg_ruby_too_old. With no upper
      # bound, any client at or above MIN_PYTHON works.
      def self.msg_python_too_old(cv)
        "sketchup-mcp2 v#{cv} is too old for SketchUp plugin v#{SERVER_VERSION} " \
        "(needs client v#{MIN_PYTHON} or newer). Handshake rejected. " \
        "#{UPGRADE_CLIENT_HINT} " \
        "Call `get_version` to inspect handshake state."
      end

      def self.msg_python_missing
        "sketchup-mcp2 client pre-dates version-compat checking. " \
        "Handshake rejected. " \
        "#{UPGRADE_CLIENT_HINT} " \
        "Call `get_version` to inspect handshake state."
      end
```

The closing `    end` / `  end` / `end` of the modules stay as they are.

- [ ] **Step 7: Drop `max_compatible_python` from the handler**

Replace the whole content of `mcp_for_sketchup/mcp_for_sketchup/handlers/system.rb` with:

```ruby
# mcp_for_sketchup/mcp_for_sketchup/handlers/system.rb
module MCPforSketchUp
  module Handlers
    module System
      # Returns the Ruby-side compat metadata. Used by the MCP tool
      # `get_version` (Python wrapper computes the `compatible` flag).
      # Only the floor: there is no upper bound on the client version.
      def self.get_version(_params)
        {
          ruby_version:           MCPforSketchUp::Core::Compat::SERVER_VERSION,
          min_compatible_python:  MCPforSketchUp::Core::Compat::MIN_PYTHON,
        }
      end
    end
  end
end
```

- [ ] **Step 8: Run the three test files to verify they pass**

Run: `ruby test/test_compat.rb && ruby test/test_system.rb && ruby test/test_server_handshake.rb`
Expected: `0 failures, 0 errors` in each.

- [ ] **Step 9: Fix the comment in `test/test_version_pair.rb`**

Replace lines 1–11:

```ruby
# test/test_version_pair.rb
# T-21: у релиза четыре Ruby-литерала версии, правящихся вручную, —
# package.rb VERSION, ext.version в загрузчике mcp_for_sketchup.rb,
# Core::Compat::SERVER_VERSION и Core::Compat::MAX_PYTHON (docs/release.md §1
# предписывает править последние два вместе). Разъезд любой пары даёт .rbz с
# противоречивой самоидентификацией, и все четыре замкнуты на тестовом
# прогоне: здесь сверяются package.rb VERSION и SERVER_VERSION; загрузчик —
# транзитивно, через post-build-проверку внутри package.rb, которую запускает
# тест сборки; MAX_PYTHON — через test/test_compat.rb::
# test_max_python_matches_server_version. Python-сторона закрыта зеркальным
# tests/test_compat.py::test_python_version_matches_installed_metadata.
```

with:

```ruby
# test/test_version_pair.rb
# T-21: у релиза плагина три Ruby-литерала версии, правящихся вручную, —
# package.rb VERSION, ext.version в загрузчике mcp_for_sketchup.rb и
# Core::Compat::SERVER_VERSION (docs/release.md §1). Разъезд любой пары даёт
# .rbz с противоречивой самоидентификацией, и все три замкнуты на тестовом
# прогоне: здесь сверяются package.rb VERSION и SERVER_VERSION; загрузчик —
# транзитивно, через post-build-проверку внутри package.rb, которую запускает
# тест сборки. Python-сторона закрыта зеркальным
# tests/test_compat.py::test_python_version_matches_installed_metadata.
```

- [ ] **Step 10: Run the full Ruby suite**

Run: `ruby test/run_all.rb`
Expected: `0 failures, 0 errors`; `416 runs` (417 before: −4 deleted and +1 added in `test_compat.rb`, +2 in `test_server_handshake.rb`). Write down the runs and assertions counts — Task 3 puts them into `CLAUDE.md`. Also confirm the removed names are gone:

Run: `git grep -n -E 'MAX_PYTHON|max_compatible|too_new|with_range' -- mcp_for_sketchup test`
Expected: no output.

- [ ] **Step 11: Commit**

```bash
git add mcp_for_sketchup/mcp_for_sketchup/core/compat.rb \
        mcp_for_sketchup/mcp_for_sketchup/handlers/system.rb \
        test/test_compat.rb test/test_system.rb test/test_server_handshake.rb \
        test/test_version_pair.rb
git commit -m "feat: accept a newer client at the handshake (floors only, plugin side)"
```

---

### Task 3: Release process and documentation

**Files:**
- Modify: `docs/release.md:34-58,60-69,71,92,100-117,134`
- Modify: `CLAUDE.md:57-67,89-90,141`
- Modify: `README.md:180-182`

**Interfaces:**
- Consumes: the rule and messages from Tasks 1–2; the final test counts from fresh runs in Step 5.
- Produces: documentation only.

- [ ] **Step 1: Rewrite `docs/release.md` §1**

Replace everything from the heading `## 1. Bump version in 6 places (must match)` through the paragraph that begins with "Run `uv lock` to refresh" and ends with "and push." (lines 34–51) with:

```markdown
## 1. Choose the scope, then bump

Releases share one version line. Each release takes the next number — patch for fixes, minor for features and contract breaks — whether it ships the Python package, the plugin, or both. The side a release does not ship keeps its version literals, so every `vX.Y.Z` tag stays unique.

Bump only the side you ship:

- **Python** — `pyproject.toml` (`version = "X.Y.Z"`) and `src/sketchup_mcp/__init__.py` (`__version__ = "X.Y.Z"`). Then run `uv lock` to refresh `uv.lock` with the new project version; otherwise the next `uv` call updates it post-release and you end up with a stray `chore: sync uv.lock` commit.
- **Plugin** — `mcp_for_sketchup/package.rb` (`VERSION = 'X.Y.Z'`), `mcp_for_sketchup/mcp_for_sketchup.rb` (`ext.version = 'X.Y.Z'`) and `mcp_for_sketchup/mcp_for_sketchup/core/compat.rb` (`SERVER_VERSION = "X.Y.Z"`).

**Compatibility floors.** Each side declares only the oldest counterpart it works with: `MIN_RUBY` in `src/sketchup_mcp/compat.py`, `MIN_PYTHON` in `core/compat.rb`. There is no upper bound — the newer side of a pair knows what changed, so the newer side rejects the older one. Decide per release:

- A hotfix, or a feature with no new requirement, leaves both floors alone.
- When one side starts to need a newer counterpart — say, a new Python tool calls a new Ruby handler — raise that side's floor to the first counterpart version that has what it needs.
- A contract break (an existing message changes meaning or shape) ships both sides, and both floors rise to this release's version. Forget a floor here and an incompatible pair passes the handshake: the older side cannot stop it.

`tests/test_compat.py::test_in_repo_pair_is_compatible` checks that the client and the plugin in the same commit accept each other.

**Contract break of v0.3.0 (2026-07-02; batches 1+2, branch `fix/deep-review-p2`):** `transform_component.position` switched from a relative offset to an absolute bbox-min target (`feat!`, commit `6b7d133`), so an old/new client–server mix would pass the handshake but silently misplace geometry. Batch 2 widened the break with new tool parameters, stricter validation and changed response shapes. v0.3.0 raised both floors to `0.3.0`.

**Releases up to 0.3.1 cap the counterpart at their own version.** An installed 0.3.0 plugin accepts only a 0.3.0 client, a 0.3.1 plugin accepts 0.3.0–0.3.1, and the 0.3.x clients mirror this. Every later release looks too new to them, so the first release after 0.3.1 must ship both sides — see the release-notes checklist in [§6](#6-git-tag--github-release).

Commit (`chore: bump to vX.Y.Z`) and push.
```

- [ ] **Step 2: Update `docs/release.md` §2–§6**

2a. §2 — between the heading `## 2. Pre-flight tests` and its bash block, insert this paragraph followed by a blank line:

```markdown
Run both suites for every release, one-sided ones included: the client and the plugin in this commit must stay a working pair.
```

2b. §3 — replace the bash block under `## 3. Build artifacts`:

````markdown
```bash
rm -rf dist/ mcp_for_sketchup/*.rbz
uv build                                              # → dist/*.whl + dist/*.tar.gz
uvx twine check dist/*                                # validate metadata / README rendering
(cd mcp_for_sketchup && ruby package.rb)   # → mcp_for_sketchup_vX.Y.Z.rbz
```
````

with:

````markdown
Build only the side you ship:

```bash
# Python
rm -rf dist/
uv build                                              # → dist/*.whl + dist/*.tar.gz
uvx twine check dist/*                                # validate metadata / README rendering

# Plugin
rm -f mcp_for_sketchup/*.rbz
(cd mcp_for_sketchup && ruby package.rb)   # → mcp_for_sketchup_vX.Y.Z.rbz
```
````

2c. §4 and §5 — directly under the headings `## 4. TestPyPI rehearsal` and `## 5. Production PyPI`, insert the line `Python releases only.` followed by a blank line.

2d. §6 — replace the first paragraph under `## 6. Git tag + GitHub Release` (it begins with "Attach the `.rbz`" and ends with "(*Identified Extensions Only*).") with:

````markdown
Every release carries the current artifacts of **both** sides, so the latest release page always offers the plugin and the client — the handshake error messages send users there. Attach what you built in [§3](#3-build-artifacts), and re-attach the unchanged side's files from the previous release (`vPREV`):

```bash
# Python-only release: the current signed plugin
rm -f mcp_for_sketchup/*.rbz && gh release download vPREV -p '*-signed.rbz' -D mcp_for_sketchup
# Plugin-only release: the current wheel + sdist
rm -rf dist/ && gh release download vPREV -p 'sketchup_mcp2-*' -D dist
```

The `.rbz` must already be self-signed via the [Trimble signing service](https://extensions.sketchup.com/developer/sign-extension) — an unsigned extension is flagged as unidentified, and SketchUp blocks it outright under the strictest loading policy (*Identified Extensions Only*).
````

2e. In the `gh release create` block, replace the three artifact lines:

```
  dist/sketchup_mcp2-X.Y.Z-py3-none-any.whl \
  dist/sketchup_mcp2-X.Y.Z.tar.gz \
  mcp_for_sketchup/mcp_for_sketchup_vX.Y.Z-signed.rbz
```

with (the unchanged side keeps its older version number, hence the globs):

```
  dist/sketchup_mcp2-*-py3-none-any.whl \
  dist/sketchup_mcp2-*.tar.gz \
  mcp_for_sketchup/mcp_for_sketchup_v*-signed.rbz
```

2f. Replace:

```markdown
Release notes must call out anything a user upgrading in place would otherwise
discover the hard way. For `0.3.1`:
```

with:

```markdown
Release notes must say which side the release ships and the oldest counterpart it works with: "works with plugin ≥ vMIN_RUBY" for the client, "works with sketchup-mcp2 ≥ vMIN_PYTHON" for the plugin.

**First release after 0.3.1 (one-time):** it ships both sides, and its notes must ask every user to upgrade both once — releases up to 0.3.1 accept only a counterpart of their own version (see [§1](#1-choose-the-scope-then-bump)). Give the client command explicitly: `uvx sketchup-mcp2@latest`, then restart the MCP client. The 0.3.x client's own hint, `uv pip install --upgrade sketchup-mcp2`, does not refresh a `uvx` install.

Release notes must also call out anything a user upgrading in place would otherwise
discover the hard way. For `0.3.1`:
```

2g. In the last `0.3.1` bullet, replace the link `(see [§1](#1-bump-version-in-6-places-must-match))` with `(see [§1](#1-choose-the-scope-then-bump))`.

- [ ] **Step 3: Update `CLAUDE.md`**

3a. Replace the "Version handshake" bullet:

```markdown
- **Version handshake (one-time on connect)**: every TCP connection MUST
  begin with a JSON-RPC `hello` request carrying
  `params.client_version`. The server validates against
  `core/compat.rb`'s `MIN_PYTHON`..`MAX_PYTHON` range and replies with
  `{server_version, client_id}` in `result`. Mismatches return JSON-RPC
  error `-32001` (`IncompatibleVersionError` on the Python side) and
  the server closes the socket. After a successful handshake, regular
  `tools/call` requests carry no `client_version` field and responses
  carry no `server_version` field. Compatibility ranges live in
  `src/sketchup_mcp/compat.py` and `mcp_for_sketchup/mcp_for_sketchup/core/compat.rb`.
  `get_version` remains a regular tool returning the verdict payload.
```

with:

```markdown
- **Version handshake (one-time on connect)**: every TCP connection MUST
  begin with a JSON-RPC `hello` request carrying
  `params.client_version`. The server rejects a client older than
  `core/compat.rb`'s `MIN_PYTHON`; the client rejects a plugin older than
  `compat.py`'s `MIN_RUBY`. There is **no upper bound**: the newer side of
  a pair knows what changed, so it rejects the older one, and a
  Python-only or plugin-only release talks to the installed counterpart.
  The server replies with `{server_version, client_id}` in `result`.
  Mismatches return JSON-RPC error `-32001` (`IncompatibleVersionError`
  on the Python side) and the server closes the socket. After a
  successful handshake, regular `tools/call` requests carry no
  `client_version` field and responses carry no `server_version` field.
  When to raise the floors: `docs/release.md` §1. Releases up to 0.3.1
  still cap the counterpart at their own version. `get_version` remains a
  regular tool returning the verdict payload.
```

3b. In the Python-side table, replace `(MIN_RUBY, MAX_RUBY, check_ruby_version)` with `(MIN_RUBY, check_ruby_version)`.

3c. The test counts (lines 89–90) are updated in Step 5.

- [ ] **Step 4: Update `README.md`**

Replace the paragraph under the heading ``### `IncompatibleVersionError` ``:

```markdown
Your installed `sketchup-mcp2` Python package and the `.rbz` extension are outside the supported version range. Rebuild the `.rbz` from the same commit as the Python package, or `pip install -U sketchup-mcp2`. The current supported range lives in `src/sketchup_mcp/compat.py` and `mcp_for_sketchup/mcp_for_sketchup/core/compat.rb`.
```

with:

```markdown
One side is older than the other accepts. The message names the outdated side and the minimum version it needs:

- **Client too old** — upgrade the Python package: run `uvx sketchup-mcp2@latest` once (or `uv pip install -U sketchup-mcp2` for a pip install), then restart your MCP client. A plain `uvx sketchup-mcp2` keeps running its cached version.
- **Plugin too old** — install the latest `.rbz` from [GitHub Releases](https://github.com/zinin/sketchup-mcp2/releases).

Each side declares only the oldest counterpart it works with, so being newer never fails the handshake. Releases up to 0.3.1 are the exception: they accept only a counterpart of their own version, so moving past 0.3.1 means upgrading both once. The floors live in `src/sketchup_mcp/compat.py` (`MIN_RUBY`) and `mcp_for_sketchup/mcp_for_sketchup/core/compat.rb` (`MIN_PYTHON`).
```

- [ ] **Step 5: Run both suites fresh and record the counts**

Run: `uv run pytest tests/ -q`
Expected: `181 passed` (or the Task 1 count).

Run: `ruby test/run_all.rb`
Expected: `416 runs, <N> assertions, 0 failures, 0 errors, 0 skips` (or the Task 2 count).

Put the numbers into `CLAUDE.md`: in `ruby test/run_all.rb … — 417 runs / 1124 assertions` replace `417 runs / 1124 assertions` with the new runs and assertions; in `uv run pytest tests/ -q … — 177 tests` replace `177` with the new count.

- [ ] **Step 6: Verify the documentation**

Run: `git grep -n -E 'MAX_RUBY|MAX_PYTHON|max_compatible|too_new' -- . ':!docs/superpowers'`
Expected: no output.

Run: `grep -n '1-bump-version' docs/release.md`
Expected: no output.

Run: `grep -n '#1-choose-the-scope-then-bump\|#6-git-tag--github-release' docs/release.md`
Expected: two hits for the §1 anchor (§6 checklist and the 0.3.1 bullet) and one for the §6 anchor (end of §1).

- [ ] **Step 7: Commit**

```bash
git add docs/release.md CLAUDE.md README.md
git commit -m "docs: one-sided releases and compatibility floors"
```

---

## Final acceptance (controller, after all tasks)

- [ ] Fresh runs: `uv run pytest tests/ -q` and `ruby test/run_all.rb` both green; counts match `CLAUDE.md`.
- [ ] `git grep -n -E 'MAX_RUBY|MAX_PYTHON|max_compatible|too_new' -- . ':!docs/superpowers'` prints nothing.
- [ ] Live smoke check (needs the user — SketchUp runs on their machine):
  1. `cd mcp_for_sketchup && ruby package.rb && cd ..` builds `mcp_for_sketchup/mcp_for_sketchup_v0.3.1.rbz` from this branch.
  2. The user installs that `.rbz` in SketchUp (Extension Manager → Install Extension) and starts the server (Plugins → MCP Server → Start).
  3. `uv run python examples/smoke_check.py` (split host: prefix `SKETCHUP_MCP_HOST=<ip>`) ends with `ALL STEPS PASSED ✓`, and step 25 prints `in-repo pair: compatible=true`.
- [ ] Before opening the PR: `git rm -r docs/superpowers/` (removes only the tracked spec and plan; the old untracked files stay on disk) and commit `chore: drop planning docs from the PR diff`.
