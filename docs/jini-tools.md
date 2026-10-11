# jini-tools: inspection, scene and plugin-development tools

The `jini-tools` branch adds 14 MCP tools to sketchup-mcp2. They cover what
the upstream set leaves to `eval_ruby`:

- checking the geometry a plugin built;
- finding faces and points in world coordinates;
- showing one part on its own;
- working out why the viewport is slow;
- reloading plugin code without restarting SketchUp.

| Group | Tool | What it answers | Changes the model? |
|---|---|---|---|
| Inspection | [`get_edit_context`](#get_edit_context) | Where is the user: open group, selection, camera | no |
| | [`solid_report`](#solid_report) | Is each part a closed solid, how big, where are its holes; what changed since the last build | no |
| | [`query_faces`](#query_faces) | Which faces point this way, sit in this box, carry this tag or material | no |
| | [`find_overlaps`](#find_overlaps) | Which parts interpenetrate, rather than just touch | no |
| | [`raycast`](#raycast) | What lies along this line | no |
| | [`scene_stats`](#scene_stats) | How many faces the scene really draws, and which definitions cost most | no |
| | [`get_attributes`](#get_attributes) | What plugin data an entity carries | no |
| Scene | [`select_entities`](#select_entities) | Point the user at something | selection only |
| | [`set_entity_properties`](#set_entity_properties) | Tag, hide, lock or rename many entities | yes, one Undo step |
| | [`set_attributes`](#set_attributes) | Write or delete attribute keys | yes, one Undo step |
| | [`capture_view`](#capture_view) | A picture of chosen entities, isolated and framed | no (rolled back) |
| | [`profile_view`](#profile_view) | Milliseconds per frame, still or orbiting | no (camera restored) |
| Plugin development | [`eval_ruby_dry_run`](#eval_ruby_dry_run) | What would this code do, without keeping it | no (rolled back) |
| | [`reload_ruby`](#reload_ruby) | Hot-load edited `.rb` files | runs your code |

The two plugin-development tools run Ruby, so they sit behind the same gate
as `eval_ruby`.

---

## Contents

1. [Installing the branch](#installing-the-branch)
2. [Conventions shared by every tool](#conventions-shared-by-every-tool)
3. [Tool reference](#tool-reference)
4. [Verification and known limits](#verification-and-known-limits)
5. [Code map and tests](#code-map-and-tests)
6. [Releasing](#releasing)

---

## Installing the branch

The tools need both halves from this branch: the Ruby handlers in the
SketchUp plugin and the Python wrappers in the MCP server. Mixing one branch
half with one stock 0.3.1 half is safe, because both still carry version
0.3.1 and pass the handshake:

- **Branch client with a stock plugin.** The 14 tools answer
  `[-32601] unknown tool: …` with a hint that points here.
- **Stock client with the branch plugin.** The tools exist in SketchUp, but
  the MCP client never offers them.

### SketchUp plugin

Use either of the following.

- **Build and install an .rbz.**
  1. Run `cd mcp_for_sketchup && ruby package.rb`.
  2. In SketchUp, open **Extension Manager → Install Extension…** and pick
     `mcp_for_sketchup_v0.3.1.rbz`.
  3. Restart SketchUp.
- **Copy the folder.** Replace
  `%APPDATA%\SketchUp\SketchUp 2026\SketchUp\Plugins\mcp_for_sketchup\` with
  this checkout's `mcp_for_sketchup/mcp_for_sketchup/` (the loader
  `mcp_for_sketchup.rb` is unchanged), then restart SketchUp.

To try the branch in a running SketchUp without reinstalling, load the files
into the live session. Do it once with `eval_ruby`; after that,
`reload_ruby` can reload them:

```ruby
root = 'D:/path/to/sketchup-mcp2/mcp_for_sketchup/mcp_for_sketchup'
v, $VERBOSE = $VERBOSE, nil
%w[helpers/validation helpers/mesh helpers/space handlers/inspect
   handlers/scene handlers/devtools handlers/dispatch].each { |f| load "#{root}/#{f}.rb" }
$VERBOSE = v
```

This changes only the running session. Restarting SketchUp brings back the
installed plugin.

### MCP server (Python)

Use either of the following.

- **Into the Python interpreter your MCP client already runs:**
  `python -m pip install -e <checkout>`. The editable install follows the
  branch as you pull. Restart the MCP server afterwards (`/mcp` in Claude
  Code).
- **Run it from the checkout:**
  `claude mcp add sketchup -- uv run --directory <checkout> sketchup-mcp2`.

---

## Conventions shared by every tool

**Units.** Lengths are mm, areas mm², volumes mm³ and angles degrees, as in
the rest of the server. Attribute values are the one exception:
`get_attributes` returns them exactly as stored, so a stored length is raw
inches.

**World coordinates, also in edit mode.** Every coordinate a tool returns is
in model (world) space. That matters while the user has a group open,
because SketchUp then reports placements in a mixed frame:

- every instance on the open path reports the identity;
- the open group's contents report world coordinates;
- the contents of any other instance report their own local coordinates.

`helpers/space.rb` walks down from the model root, multiplies the reported
transformations, and corrects the one case that walk gets wrong: a second
instance of the definition being edited. If a result passes through a
second instance of an *outer* open definition, its frame cannot be read
while that definition is open. The result then carries
`edit_mode_ambiguous: true`.

**IDs.** IDs are `entityID` integers, sent as numbers or strings. Lists of
IDs drop duplicates.

**Time limits.** `solid_report`, `query_faces`, `find_overlaps` and
`scene_stats` take `max_seconds` (1–55, default 20). Past that limit they
return what they have, with `complete: false`. A Ruby call that outlives
the client's 60 s timeout keeps running and freezes SketchUp until it ends,
so the limit exists to keep calls well inside it.

**Errors.** Errors come back as `[code] message` text:

- `-32602` means a bad parameter. Parameters are checked before the model
  is touched.
- `-32601` from an older plugin carries the install hint.
- `-32010` means the eval gate is closed. That message is passed through
  verbatim so it can be shown to the user.

**Undo.**

- `set_entity_properties` and `set_attributes` are one Undo step each.
- `capture_view` and `eval_ruby_dry_run` change the model only inside an
  operation they abort, so they leave no Undo entry.
- `select_entities` changes only the selection, which SketchUp doesn't
  undo.

**Retries.** When the connection drops mid-reply, the client re-sends a
read-only tool by itself. That covers every tool marked "no" in the table
above, except `solid_report`: re-running `save_as` and `compare_with` on the
same label would compare the new snapshot with itself.

---

## Tool reference

### get_edit_context

Where the user is. Call it first when results look offset, or when a
selection doesn't take.

No parameters.

Returns:

```json
{
  "model": {"title": "…", "path": "…"},
  "active_path": [{"id": 432853, "name": "Main Wall#2578", "type": "component", "definition": "Main Wall#2578"}],
  "edit_transform": {"origin_mm": [65599.54, -8028.42, -500.0], "xaxis": [-1, 0, 0], "yaxis": [0, -1, 0], "zaxis": [0, 0, 1]},
  "active_entities": {"edge": 203, "face": 66},
  "selection": {"count": 3, "by_type": {"face": 3}, "ids": [381639, 381651, 381645]},
  "camera": {"eye_mm": […], "target_mm": […], "up": […], "perspective": false, "height_mm": 3689.5},
  "viewport": {"width": 2434, "height": 1070},
  "active_tool": "SelectionTool"
}
```

`active_path` is `[]` and `edit_transform` is `null` when nothing is open.

### solid_report

A per-part solid check.

| Parameter | Default | |
|---|---|---|
| `ids` | — | 1–200 groups or components |
| `children` | `false` | Report each group or component directly inside the given ones, such as the parts of a generated building |
| `max_samples` | 5 | Open and non-manifold edge midpoints to list per part (0–50) |
| `save_as` | — | Keep this report in memory under a label |
| `compare_with` | — | Diff against an earlier `save_as` report |
| `max_seconds` | 20 | |

Each part reports the following:

- `faces`, `edges` and `nested_instances`.
- `manifold`, which is SketchUp's `manifold?`.
- `volume_mm3` and `orientation` (`outward` or `inward`). Both are reported
  only for manifold parts.
- `area_mm2` and the world `bbox_mm`.
- `open_edges` (edges with one face), `nonmanifold_edges` (edges with three
  or more faces) and `stray_edges` (edges with no face).
- `open_edge_samples_mm` and `nonmanifold_edge_samples_mm`: edge midpoints
  in world mm, which show where to look for holes and stray faces.

Volume and area come from the faces' triangles in world space, so they
include the instance's scale. Faces of nested groups are counted in the
bbox only, because a solid holds only faces and edges.

`save_as` and `compare_with` exist for rebuilds: run the build, report with
`save_as`, change the plugin, rebuild, then report with `compare_with`. A
rebuild makes new groups with new IDs, so parts are matched by name (the
2nd "Wall 1" with the 2nd "Wall 1"). Small drift doesn't count as a change:
1 mm³ or a millionth of the volume, 1 mm² of area, and 0.01 mm per bbox
coordinate.

An illustrative diff:

```json
"diff": {"added": ["Wall 8"], "removed": [], "unchanged": 14,
         "changed": [{"part": "Column 4", "changes": {"faces": [8, 6], "volume_mm3": [999201566.3, 875014892.5]}}]}
```

Passing the same label to both compares against the old snapshot and then
replaces it. Snapshots live in the SketchUp session: the newest 20 labels
are kept, and they are lost on restart.

### query_faces

Find faces in world mm.

| Parameter | Default | |
|---|---|---|
| `id` | the context being edited | Group or component whose faces to search |
| `recursive` | `false` | Also search nested groups and components |
| `orientation` | `any` | `up`, `down`, `vertical` (walls), `sloped` or `any`, judged on the world normal |
| `angle_tolerance_deg` | 1 | For `orientation` and `normal` (0–45) |
| `normal` | — | Keep faces whose normal points this way, e.g. `[0, -1, 0]` |
| `within_mm` | — | `{min: [x,y,z], max: [x,y,z]}`; keep faces whose bbox touches it |
| `min_area_mm2` | 0 | |
| `tag` | — | `"Untagged"` matches Layer0 |
| `material` | — | Front or back material, by display name or name |
| `include_vertices` | `true` | Outer loop in world mm |
| `limit` / `offset` | 100 / 0 | Paging (`total`, `truncated`) |

Each face reports `id`, `area_mm2`, `normal`, `plane_offset_mm` (*d* in
normal · p = d), `bbox_mm`, `holes`, `material`, `back_material`, `tag`,
`parent_id` (the nested instance it came from) and `vertices_mm`.

Example: `query_faces(tag="Erase")` inside the open Main Wall#2578 returned
the three recess faces with their world vertices (a jamb at x = 63059.54 mm
from z = 600 to 3000, the sill at z = 600, and the far jamb).

### find_overlaps

Pairs of parts whose volumes interpenetrate.

| Parameter | Default | |
|---|---|---|
| `ids` *or* `container_id` | — | 2–200 parts, or the groups/components directly inside one container |
| `samples_per_axis` | 12 | n³ sample points per pair (4–40); raise it to catch thin overlaps |
| `tolerance_mm` | 1.0 | Interpenetration shallower than this counts as contact |
| `include_hidden` | `false` | Also test hidden parts and parts on hidden tags |
| `max_seconds` | 20 | |

How it works:

1. Every part, with its nested geometry, becomes world-space triangles.
2. Each pair's bounding boxes are intersected and shrunk by the tolerance.
   Pairs with nothing left are skipped.
3. The common box is sampled on a jittered n³ grid. A sample counts when it
   lies inside both parts by ray parity.
4. Parity is voted over three axis rays. A ray that grazes an edge
   miscounts, but two of the three would have to fail at the same point.
5. A hit within `tolerance_mm` of either surface is contact, not overlap.
   That catches contacts the box shrink in step 2 misses, such as a wall
   end sitting a hundredth of a millimetre into a slanted column face.

Each overlap reports:

- `hits` and `samples`.
- `overlap_volume_mm3`: an estimate, (hits / samples) × the common box
  volume.
- `max_depth_mm`: how far the deepest hit lies inside the nearer of the
  two surfaces.
- `box_mm` and up to three `sample_points_mm`.

Pairs whose only hits were within tolerance are listed under
`within_tolerance`. Parts that are not closed solids are listed in
`not_solid` with a warning, because parity assumes closed surfaces.

Examples from the Main Wall#2578 build (15 parts, 21 candidate pairs, 1.7 s
inside SketchUp):

- With the default tolerance, `overlaps` is empty and `within_tolerance`
  lists Wall 6 / Column 5 and Wall 7 / Column 7. SketchUp's own
  `Face#classify_point` agreed on every ray that those sample points lie
  inside both parts, so the parity test was right. The parts really do
  overlap, by about 0.01 mm.
- With `tolerance_mm: 0`, every contact appears with `max_depth_mm` 0.0 to
  0.01. That is what zero tolerance means; use it only to hunt for
  sub-millimetre slivers.

### raycast

What lies along a line, nearest first.

| Parameter | Default | |
|---|---|---|
| `origin_mm`, `direction` | — | `direction` is any non-zero vector |
| `max_hits` | 5 | 1–50 |
| `include_hidden` | `false` | |
| `max_distance_mm` | — | |

Each hit reports `point_mm`, `distance_mm`, `entity {id, type}`, `tag`,
`path` (the instances down to it) and, for faces, the world `normal` and
`material`. The next ray starts just past each hit, and repeats at the same
spot (an edge, then the faces beside it) are dropped.

Geometry is skipped only when it is hidden or on a hidden tag. Edit mode's
"hide rest of model" only changes what is drawn, so rays still hit that
geometry.

### scene_stats

What the scene really draws.

| Parameter | Default | |
|---|---|---|
| `id` | whole model | Group or component to measure |
| `top` | 10 | Heaviest definitions to list |
| `max_seconds` | 20 | |

Returns the following:

- `direct` counts.
- `flattened` counts: faces, edges, instances and hidden entities, carried
  through every instance.
- `heaviest_definitions`: `faces_each × occurrences = faces_total`.
- `faces_by_tag` and `instances_by_tag`.
- `definitions {in_scope, in_model}` and `materials`.

Each definition is counted once and its occurrences are carried down in
topological order, so the whole 445,000-face test model took 80 ms
inside SketchUp.

Tags usually sit on instances rather than on the faces inside them, so
`instances_by_tag` is the list to read when deciding what hiding a tag
would save.

### get_attributes

| Parameter | Default | |
|---|---|---|
| `id` | — | |
| `dictionary` | all | |
| `include_definition` | `true` | Also read the definition's dictionaries, where dynamic components keep theirs |

Returns `{id, type, entity: {dict: {key: value}}, definition: {…}}`.

Values are converted for JSON:

- points and vectors become `[x, y, z]`;
- times become ISO 8601 strings;
- colours become `[r, g, b, a]`;
- strings longer than 2,000 characters are cut.

Each dictionary returns at most 200 keys.

### select_entities

| Parameter | Default | |
|---|---|---|
| `ids` | — | Required unless `mode` is `clear` |
| `mode` | `replace` | `replace`, `add`, `remove`, `toggle` or `clear` |

SketchUp selects only inside the context being edited. IDs that live
elsewhere come back in `not_in_active_context` and are not selected.
Unknown IDs come back in `missing_ids`.

### set_entity_properties

Set the tag, hidden flag, lock and/or name of up to 1,000 entities in one
Undo step.

| Parameter | Default | |
|---|---|---|
| `ids` | — | |
| `tag` | — | `"Untagged"` means Layer0 |
| `create_tag` | `true` | Otherwise a missing tag is refused before anything changes |
| `hidden`, `locked` | — | `locked` applies to groups and components only |
| `name` | — | Groups and components only; `""` clears the name |

When a property doesn't apply to an entity (a face can't be locked or
named), it is left out for that entity, and the entity is listed in
`not_applied` with the reason. Its other properties are still set.
`updated` counts the entities that took at least one property.

### set_attributes

| Parameter | Default | |
|---|---|---|
| `id`, `dictionary` | — | |
| `values` | — | 1–200 keys; `null` deletes a key |
| `target` | `instance` | `definition` writes on the group's or component's definition |

Values may be strings, numbers, booleans, or flat lists of those. The
result reports `set`, `deleted`, and `absent` (keys asked to be deleted
that weren't there).

### capture_view

A PNG of chosen entities. It returns an MCP image plus JSON with `width`,
`height`, `preset_used`, `style_used`, `fitted_bbox_mm`, `hidden_count` and
`warnings`.

| Parameter | Default | |
|---|---|---|
| `ids` | — | Entities to frame and/or isolate |
| `isolate` | `true` when ids are given | Hide everything else for the shot |
| `fit` | `true` when ids are given | Aim and zoom onto `ids` |
| `view_preset` | `current` | `front`, `back`, `left`, `right`, `top`, `bottom`, `iso`, or `current` to keep the view direction |
| `style` | `default` | `shaded`, `hidden_line`, `wireframe` |
| `max_size` | 1024 | Longest side in pixels (64–4096) |
| `margin` | 1.15 | 1.0 is tight |

How it leaves the scene untouched:

- Isolation hides siblings at every level of each target's path inside an
  operation that is always aborted. The hidden flags come back exactly, and
  no Undo entry is left.
- Hidden targets are shown for the shot.
- Targets on hidden tags produce a warning; tag visibility is not changed.
- While a group is open, the "hide/fade rest of model" settings are lifted
  for the shot, so targets outside the open group appear unfaded.
  `InactiveFade` is an opacity (1.0 = unfaded, checked by rendering both
  ends); `InstanceFade` is set to 1.0 the same way.
- The camera and the rendering options it touched are put back.

A perspective camera backs off until the box's bounding sphere fits. A
parallel camera is sized to the box's corners as seen along the view.

A 2D or match-photo camera can't be restored, so the call refuses.

### profile_view

Milliseconds per frame. Each frame is timed around `View#refresh`, which
draws synchronously.

| Parameter | Default | |
|---|---|---|
| `frames` | 20 | 1–120 |
| `orbit_degrees` | 0 | Swing the camera round its target across the frames, like the Orbit tool |

Returns `ms {min, median, mean, p90, max}`, `fps_median`, the viewport size,
the `render_mode` and whether a group is open (`editing`). The camera is
restored, and the call stops after 30 s.

To see what makes orbiting slow, compare results before and after hiding a
tag, switching style, or leaving the open group.

### eval_ruby_dry_run

Evaluates `code` inside an operation that is always aborted. The code can
build geometry and measure it, and none of that survives. The call returns
`{ok, result | error, rolled_back}`, where `result` is the `inspect` of the
last value.

Operations can't nest in SketchUp. Code that calls `start_operation` or
`commit_operation` itself makes its changes permanent. A transaction
observer notices any commit during the run; the result then says
`rolled_back: false` and carries a warning. To preview a plugin build, call
it in the plugin's own preview mode (one that skips the plugin's own
operation), as Wall Builder 2 does with `Build.build(…, preview: true)`.

Uses the same gate as `eval_ruby`.

### reload_ruby

`load`s Ruby files into the running SketchUp, in order.

| Parameter | Default | |
|---|---|---|
| `paths` | — | 1–100 files or glob patterns (`C:/dev/my_ext/**/*.rb`), at most 300 files in all |
| `stop_on_error` | `true` | Stop at the first file that fails to load |

Returns `{loaded [{path, ms}], failed [{path, error, at}], skipped}`. Errors
include syntax errors with their line, and `at` is the first backtrace line
inside the failing file.

Redefinition warnings ("already initialized constant") are silenced while
loading. Uses the same gate as `eval_ruby`.

---

## Verification and known limits

All 14 tools were run against a live SketchUp 2026 (26.2) on 2026-10-11, in
a 445,000-face model with a component open for editing. Everything ran
through the branch's Python wrappers over the real socket, except
`get_edit_context` and `select_entities`, which were run in-process.

| Check | Result |
|---|---|
| `solid_report` volumes against `Group#volume` | Equal (Column 1: 875,014,892.5 mm³ both ways; a 16 m³ wall: 10 mm³ apart) |
| `solid_report` `compare_with` on an unchanged build | 15 parts unchanged |
| `find_overlaps` hits against `Face#classify_point` on 5 random rays per point | Agreed on every ray |
| `capture_view` and `profile_view` | Camera, rendering options, hidden flags, open path and selection identical afterwards |
| `set_entity_properties` and `set_attributes` on real entities | Applied as expected (the tool's own operation calls stubbed inside an outer aborted operation, so nothing was committed); the abort restored everything, including the new tag |
| `eval_ruby_dry_run` building a 6-face box | Measured, then gone: entity count back to 14, group invalid |
| `reload_ruby` | Used to hot-reload these handlers during the work |

Known limits:

- **`eval_ruby_dry_run` commit detection is tested headless only.** The
  live test did not commit anything into the user's model, so the observer
  firing was not seen in SketchUp.
- **Ray parity assumes closed parts.** Results for parts listed in
  `not_solid` are approximate.
- **Overlap volumes are estimates.** One hit in 1,728 samples of a large
  box is a large number of mm³. Read `max_depth_mm` before believing a
  clash.
- **Ambiguous edit-mode frames.** A second instance of an outer open
  definition can't be placed while that definition is open; such results
  carry `edit_mode_ambiguous`.
- **Selection.** `select_entities` selects only in the active context, as
  SketchUp does.
- **Cameras.** `capture_view` refuses 2D and match-photo cameras, and
  `profile_view` refuses to orbit them.

---

## Code map and tests

| File | Role |
|---|---|
| `mcp_for_sketchup/mcp_for_sketchup/helpers/mesh.rb` | Pure geometry on arrays: volumes, transforms, boxes, jittered samples, parity solid, point-triangle distance. No SketchUp API |
| `…/helpers/space.rb` | World frames, including the edit-mode rule; instance paths; world triangles of a face or a part |
| `…/handlers/inspect.rb` | `get_edit_context`, `solid_report`, `query_faces`, `find_overlaps`, `raycast`, `scene_stats`, `get_attributes` |
| `…/handlers/scene.rb` | `select_entities`, `set_entity_properties`, `set_attributes`, `capture_view`, `profile_view` |
| `…/handlers/devtools.rb` | `eval_ruby_dry_run`, `reload_ruby` |
| `…/handlers/dispatch.rb`, `…/main.rb` | Routes and load order |
| `…/helpers/validation.rb` | `require_id_list`, `optional_number_range` |
| `src/sketchup_mcp/jini_tools.py` | The 14 FastMCP wrappers |
| `src/sketchup_mcp/connection.py` | Read-only tools added to the retry list |
| `src/sketchup_mcp/prompts.py` | Section 9 of `sketchup_modeling_strategy`: when to use the new tools |

Tests:

| File | Runs | Covers |
|---|---|---|
| `test/test_mesh.rb` | 27 | Volumes, mirror and scale, inverse-transpose normals, boxes, samples, parity voting (including a ray along a face diagonal), concave solids, overlap estimates, closest point, slanted contact within tolerance |
| `test/test_jini_tools.rb` | 36 | Routing of all 14 tools; 32 bad-parameter cases refused before the model is touched; the edit-mode frame rule; instance-path climbing; snapshot diffs; attribute conversion; isolation; camera maths; dry-run rollback bookkeeping; `reload_ruby`; operation labels |
| `tests/test_jini_tools.py` | 55 | Ruby name and arguments of every wrapper; schema refusals; the `capture_view` image path; pass-through of `-32010` and `-32601`; the retry list; description pins |

```bash
uv run --extra dev pytest tests/ -q   # 237 passed
ruby test/run_all.rb                   # 480 runs
```

On Windows, eight upstream tests fail on a clean master as well. They are
`test_logger` file deletes, `test_application_show_log` (`File.stub` is gone
from minitest 6, plus POSIX path expectations), and the
`test_package_output` teardown.

That teardown fails to delete the `.rbz` it built (EACCES), so a `.rbz` you
had in `mcp_for_sketchup/` stays in the temp folder the test moved it to
(`%TEMP%\rbz-stash*`). Move it back by hand, or run the suite without that
file.

---

## Releasing

The branch keeps version 0.3.1 on both sides, so each half still pairs with
an installed 0.3.1 counterpart. A release follows
[release.md §1](release.md#1-choose-the-scope-then-bump):

- The release is the next feature number, 0.4.0, and ships both sides,
  because the new Python tools call new Ruby handlers.
- It is the first release after 0.3.1, so both floors (`MIN_RUBY`,
  `MIN_PYTHON`) rise to 0.4.0.
  `tests/test_compat.py::test_first_release_past_0_3_1_raises_floors`
  enforces this.
