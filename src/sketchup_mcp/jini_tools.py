"""Inspection, scene and plugin-development tools (branch ``jini-tools``).

Thin wrappers over the Ruby handlers in ``handlers/inspect.rb``,
``handlers/scene.rb`` and ``handlers/devtools.rb``, with the conventions of
:mod:`sketchup_mcp.tools`: mm at the boundary, ids sent as strings, errors
returned as ``[code] message`` strings. Documented in docs/jini-tools.md.
"""
import base64
import json
from typing import Annotated, Literal, Optional, Union

from mcp.server.fastmcp import Context, Image
from pydantic import BaseModel, Field

from sketchup_mcp import compat, config
from sketchup_mcp.app import mcp
from sketchup_mcp.errors import SketchUpError, format_error
from sketchup_mcp.tools import EntityId, _extract_text, _raw_call

# A plugin without these handlers answers -32601 "unknown tool"; say why.
_OLD_PLUGIN_HINT = (
    " (the SketchUp plugin has no such tool: install the mcp_for_sketchup "
    "build from the jini-tools branch — see docs/jini-tools.md)"
)

MaxSeconds = Annotated[
    float,
    Field(ge=1, le=55,
          description="Stop and return what was found so far (complete: false) "
                      "after this many seconds; keeps long reads under the "
                      "client's 60 s timeout"),
]

Coords3 = Annotated[list[float], Field(min_length=3, max_length=3)]


class BoxMm(BaseModel):
    """Axis-aligned box in world mm."""

    min: Annotated[Coords3, Field(description="Minimum corner [x, y, z] in mm")]
    max: Annotated[Coords3, Field(description="Maximum corner [x, y, z] in mm")]


AttributeScalar = Union[str, int, float, bool, None]


def _ids(ids: list) -> list[str]:
    return [str(i) for i in ids]


async def _jcall(ctx: Context, tool_name: str, /, **kwargs) -> str:
    """Like tools._call, plus two messages passed through verbatim: the
    eval gate's -32010 (for the eval-gated tools) and a hint on -32601 when
    the plugin predates these tools."""
    try:
        result = await _raw_call(ctx, tool_name, **kwargs)
    except ConnectionError as e:
        return f"SketchUp not running or extension not started: {e}"
    except SketchUpError as e:
        if e.code == compat.EVAL_DISABLED_CODE:
            return e.message
        e.data.setdefault("tool", tool_name)
        text = format_error(e, debug=config.LOG_LEVEL == "DEBUG")
        if e.code == -32601:
            text += _OLD_PLUGIN_HINT
        return text
    return _extract_text(result)


# ---- inspection ---------------------------------------------------------------


@mcp.tool()
async def get_edit_context(ctx: Context) -> str:
    """Where the user is: the open group path, selection, camera and active tool.

    Call this first when results look offset or empty — while the user is
    editing inside a group, SketchUp reports that group's contents in world
    coordinates and only the active context can be selected.

    Returns: JSON {model{title, path}, active_path[{id, name, type,
    definition}], edit_transform{origin_mm, xaxis, yaxis, zaxis}|null,
    active_entities{type: count}, selection{count, by_type, ids[≤50]},
    camera{eye_mm, target_mm, up, perspective, fov_deg|height_mm},
    viewport{width, height}, active_tool}.
    """
    return await _jcall(ctx, "get_edit_context")


