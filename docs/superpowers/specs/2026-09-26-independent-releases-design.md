# Design: Independent Python and plugin releases

- **Date**: 2026-09-26
- **Status**: Draft — awaiting user review
- **Branch**: `feature/independent-releases` (from `master` at `9e987d6`)
- **Target**: merge to `master` without a release; ships with the next
  paired release (§4)
- **Author**: Alexander V. Zinin (with Claude Code)

## 1. Problem

The version handshake accepts only pairs of equal versions. Each side caps
its counterpart at its own version: `compat.py` sets `MAX_RUBY` to
`CLIENT_VERSION`, `compat.rb` sets `MAX_PYTHON` to `SERVER_VERSION`, and
`test_max_ruby_matches_python_version` / `test_max_python_matches_server_version`
pin both caps. A release of either side therefore looks "too new" to the
installed counterpart. A Python hotfix cannot ship without a plugin release
(a newly signed `.rbz`), and a plugin hotfix cannot ship without a PyPI
release.

The cap also sits on the wrong side. The older component enforces the upper
bound, yet only the newer component can know whether it still speaks the
older one's contract.

## 2. Goals and non-goals

Goals:

- From the first release that carries this change on, a release of one side
  completes the handshake with the counterpart the user already has, unless
  the release declares that it needs a newer counterpart.
- Incompatible pairs still fail the handshake (`-32001` /
  `IncompatibleVersionError`), and the message names the outdated side and
  the minimum version it needs.
- The release process supports Python-only, plugin-only and paired releases.

Non-goals:

- Changing released versions. Every version up to 0.3.1 caps the counterpart
  at its own version, and nothing already shipped can change that. The
  transition costs one paired release (§4).
- Handshake changes. `hello` keeps `params.client_version`; its reply keeps
  `server_version` and `client_id`.
- A separate protocol version, or compatibility by equal `MAJOR.MINOR`
  (rejected, §10).
- Capability negotiation or per-tool version gates.
- A live cross-version run, such as Python 0.3.2 against a 0.3.1 plugin.
  Unit and handshake tests cover that scenario (§6).

## 3. The rule

Each side declares only the oldest counterpart it works with:

- `MIN_RUBY` in `src/sketchup_mcp/compat.py` — the oldest plugin this client
  works with.
- `MIN_PYTHON` in `mcp_for_sketchup/mcp_for_sketchup/core/compat.rb` — the
  oldest client this plugin works with.

There is no upper bound. The newer side of a pair knows what changed, so the
newer side rejects the older one. Examples on the shared version line (§7.1):

| Pair | Outcome |
|---|---|
| Python 0.4.1 (hotfix) + plugin 0.4.0 | connects |
| plugin 0.4.2 (hotfix) + Python 0.4.1 | connects |
| Python 0.5.0 (contract break, `MIN_RUBY = "0.5.0"`) + plugin 0.4.2 | the plugin accepts the client; Python rejects the plugin as too old, needs ≥ 0.5.0 |
| plugin 0.5.0 (`MIN_PYTHON = "0.5.0"`) + Python 0.4.1 | the plugin rejects the client as too old, needs ≥ 0.5.0 |

Floor policy, applied at release time (§7.2):

- A hotfix, or a feature with no new requirement, leaves both floors alone.
- When one side starts to need a newer counterpart — say, a new Python tool
  calls a new Ruby handler — that side raises its own floor to the first
  counterpart version that has what it needs.
- A contract break (an existing message changes meaning or shape, as in
  0.3.0) ships as a paired release, and both floors rise to that release's
  version.

Risk: a breaking release that forgets to raise a floor lets an incompatible
pair through the handshake, and the older side cannot stop it. Only the
release checklist (§7.2) guards against this — the same discipline that
raised both floors in 0.3.0.

## 4. Transition

Released versions keep their caps:

| Release | Plugin accepts clients | Client accepts plugins |
|---|---|---|
| v0.3.0 | 0.3.0 only | 0.3.0 only |
| v0.3.1 | 0.3.0–0.3.1 | 0.3.0–0.3.1 |

