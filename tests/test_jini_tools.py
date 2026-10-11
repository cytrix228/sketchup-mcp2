"""jini-tools wrappers (docs/jini-tools.md): the Ruby name and arguments each
tool sends, schema checks through the real FastMCP schemas, the image path of
capture_view, and the messages passed through verbatim."""
import base64
import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from mcp.server.fastmcp import Image

from sketchup_mcp.app import mcp
from sketchup_mcp.errors import SketchUpError

TINY_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9Q"
    "DwADhgGAWjR9awAAAABJRU5ErkJggg=="
)


@pytest.fixture
def conn():
    fake = MagicMock()
    fake.send_command = AsyncMock(return_value={"content": [{"text": "ok"}]})
    with patch("sketchup_mcp.tools.get_connection", AsyncMock(return_value=fake)):
        yield fake


@pytest.mark.parametrize(
    "tool, kwargs, ruby_name, ruby_kwargs",
    [
        ("get_edit_context", {}, "get_edit_context", {}),
        ("solid_report", {"ids": [12, "13"]}, "solid_report",
         {"ids": ["12", "13"], "children": False, "max_samples": 5, "max_seconds": 20}),
        ("solid_report",
         {"ids": [1], "children": True, "save_as": "a", "compare_with": "b"},
         "solid_report",
         {"ids": ["1"], "children": True, "max_samples": 5, "max_seconds": 20,
          "save_as": "a", "compare_with": "b"}),
        ("query_faces", {}, "query_faces",
         {"recursive": False, "orientation": "any", "angle_tolerance_deg": 1.0,
          "min_area_mm2": 0.0, "include_vertices": True, "limit": 100, "offset": 0,
          "max_seconds": 20}),
        ("query_faces",
         {"id": 5, "orientation": "up", "normal": [0, 0, 1],
          "within_mm": {"min": [0, 0, 0], "max": [10, 10, 10]}, "tag": "Walls",
          "material": "Brick"},
         "query_faces",
         {"id": "5", "recursive": False, "orientation": "up", "angle_tolerance_deg": 1.0,
          "min_area_mm2": 0.0, "include_vertices": True, "limit": 100, "offset": 0,
          "max_seconds": 20, "normal": [0, 0, 1],
          "within_mm": {"min": [0, 0, 0], "max": [10, 10, 10]}, "tag": "Walls",
          "material": "Brick"}),
        ("find_overlaps", {"ids": [1, 2]}, "find_overlaps",
         {"samples_per_axis": 12, "tolerance_mm": 1.0, "include_hidden": False,
          "max_seconds": 20, "ids": ["1", "2"]}),
        ("find_overlaps", {"container_id": 9}, "find_overlaps",
         {"samples_per_axis": 12, "tolerance_mm": 1.0, "include_hidden": False,
          "max_seconds": 20, "container_id": "9"}),
        ("raycast", {"origin_mm": [0, 0, 0], "direction": [0, 0, -1]}, "raycast",
         {"origin_mm": [0, 0, 0], "direction": [0, 0, -1], "max_hits": 5,
          "include_hidden": False}),
        ("raycast",
         {"origin_mm": [0, 0, 0], "direction": [1, 0, 0], "max_distance_mm": 500},
         "raycast",
         {"origin_mm": [0, 0, 0], "direction": [1, 0, 0], "max_hits": 5,
          "include_hidden": False, "max_distance_mm": 500}),
        ("scene_stats", {}, "scene_stats", {"top": 10, "max_seconds": 20}),
        ("scene_stats", {"id": 3}, "scene_stats", {"top": 10, "max_seconds": 20, "id": "3"}),
        ("get_attributes", {"id": 4}, "get_attributes",
         {"id": "4", "include_definition": True}),
        ("get_attributes", {"id": 4, "dictionary": "dynamic_attributes"}, "get_attributes",
         {"id": "4", "include_definition": True, "dictionary": "dynamic_attributes"}),
        ("select_entities", {"ids": [1, 2]}, "select_entities",
         {"mode": "replace", "ids": ["1", "2"]}),
        ("select_entities", {"mode": "clear"}, "select_entities", {"mode": "clear"}),
        ("set_entity_properties", {"ids": [1], "tag": "Erase"}, "set_entity_properties",
         {"ids": ["1"], "create_tag": True, "tag": "Erase"}),
        ("set_entity_properties", {"ids": [1], "hidden": False, "name": ""},
         "set_entity_properties",
         {"ids": ["1"], "create_tag": True, "hidden": False, "name": ""}),
        ("set_attributes", {"id": 1, "dictionary": "d", "values": {"a": 1, "b": None}},
         "set_attributes",
         {"id": "1", "dictionary": "d", "values": {"a": 1, "b": None},
          "target": "instance"}),
        ("profile_view", {}, "profile_view", {"frames": 20, "orbit_degrees": 0.0}),
        ("eval_ruby_dry_run", {"code": "1"}, "eval_ruby_dry_run", {"code": "1"}),
        ("reload_ruby", {"paths": ["a.rb"]}, "reload_ruby",
         {"paths": ["a.rb"], "stop_on_error": True}),
    ],
)
async def test_wrapper_sends_ruby_name_and_arguments(tool, kwargs, ruby_name,
                                                     ruby_kwargs, conn):
    result = await mcp.call_tool(tool, kwargs)
    assert "ok" in json.dumps(_plain(result))
    conn.send_command.assert_called_once_with(ruby_name, ruby_kwargs)