@mcp.tool()
async def solid_report(
    ctx: Context,
    ids: Annotated[
        list[EntityId],
        Field(min_length=1, max_length=200,
              description="Groups/components to report on"),
    ],
    children: Annotated[
        bool,
        Field(description="Report each group/component directly inside the "
                          "given ones instead of the given ones themselves "
                          "(e.g. the parts of a generated building)"),
    ] = False,
    max_samples: Annotated[
        int,
        Field(ge=0, le=50,
              description="How many open / non-manifold edge midpoints to "
                          "list per part"),
    ] = 5,
    save_as: Annotated[
        Optional[Annotated[str, Field(min_length=1)]],
        Field(description="Keep this report in memory under this label for a "
                          "later compare_with (session only)"),
    ] = None,
    compare_with: Annotated[
        Optional[Annotated[str, Field(min_length=1)]],
        Field(description="Label of an earlier save_as report to diff "
                          "against; parts are matched by name"),
    ] = None,
    max_seconds: MaxSeconds = 20,
) -> str:
    """Per-part solid check: face/edge counts, manifold, volume, area, world bbox, open edges.

    Volume (mm³) is reported only for manifold parts; orientation says
    whether the faces point outward. Open edges (one face) and non-manifold
    edges (3+ faces) are counted with sample midpoints in world mm, which is
    where to look for holes and stray faces. save_as / compare_with diff a
    rebuild against the build before it — the parts get new ids but keep
    their names.

    Returns: JSON {parts[{id, name, type, tag, faces, edges,
    nested_instances, manifold, volume_mm3|null, orientation|null, area_mm2,
    bbox_mm, open_edges, nonmanifold_edges, stray_edges,
    open_edge_samples_mm, nonmanifold_edge_samples_mm}], complete,
    diff{added, removed, changed[{part, changes{field: [old, new]}}],
    unchanged}?, saved_as?}.
    """
    args: dict = {"ids": _ids(ids), "children": children,
                  "max_samples": max_samples, "max_seconds": max_seconds}
    if save_as is not None:
        args["save_as"] = save_as
    if compare_with is not None:
        args["compare_with"] = compare_with
    return await _jcall(ctx, "solid_report", **args)


@mcp.tool()
async def query_faces(
    ctx: Context,
    id: Annotated[
        Optional[EntityId],
        Field(description="Group/component whose faces to search; omit for "
                          "the context the user is editing"),
    ] = None,
    recursive: Annotated[
        bool, Field(description="Also search nested groups/components"),
    ] = False,
    orientation: Annotated[
        Literal["any", "up", "down", "vertical", "sloped"],
        Field(description="Filter by world normal: up/down-facing, vertical "
                          "(walls), sloped, or any"),
    ] = "any",
    angle_tolerance_deg: Annotated[
        float,
        Field(ge=0, le=45,
              description="Angle tolerance in degrees for orientation and normal"),
    ] = 1.0,
    normal: Annotated[
        Optional[Coords3],
        Field(description="Keep faces whose world normal points this way "
                          "[x, y, z] (within angle_tolerance_deg)"),
    ] = None,
    within_mm: Annotated[
        Optional[BoxMm],
        Field(description="Keep faces whose world bbox touches this box (mm)"),
    ] = None,
    min_area_mm2: Annotated[
        float, Field(ge=0, description="Skip faces smaller than this (mm²)"),
    ] = 0.0,
    tag: Annotated[
        Optional[Annotated[str, Field(min_length=1)]],
        Field(description="Keep faces on this tag (\"Untagged\" for Layer0)"),
    ] = None,
    material: Annotated[
        Optional[Annotated[str, Field(min_length=1)]],
        Field(description="Keep faces painted with this material (front or back)"),
    ] = None,
    include_vertices: Annotated[
        bool, Field(description="Include each face's outer loop in world mm"),
    ] = True,
    limit: Annotated[
        int, Field(ge=1, le=500, description="Page size — faces per response"),
    ] = 100,
    offset: Annotated[
        int, Field(ge=0, description="How many matches to skip (pagination)"),
    ] = 0,
    max_seconds: MaxSeconds = 20,
) -> str:
    """Find faces by direction, position, size, tag or material — in world mm.

    Coordinates are world space even while the user is editing inside a
    group. Use it to answer "which faces are at this height / face this
    way / sit in this box" without writing Ruby.

    Returns: JSON {faces[{id, area_mm2, normal, plane_offset_mm, bbox_mm,
    holes, material, back_material, tag, parent_id, vertices_mm?}], total,
    offset, truncated, complete}. plane_offset_mm is d in normal·p = d.
    """
    args: dict = {"recursive": recursive, "orientation": orientation,
                  "angle_tolerance_deg": angle_tolerance_deg,
                  "min_area_mm2": min_area_mm2,
                  "include_vertices": include_vertices, "limit": limit,
                  "offset": offset, "max_seconds": max_seconds}
    if id is not None:
        args["id"] = str(id)
    if normal is not None:
        args["normal"] = normal
    if within_mm is not None:
        args["within_mm"] = within_mm.model_dump()
    if tag is not None:
        args["tag"] = tag
    if material is not None:
        args["material"] = material
    return await _jcall(ctx, "query_faces", **args)