Every release after 0.3.1 carries a higher version, so an installed 0.3.x
component rejects it as too new. The first release that carries this change
must therefore ship both sides, and its notes must ask users to upgrade both
once. The old components point the right way: a 0.3.x plugin suggests a newer
`.rbz`, and a 0.3.x client suggests upgrading the package. The client's
command, `uv pip install --upgrade sketchup-mcp2`, does not refresh a `uvx`
install, so the notes must give `uvx sketchup-mcp2@latest` (§5.4). One-sided
releases work from then on.

`MIN_RUBY` and `MIN_PYTHON` stay `"0.3.0"` on `master`, the version of the
last contract break. The next release decides whether to raise them.

## 5. Changes

### 5.1 `src/sketchup_mcp/compat.py`

- Delete `MAX_RUBY`, the `rv > MAX_RUBY` branch of `check_ruby_version` and
  `_msg_ruby_too_new`.
- `check_ruby_version` raises only for a missing, unparseable or
  older-than-`MIN_RUBY` version.
- Rewrite the module docstring, the policy comment above `MIN_RUBY` and the
  comment in `_msg_ruby_too_old` to state the rule of §3.
- Messages: §5.4.

### 5.2 `mcp_for_sketchup/mcp_for_sketchup/core/compat.rb`

- Delete `MAX_PYTHON`, the `cv > max` branch of `check_python_version` and
  `msg_python_too_new`.
- `check_python_version` raises only for a nil, unparseable or
  older-than-`MIN_PYTHON` version.
- Rewrite the comments that explain exact-match pairing.
- Messages: §5.4. One constant holds the client upgrade hint that both
  messages share.

`core/server.rb` and `src/sketchup_mcp/connection.py` do not change; they
only call the checks.

### 5.3 `get_version`

- `handlers/system.rb` returns `ruby_version` and `min_compatible_python`;
  `max_compatible_python` goes.
- `tools.py::get_version` drops `max_compatible_ruby` and
  `ruby_max_compatible_python` from its payload and its docstring.
  `compatible` is true when both conditions hold:
  - Python accepts the plugin: `check_ruby_version(ruby_version)` passes;
  - the plugin accepts Python:
    `parse(min_compatible_python) <= parse(CLIENT_VERSION)`.
- The tool ignores `max_compatible_python`. Only released plugins send it, and
  their handshake rejects any newer client before `get_version` can run.
- Dropping `max_compatible_python` changes the shape of an existing response,
  which §3 counts as a contract break. No released client can observe it,
  though: each one rejects any newer plugin at the handshake (§4). The floors
  therefore stay put for this change.

### 5.4 Messages

Python, `compat.py`:

- Plugin too old:
  ``SketchUp plugin v{rv} is too old for sketchup-mcp2 v{CLIENT_VERSION} (needs plugin v{MIN_RUBY} or newer). Install the latest mcp_for_sketchup .rbz from the GitHub releases page. Call `get_version` to inspect handshake state.``
- Version missing:
  ``SketchUp plugin pre-dates version-compat checking. Install the latest mcp_for_sketchup .rbz from the GitHub releases page. Call `get_version` to inspect handshake state.``
- Version unparseable: unchanged.

Ruby, `compat.rb`:

- Client too old:
  ``sketchup-mcp2 v#{cv} is too old for SketchUp plugin v#{SERVER_VERSION} (needs client v#{MIN_PYTHON} or newer). Handshake rejected. <hint> Call `get_version` to inspect handshake state.``
- Version missing:
  ``sketchup-mcp2 client pre-dates version-compat checking. Handshake rejected. <hint> Call `get_version` to inspect handshake state.``