def _plain(result):
    """FastMCP's call_tool returns content blocks (and, on newer versions, a
    structured copy); reduce either to text for the assertion."""
    blocks = result[0] if isinstance(result, tuple) else result
    return [getattr(b, "text", None) for b in blocks]


@pytest.mark.parametrize(
    "tool, kwargs, field",
    [
        ("solid_report", {"ids": []}, "ids"),
        ("solid_report", {"ids": [1], "max_samples": 51}, "max_samples"),
        ("solid_report", {"ids": [1], "max_seconds": 0.5}, "max_seconds"),
        ("query_faces", {"orientation": "left"}, "orientation"),
        ("query_faces", {"normal": [0, 1]}, "normal"),
        ("query_faces", {"within_mm": {"min": [0, 0, 0]}}, "within_mm"),
        ("query_faces", {"limit": 501}, "limit"),
        ("find_overlaps", {"ids": [1]}, "ids"),
        ("find_overlaps", {"ids": [1, 2], "samples_per_axis": 41}, "samples_per_axis"),
        ("raycast", {"origin_mm": [0, 0, 0], "direction": [0, 0]}, "direction"),
        ("raycast", {"origin_mm": [0, 0, 0], "direction": [0, 0, 1], "max_distance_mm": 0},
         "max_distance_mm"),
        ("select_entities", {"mode": "invert"}, "mode"),
        ("set_entity_properties", {"ids": []}, "ids"),
        ("set_attributes", {"id": 1, "dictionary": "d", "values": {}}, "values"),
        ("set_attributes", {"id": 1, "dictionary": "d", "values": {"k": {"a": 1}}}, "values"),
        ("capture_view", {"max_size": 32}, "max_size"),
        ("capture_view", {"margin": 4}, "margin"),
        ("profile_view", {"frames": 0}, "frames"),
        ("reload_ruby", {"paths": []}, "paths"),
        ("eval_ruby_dry_run", {"code": ""}, "code"),
    ],
)
async def test_schema_refuses_bad_arguments(tool, kwargs, field, conn):
    with pytest.raises(Exception) as exc_info:
        await mcp.call_tool(tool, kwargs)
    assert field in str(exc_info.value)
    conn.send_command.assert_not_called()


async def test_capture_view_returns_the_image_and_its_metadata(conn):
    from sketchup_mcp.jini_tools import capture_view

    meta = {"width": 1, "height": 1, "preset_used": "iso", "style_used": "default",
            "fitted_bbox_mm": {"min": [0, 0, 0], "max": [1, 1, 1]}, "hidden_count": 7,
            "warnings": []}
    conn.send_command.return_value = {
        "content": [{"type": "text", "text": json.dumps(
            {**meta, "png_base64": base64.b64encode(TINY_PNG).decode()})}]
    }
    out = await capture_view(MagicMock(), ids=[5], view_preset="iso")
    assert isinstance(out[0], Image)
    assert out[0].data == TINY_PNG
    assert json.loads(out[1]) == meta
    conn.send_command.assert_called_once_with(
        "capture_view",
        {"view_preset": "iso", "style": "default", "max_size": 1024, "margin": 1.15,
         "ids": ["5"]},
    )