@mcp.tool()
async def find_overlaps(
    ctx: Context,
    ids: Annotated[
        Optional[Annotated[list[EntityId], Field(min_length=2, max_length=200)]],
        Field(description="Groups/components to test against each other "
                          "(2..200); or pass container_id"),
    ] = None,
    container_id: Annotated[
        Optional[EntityId],
        Field(description="Test the groups/components directly inside this "
                          "one against each other"),
    ] = None,
    samples_per_axis: Annotated[
        int,
        Field(ge=4, le=40,
              description="Sampling grid per axis inside each pair's common "
                          "box (n³ points); raise it to catch thin overlaps"),
    ] = 12,
    tolerance_mm: Annotated[
        float,
        Field(ge=0, le=1000,
              description="Ignore interpenetration shallower than this: hits "
                          "within this distance of either part's surface count "
                          "as contact. 0 reports every contact, even 0.01 mm"),
    ] = 1.0,
    include_hidden: Annotated[
        bool, Field(description="Also test hidden parts and parts on hidden tags"),
    ] = False,
    max_seconds: MaxSeconds = 20,
) -> str:
    """Find pairs of solids whose volumes overlap (interpenetrate), not just touch.

    Each pair whose bounding boxes share volume is sampled on a grid; a
    point counts when it is inside both parts by ray parity, voted over
    three axes so a ray grazing an edge can't fake a hit. Hits within
    tolerance_mm of either surface are contact, not overlap: pairs that only
    have those are listed in within_tolerance. overlap_volume_mm3 is an
    estimate (hits / samples × common box volume); max_depth_mm is how far
    the deepest hit lies inside the nearer surface. Parts that are not
    closed solids are listed in not_solid; treat their results as
    approximate.

    Returns: JSON {parts, pairs_total, pairs_checked, complete,
    samples_per_axis, overlaps[{a{id,name,type}, b{...}, hits, samples,
    overlap_volume_mm3, max_depth_mm, box_mm, sample_points_mm}],
    within_tolerance[{a, b, hits}]?, not_solid?, warning?}.
    """
    args: dict = {"samples_per_axis": samples_per_axis,
                  "tolerance_mm": tolerance_mm,
                  "include_hidden": include_hidden, "max_seconds": max_seconds}
    if ids is not None:
        args["ids"] = _ids(ids)
    if container_id is not None:
        args["container_id"] = str(container_id)
    return await _jcall(ctx, "find_overlaps", **args)


@mcp.tool()
async def raycast(
    ctx: Context,
    origin_mm: Annotated[
        Coords3, Field(description="Ray start [x, y, z] in world mm"),
    ],
    direction: Annotated[
        Coords3, Field(description="Ray direction [x, y, z] (any length, not zero)"),
    ],
    max_hits: Annotated[
        int, Field(ge=1, le=50, description="Stop after this many hits"),
    ] = 5,
    include_hidden: Annotated[
        bool, Field(description="Also hit hidden geometry"),
    ] = False,
    max_distance_mm: Annotated[
        Optional[Annotated[float, Field(gt=0)]],
        Field(description="Ignore hits farther than this from the origin (mm)"),
    ] = None,
) -> str:
    """Cast a ray through the model and list what it hits, nearest first.

    Probes geometry without selecting anything: "what is above this point",
    "how thick is this wall here", "which part is in front". Each hit
    carries the entity, the instance path down to it, and for faces the
    world normal and material.

    Returns: JSON {hits[{point_mm, distance_mm, entity{id, type}, tag,
    path[{id, name, type}], normal?, material?}]}.
    """
    args: dict = {"origin_mm": origin_mm, "direction": direction,
                  "max_hits": max_hits, "include_hidden": include_hidden}
    if max_distance_mm is not None:
        args["max_distance_mm"] = max_distance_mm
    return await _jcall(ctx, "raycast", **args)