- `<hint>`:
  ``Upgrade the client: run `uvx sketchup-mcp2@latest` once (or `uv pip install --upgrade sketchup-mcp2` for a pip install), then restart the MCP client.``
  The current hint, ``Run: uv pip install --upgrade sketchup-mcp2``, does
  nothing for the `uvx` setup that README documents: `uvx` keeps running its
  cached version until asked for `@latest` (uv documentation, "Tool
  versions").
- Version unparseable: unchanged.

`tools.py::get_version`, when the plugin does not accept the client:

- ``SketchUp plugin v{ruby_version} requires sketchup-mcp2 v{ruby_min} or newer.``
- When `min_compatible_python` is missing or unparseable:
  ``SketchUp plugin v{ruby_version} sent no valid min_compatible_python ({ruby_min!r}).``

### 5.5 `examples/smoke_check.py`

- Step 25 checks the two conditions of §5.3 without `max` and reads
  "in-repo pair must report compatible=true".
- The header (lines 8–9) requires a plugin version of at least `MIN_RUBY`.

## 6. Tests

Python (pytest):

- `tests/test_compat.py`
  - delete `test_at_max_passes`, `test_too_new_raises_with_upgrade_hint`,
    `test_min_le_max_invariant` and `test_max_ruby_matches_python_version`;
  - `test_too_old_raises_with_reinstall_hint` and
    `test_none_raises_with_pre_dates_hint` assert the new texts
    (`needs plugin v… or newer`, `latest mcp_for_sketchup .rbz`);
  - add `test_newer_plugin_accepted`: `check_ruby_version("99.0.0")` passes;
  - add `test_in_repo_pair_is_compatible`: read `SERVER_VERSION` and
    `MIN_PYTHON` from `compat.rb` with a regex, fail loudly if either is
    missing, and assert `MIN_RUBY <= SERVER_VERSION` and
    `MIN_PYTHON <= CLIENT_VERSION`. It replaces the pinning tests: it catches a
    mistyped floor and a floor that names an unreleased counterpart;
  - drop every `monkeypatch.setattr(compat, "MAX_RUBY", …)`;
  - the parse tests and `test_python_version_matches_installed_metadata` stay.
- `tests/test_version_tool.py`
  - the payload has no `max_*` fields;
  - add: a plugin newer than the client gives `compatible=true`;
  - `test_two_way_compat_drift_detected` stays (the plugin's
    `min_compatible_python` exceeds the client, so `compatible=false`) and
    asserts the new error text;
  - add: a missing `min_compatible_python` gives `compatible=false` with the
    §5.4 text;
  - drop every `monkeypatch.setattr(compat, "MAX_RUBY", …)`.
- `tests/test_connection.py`
  - every `compat.MAX_RUBY` in `hello` fixtures becomes `compat.MIN_RUBY`;
  - add: a `hello` reply whose `server_version` is newer than the client
    connects.

Ruby (minitest):

- `test/test_compat.rb`
  - the helper `with_range(min, max)` becomes `with_min(min)`;
  - delete `test_at_max_passes`, `test_too_new_points_forward_and_backward`,
    `test_min_le_max_invariant` and `test_max_python_matches_server_version`;
  - `test_too_old_raises_with_upgrade_hint` asserts
    `needs client v… or newer` and `uvx sketchup-mcp2@latest`;
  - add `test_newer_client_accepted`.
- `test/test_system.rb`: the payload has no `max_compatible_python`.
- `test/test_server_handshake.rb`: add a `hello` whose `client_version` is
  newer than `SERVER_VERSION`; the handshake succeeds. The existing rejection
  test sends `0.0.0` and stays.
- `test/test_version_pair.rb`: the comment names `MAX_PYTHON`; update it.

Live: `examples/smoke_check.py` passes 25/25 against SketchUp running the
plugin built from the same commit.

## 7. Release process (`docs/release.md`)

### 7.1 Numbering

Releases share one version line. Each release takes the next number — patch
for fixes, minor for features and contract breaks — whether it ships Python,
the plugin or both. The side a release does not ship keeps its version
literals, so every `vX.Y.Z` tag stays unique and the GitHub release list stays
linear.

### 7.2 §1, rewritten

Replace "Bump version in 6 places (must match)" with:

1. Choose the scope: Python, plugin, or both.
2. Bump only the shipped side:
   - Python — `pyproject.toml` (`version`) and `src/sketchup_mcp/__init__.py`
     (`__version__`), then `uv lock`;
   - plugin — `mcp_for_sketchup/package.rb` (`VERSION`),
     `mcp_for_sketchup/mcp_for_sketchup.rb` (`ext.version`) and
     `core/compat.rb` (`SERVER_VERSION`).
3. Apply the floor policy of §3 to `MIN_RUBY` and `MIN_PYTHON`.
4. Keep the record of the v0.3.0 contract break, condensed. Drop the
   exact-match explanation and the list of three invariant tests;
   `test_in_repo_pair_is_compatible` and the existing version-pair tests
   replace them.

### 7.3 Build and publish (§2–§6)

- §2: always run both suites. The in-repo pair must stay green even for a
  one-sided release.
- §3–§5: build and publish only the shipped side — Python: `uv build`,
  `twine check`, TestPyPI, PyPI; plugin: `package.rb` and Trimble signing.
- §6: every GitHub release carries the current artifacts of both sides.
  Re-attach the unchanged side's files from the previous release:
  `gh release download vPREV -p '*-signed.rbz'` for the plugin,
  `gh release download vPREV -p 'sketchup_mcp2-*'` for the wheel and sdist.
  Otherwise the latest release page lacks a `.rbz` after a Python-only
  release, and the new messages send users exactly there. The notes state
  which side changed and the minimum counterpart: "works with plugin
  ≥ vMIN_RUBY" or "works with sketchup-mcp2 ≥ vMIN_PYTHON".
- The release-notes checklist gains a one-time item: the first release under
  this rule ships both sides and asks users to upgrade both once, giving
  `uvx sketchup-mcp2@latest` for the client (§4).
- The 0.3.1 notes link to §1 by anchor; update the link to the new heading.

## 8. Other documentation

- `CLAUDE.md`, "Version handshake": the server rejects a client older than
  `MIN_PYTHON`, and the client rejects a plugin older than `MIN_RUBY`; there
  is no upper bound, and the newer side decides. The `compat.py` row loses
  `MAX_RUBY`. The test counts follow the final run.
- `README.md`, `IncompatibleVersionError`: the message names the outdated side
  and the version it needs. Upgrade Python with `uvx sketchup-mcp2@latest`
  (or `uv pip install -U sketchup-mcp2`) and the plugin with the latest
  `.rbz` from GitHub Releases. Versions up to 0.3.1 work only with a
  counterpart of the same version. Drop "Rebuild the `.rbz` from the same
  commit".
- The header comments of `compat.py` and `compat.rb` state the rule of §3.

## 9. Acceptance criteria

- [ ] `uv run pytest tests/ -q` and `ruby test/run_all.rb` pass.
- [ ] `git grep -n -E 'MAX_RUBY|MAX_PYTHON|max_compatible|too_new'` finds
      nothing outside `docs/superpowers/`.
- [ ] A plugin newer than the client, and a client newer than the plugin,
      both complete the handshake (unit and handshake tests on both sides).
- [ ] A counterpart older than the floor fails with the §5.4 text.
- [ ] The `get_version` payload has no `max_*` fields.
- [ ] `examples/smoke_check.py` passes 25/25 against a live SketchUp running
      the plugin built from the same commit.
- [ ] `docs/release.md`, `CLAUDE.md` and `README.md` describe the new rule and
      the new release process.

## 10. Decisions

| Decision | Resolution |
|---|---|
| Compatibility rule | **Floors only; the newer side decides** (option A). Rejected: B, a separate integer protocol version — a second notion of version, and "needs plugin ≥ X" cannot be expressed without raising the protocol for everyone; C, equal `MAJOR.MINOR` — every minor release of one side breaks compatibility, forcing features into patches or paired releases. |
| Support for released versions | **None.** Considered: send a contract version (`"0.3.0"`) in the existing `client_version` / `server_version` fields, which every 0.3.x build accepts. Rejected by the user: one paired release is acceptable. |
| Wire format | **Unchanged.** |
| Version numbering | **One shared line**; the side a release does not ship keeps its literals. |
| GitHub release assets | **Current artifacts of both sides** on every release. |
| Client upgrade hint | **`uvx sketchup-mcp2@latest`**, with the pip command as the alternative, then restart the MCP client. |
| Guard against a bad floor | **`test_in_repo_pair_is_compatible`** replaces the `MAX` pinning tests. |
| Live cross-version run | **Not done**; unit and handshake tests on both sides cover it. |