async def test_capture_view_forwards_isolate_and_fit_only_when_given(conn):
    from sketchup_mcp.jini_tools import capture_view

    conn.send_command.return_value = {"content": [{"text": json.dumps(
        {"png_base64": base64.b64encode(TINY_PNG).decode()})}]}
    await capture_view(MagicMock(), ids=[5], isolate=False, fit=True)
    sent = conn.send_command.call_args.args[1]
    assert sent["isolate"] is False and sent["fit"] is True


@pytest.mark.parametrize(
    "reply, message",
    [
        ({"content": [{"text": "not json"}]}, "not JSON"),
        ({"content": [{"text": "[1]"}]}, "not a JSON object"),
        ({"content": [{"text": "{}"}]}, "missing png_base64"),
        ({"content": [{"text": json.dumps({"png_base64": "!!"})}]}, "decode failed"),
    ],
)
async def test_capture_view_rejects_malformed_replies(reply, message, conn):
    from sketchup_mcp.jini_tools import capture_view

    conn.send_command.return_value = reply
    with pytest.raises(SketchUpError) as exc_info:
        await capture_view(MagicMock())
    assert message in exc_info.value.message


async def test_capture_view_names_the_missing_plugin_build(conn):
    from sketchup_mcp.jini_tools import capture_view

    conn.send_command.side_effect = SketchUpError(-32601, "unknown tool: capture_view")
    with pytest.raises(SketchUpError) as exc_info:
        await capture_view(MagicMock())
    assert "jini-tools branch" in exc_info.value.message


async def test_old_plugin_gets_a_hint(conn):
    from sketchup_mcp.jini_tools import solid_report

    conn.send_command.side_effect = SketchUpError(-32601, "unknown tool: solid_report")
    out = await solid_report(MagicMock(), ids=[1])
    assert out.startswith("[-32601] unknown tool: solid_report")
    assert "jini-tools branch" in out


@pytest.mark.parametrize("tool, kwargs", [("eval_ruby_dry_run", {"code": "1"}),
                                          ("reload_ruby", {"paths": ["a.rb"]})])
async def test_eval_gate_message_passes_through(tool, kwargs, conn):
    import sketchup_mcp.jini_tools as jt

    conn.send_command.side_effect = SketchUpError(
        -32010, "eval_ruby is disabled. Open Plugins → MCP Server → Settings...")
    out = await getattr(jt, tool)(MagicMock(), **kwargs)
    assert out.startswith("eval_ruby is disabled")


async def test_other_errors_name_the_tool(conn):
    from sketchup_mcp.jini_tools import raycast

    conn.send_command.side_effect = SketchUpError(-32000, "connection error: lost")
    out = await raycast(MagicMock(), origin_mm=[0, 0, 0], direction=[0, 0, 1])
    assert "tool=raycast" in out


async def test_connection_refused_is_a_plain_message():
    from sketchup_mcp.jini_tools import get_edit_context

    with patch("sketchup_mcp.tools.get_connection",
               AsyncMock(side_effect=ConnectionError("refused"))):
        out = await get_edit_context(MagicMock())
    assert "SketchUp not running" in out


def test_retry_list_holds_only_the_reads():
    from sketchup_mcp.connection import _RETRY_SAFE_TOOLS

    reads = {"get_edit_context", "query_faces", "find_overlaps", "raycast",
             "scene_stats", "get_attributes", "capture_view", "profile_view"}
    writes = {"select_entities", "set_entity_properties", "set_attributes",
              "eval_ruby_dry_run", "reload_ruby",
              # save_as + compare_with on one label must not run twice.
              "solid_report"}
    assert reads <= _RETRY_SAFE_TOOLS
    assert not writes & _RETRY_SAFE_TOOLS


async def test_descriptions_state_units_and_returns():
    tools = {t.name: t for t in await mcp.list_tools()}
    pins = {
        "solid_report": "volume_mm3",
        "query_faces": "vertices_mm",
        "find_overlaps": "overlap_volume_mm3",
        "raycast": "distance_mm",
        "scene_stats": "faces_total",
        "capture_view": "fitted_bbox_mm",
        "profile_view": "fps_median",
        "eval_ruby_dry_run": "rolled_back",
        "reload_ruby": "failed",
    }
    for name, fragment in pins.items():
        assert fragment in (tools[name].description or ""), name