@mcp.tool()
async def scene_stats(
    ctx: Context,
    id: Annotated[
        Optional[EntityId],
        Field(description="Group/component to measure; omit for the whole model"),
    ] = None,
    top: Annotated[
        int, Field(ge=1, le=50, description="How many heaviest definitions to list"),
    ] = 10,
    max_seconds: MaxSeconds = 20,
) -> str:
    """Count what the scene draws: faces and edges flattened through every instance.

    For "why is orbiting slow" questions: a component placed 200 times
    costs 200 × its faces. Lists the definitions contributing most faces,
    and faces and instances per tag (tags usually sit on instances, so
    instances_by_tag shows what hiding a tag would take away).

    Returns: JSON {scope, direct{faces, edges, groups, components, other},
    flattened{faces, edges, instances, hidden}, definitions{in_scope,
    in_model}, heaviest_definitions[{definition, faces_each, occurrences,
    faces_total}], faces_by_tag[{tag, faces, visible}],
    instances_by_tag[{tag, instances, visible}], materials, complete}.
    """
    args: dict = {"top": top, "max_seconds": max_seconds}
    if id is not None:
        args["id"] = str(id)
    return await _jcall(ctx, "scene_stats", **args)


@mcp.tool()
async def get_attributes(
    ctx: Context,
    id: EntityId,
    dictionary: Annotated[
        Optional[Annotated[str, Field(min_length=1)]],
        Field(description="Only this attribute dictionary; omit for all"),
    ] = None,
    include_definition: Annotated[
        bool,
        Field(description="For groups/components, also read the definition's "
                          "dictionaries (dynamic components keep theirs there)"),
    ] = True,
) -> str:
    """Read an entity's attribute dictionaries (plugin data, dynamic-component attributes).

    Values come back as stored: lengths are raw inches, points are [x, y, z]
    arrays. At most 200 keys per dictionary.

    Returns: JSON {id, type, entity{dictionary: {key: value}},
    definition{...}?}.
    """
    args: dict = {"id": str(id), "include_definition": include_definition}
    if dictionary is not None:
        args["dictionary"] = dictionary
    return await _jcall(ctx, "get_attributes", **args)


# ---- scene ------------------------------------------------------------------------


@mcp.tool()
async def select_entities(
    ctx: Context,
    ids: Annotated[
        Optional[Annotated[list[EntityId], Field(min_length=1, max_length=1000)]],
        Field(description="Entities to select (required unless mode is clear)"),
    ] = None,
    mode: Annotated[
        Literal["replace", "add", "remove", "toggle", "clear"],
        Field(description="replace the selection, add to / remove from / "
                          "toggle in it, or clear it"),
    ] = "replace",
) -> str:
    """Select entities in SketchUp so the user can see what you mean.

    SketchUp selects only inside the context being edited; ids elsewhere
    are returned in not_in_active_context (open their parent first, or ask
    the user to).

    Returns: JSON {mode, applied, selected, missing_ids,
    not_in_active_context}.
    """
    args: dict = {"mode": mode}
    if ids is not None:
        args["ids"] = _ids(ids)
    return await _jcall(ctx, "select_entities", **args)


@mcp.tool()
async def set_entity_properties(
    ctx: Context,
    ids: Annotated[
        list[EntityId],
        Field(min_length=1, max_length=1000, description="Entities to change"),
    ],
    tag: Annotated[
        Optional[Annotated[str, Field(min_length=1)]],
        Field(description="Move the entities to this tag (\"Untagged\" for Layer0)"),
    ] = None,
    create_tag: Annotated[
        bool, Field(description="Create the tag if it does not exist"),
    ] = True,
    hidden: Annotated[
        Optional[bool], Field(description="Hide (true) or unhide (false)"),
    ] = None,
    locked: Annotated[
        Optional[bool], Field(description="Lock or unlock groups/components"),
    ] = None,
    name: Annotated[
        Optional[str],
        Field(description="Rename groups/components (empty string clears the name)"),
    ] = None,
) -> str:
    """Set tag, hidden, locked and/or name on many entities as one Undo step.

    A property that doesn't apply to an entity (a face can't be locked or
    named) is left out for it, and the entity is listed in not_applied with
    the reason; its other properties are still set.

    Returns: JSON {updated, not_applied[{id, type, reason}], tag,
    tag_created}. updated counts entities that took at least one property.
    """
    args: dict = {"ids": _ids(ids), "create_tag": create_tag}
    for key, value in (("tag", tag), ("hidden", hidden), ("locked", locked),
                       ("name", name)):
        if value is not None:
            args[key] = value
    return await _jcall(ctx, "set_entity_properties", **args)


@mcp.tool()
async def set_attributes(
    ctx: Context,
    id: EntityId,
    dictionary: Annotated[
        str, Field(min_length=1, description="Attribute dictionary name"),
    ],
    values: Annotated[
        dict[str, Union[AttributeScalar, list[AttributeScalar]]],
        Field(min_length=1, max_length=200,
              description="Keys to write; null deletes the key. Values: "
                          "string, number, boolean or a flat list of those"),
    ],
    target: Annotated[
        Literal["instance", "definition"],
        Field(description="Write on the entity itself or on its definition"),
    ] = "instance",
) -> str:
    """Write or delete keys in an attribute dictionary, as one Undo step.

    Returns: JSON {id, target, dictionary, set[keys], deleted[keys],
    absent[keys]} — absent lists keys asked to be deleted that weren't there.
    """
    return await _jcall(ctx, "set_attributes", id=str(id), dictionary=dictionary,
                        values=values, target=target)


@mcp.tool()
async def capture_view(
    ctx: Context,
    ids: Annotated[
        Optional[Annotated[list[EntityId], Field(min_length=1, max_length=500)]],
        Field(description="Entities to frame and/or isolate"),
    ] = None,
    isolate: Annotated[
        Optional[bool],
        Field(description="Hide everything except ids for the shot (default: "
                          "true when ids are given)"),
    ] = None,
    fit: Annotated[
        Optional[bool],
        Field(description="Aim and zoom the camera onto ids (default: true "
                          "when ids are given)"),
    ] = None,
    view_preset: Annotated[
        Literal["current", "front", "back", "left", "right", "top", "bottom", "iso"],
        Field(description="Direction to look from; 'current' keeps the "
                          "present view direction"),
    ] = "current",
    style: Annotated[
        Literal["default", "shaded", "hidden_line", "wireframe"],
        Field(description="Temporary rendering style for the shot"),
    ] = "default",
    max_size: Annotated[
        int,
        Field(ge=64, le=4096,
              description="Largest side of the returned PNG in pixels"),
    ] = 1024,
    margin: Annotated[
        float,
        Field(ge=1.0, le=3.0,
              description="Space around the fitted entities (1.0 = tight)"),
    ] = 1.15,
    # NB: bare `list` on purpose, as in get_viewport_screenshot.
) -> list:
    """Picture of chosen entities: isolated, framed, from a chosen side.

    Hidden flags are changed inside an operation that is always aborted, and
    the camera and rendering options are put back, so the user's model and
    view are unchanged afterwards (no Undo entry). Works while the user is
    editing inside a group: "hide/fade rest of model" is lifted for the shot.

    Returns: the PNG image plus a JSON text block {width, height,
    preset_used, style_used, fitted_bbox_mm, hidden_count, warnings}.
    """
    args: dict = {"view_preset": view_preset, "style": style,
                  "max_size": max_size, "margin": margin}
    if ids is not None:
        args["ids"] = _ids(ids)
    if isolate is not None:
        args["isolate"] = isolate
    if fit is not None:
        args["fit"] = fit
    try:
        raw = await _raw_call(ctx, "capture_view", **args)
    except ConnectionError as e:
        raise SketchUpError(-32000, f"SketchUp not running: {e}") from e
    except SketchUpError as e:
        if e.code == -32601:
            raise SketchUpError(e.code, e.message + _OLD_PLUGIN_HINT, e.data) from e
        raise
    payload = _json_payload(raw, "capture_view")
    b64 = payload.get("png_base64")
    if not isinstance(b64, str):
        raise SketchUpError(-32603, "capture_view response missing png_base64")
    try:
        png = base64.b64decode(b64, validate=True)
    except (ValueError, base64.binascii.Error) as e:
        raise SketchUpError(-32603, f"png_base64 decode failed: {e}") from e
    meta = {k: payload.get(k) for k in ("width", "height", "preset_used",
                                        "style_used", "fitted_bbox_mm",
                                        "hidden_count", "warnings")}
    return [Image(data=png, format="png"), json.dumps(meta)]


def _json_payload(raw: object, tool_name: str) -> dict:
    text = _extract_text(raw)
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as e:
        raise SketchUpError(-32603, f"{tool_name} response not JSON: {e}") from e
    if not isinstance(payload, dict):
        raise SketchUpError(
            -32603, f"{tool_name} payload is not a JSON object: {type(payload).__name__}")
    return payload


@mcp.tool()
async def profile_view(
    ctx: Context,
    frames: Annotated[
        int, Field(ge=1, le=120, description="How many redraws to time"),
    ] = 20,
    orbit_degrees: Annotated[
        float,
        Field(ge=0, le=360,
              description="Swing the camera this far round its target across "
                          "the frames, like the Orbit tool; 0 redraws in place"),
    ] = 0.0,
) -> str:
    """Measure how long the viewport takes to draw one frame.

    Times View#refresh, which draws synchronously. The camera is restored
    afterwards. Compare before/after hiding things, switching styles or
    leaving a group to see what makes orbiting slow. Stops after 30 s.

    Returns: JSON {frames, ms{min, median, mean, p90, max}, fps_median,
    orbit_degrees, viewport{width, height}, render_mode, editing}.
    """
    return await _jcall(ctx, "profile_view", frames=frames,
                        orbit_degrees=orbit_degrees)


# ---- plugin development (behind the eval_ruby gate) ---------------------------------


@mcp.tool()
async def eval_ruby_dry_run(
    ctx: Context,
    code: Annotated[
        str, Field(min_length=1, description="Ruby code to evaluate and roll back"),
    ],
) -> str:
    """Evaluate Ruby inside an operation that is always aborted: see the result, keep no changes.

    For "what would this build" questions: the code may create or erase
    geometry and read the outcome; everything is rolled back with no Undo
    entry. Code that starts or commits its own operation escapes the
    rollback — the result then says rolled_back: false. Uses the same gate
    as eval_ruby.

    Returns: JSON {ok, result (inspect of the last value) | error,
    rolled_back, warning?}.
    """
    return await _jcall(ctx, "eval_ruby_dry_run", code=code)


@mcp.tool()
async def reload_ruby(
    ctx: Context,
    paths: Annotated[
        list[Annotated[str, Field(min_length=1)]],
        Field(min_length=1, max_length=100,
              description="Ruby files or glob patterns to load, in order "
                          "(e.g. C:/plugins/my_ext/**/*.rb)"),
    ],
    stop_on_error: Annotated[
        bool, Field(description="Stop at the first file that fails to load"),
    ] = True,
) -> str:
    """Load (reload) Ruby files into the running SketchUp — plugin hot-reload.

    Redefinition warnings are silenced; errors come back per file with the
    backtrace line in that file. Uses the same gate as eval_ruby.

    Returns: JSON {loaded[{path, ms}], failed[{path, error, at}], skipped}.
    """
    return await _jcall(ctx, "reload_ruby", paths=paths,
                        stop_on_error=stop_on_error)
