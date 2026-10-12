"""Several SketchUp processes behind one MCP server: the per-port
connections, finding the instances, choosing one, and following the only one
left when the first port's goes away (docs/multi-instance.md)."""
import asyncio
import json
import socket
import struct
from unittest.mock import AsyncMock, MagicMock

import pytest

from sketchup_mcp import compat, config, connection, discovery
from sketchup_mcp.app import mcp
from sketchup_mcp.discovery import Instance

# The autouse fixture in conftest.py stubs discovery.discover; the real one is
# kept here for the tests of discovery itself.
REAL_DISCOVER = discovery.discover


class FakeSketchUp:
    """A server speaking the plugin's wire protocol, for probe()."""

    def __init__(self, info=None, legacy=False, silent=False):
        self.info = info or {}
        self.legacy = legacy
        self.silent = silent
        self.server = None
        self.port = None

    async def __aenter__(self):
        self.server = await asyncio.start_server(self._serve, "127.0.0.1", 0)
        self.port = self.server.sockets[0].getsockname()[1]
        return self

    async def __aexit__(self, *exc):
        self.server.close()
        await self.server.wait_closed()

    async def _serve(self, reader, writer):
        try:
            while True:
                (length,) = struct.unpack(">I", await reader.readexactly(4))
                request = json.loads(await reader.readexactly(length))
                if self.silent:
                    continue  # never answers; ends when the client lets go
                body = json.dumps(self._reply(request)).encode()
                writer.write(struct.pack(">I", len(body)) + body)
                await writer.drain()
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            writer.close()

    def _reply(self, request):
        rid = request.get("id")
        if request.get("method") == "hello":
            result = {"server_version": compat.MIN_RUBY, "client_id": 1}
            return {"jsonrpc": "2.0", "result": result, "id": rid}
        name = request["params"]["name"]
        if name == "get_instance_info" and not self.legacy:
            payload = self.info
        elif name == "get_model_info":
            payload = {"title": self.info.get("model_title"), "path": self.info.get("model_path")}
        else:
            error = {"code": -32601, "message": f"unknown tool: {name}"}
            return {"jsonrpc": "2.0", "error": error, "id": rid}
        content = [{"type": "text", "text": json.dumps(payload)}]
        return {"jsonrpc": "2.0", "result": {"content": content, "isError": False}, "id": rid}


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _text(result) -> str:
    blocks = result[0] if isinstance(result, tuple) else result
    return blocks[0].text


LEVEL_1 = Instance(9876, "ready", pid=101, model_title="Level 1", model_path="C:/m/level1.skp")
LEVEL_2 = Instance(9877, "ready", pid=102, model_title="Level 2", model_path="C:/m/level2.skp")
COPY_2 = Instance(9878, "ready", pid=103, model_title="Level 2 copy", model_path="C:/m/copy.skp")


# ---- probing one port ------------------------------------------------------

@pytest.mark.asyncio
async def test_probe_reads_the_instance():
    info = {"pid": 4242, "model_title": "Level 2", "model_path": "C:/m/level2.skp",
            "sketchup_version": "26.1.0", "server_version": "0.3.1"}
    async with FakeSketchUp(info) as fake:
        found = await discovery.probe(fake.port, timeout=2.0)
    assert found.status == "ready"
    assert (found.port, found.pid, found.model_title) == (fake.port, 4242, "Level 2")
    assert found.sketchup_version == "26.1.0"


@pytest.mark.asyncio
async def test_probe_names_the_model_of_a_plugin_from_before_multi_instance():
    async with FakeSketchUp({"model_title": "Old", "model_path": "C:/m/old.skp"}, legacy=True) as fake:
        found = await discovery.probe(fake.port, timeout=2.0)
    assert found.status == "ready"
    assert found.model_title == "Old"
    assert found.pid is None


@pytest.mark.asyncio
async def test_probe_finds_nothing_where_nothing_listens():
    assert await discovery.probe(_free_port(), timeout=0.5) is None


@pytest.mark.asyncio
async def test_probe_reports_a_sketchup_that_does_not_answer_as_busy():
    async with FakeSketchUp(silent=True) as fake:
        found = await discovery.probe(fake.port, timeout=0.2)
    assert found.status == "busy"


@pytest.mark.asyncio
async def test_discover_lists_what_answers_in_port_order(monkeypatch):
    monkeypatch.setattr(config, "PORT", 9876)
    monkeypatch.setattr(config, "PORT_SPAN", 4)
    answers = {9877: LEVEL_2, 9876: LEVEL_1}

    async def fake_probe(port, timeout=discovery.PROBE_TIMEOUT):
        return answers.get(port)

    monkeypatch.setattr(discovery, "probe", fake_probe)
    assert [one.port for one in await REAL_DISCOVER()] == [9876, 9877]
    assert discovery.ports() == [9876, 9877, 9878, 9879]


# ---- which SketchUp the tools act on ---------------------------------------

def test_the_first_port_until_something_else_is_chosen():
    assert connection.target_port() == config.PORT
    connection.follow_port(9877)
    assert connection.target_port() == 9877
    assert connection.target_reason().startswith("followed")
    connection.select_port(9878)
    assert (connection.target_port(), connection.target_reason()) == (9878, "selected")
    connection.select_port(None)
    assert connection.target_port() == config.PORT


def test_following_never_overrides_a_choice():
    connection.select_port(9878)
    connection.follow_port(9877)
    assert connection.target_port() == 9878


@pytest.mark.asyncio
async def test_one_connection_per_port():
    first = await connection.get_connection(9876)
    assert await connection.get_connection(9876) is first
    other = await connection.get_connection(9877)
    assert other is not first and other.port == 9877
    connection.select_port(9877)
    assert await connection.get_connection() is other


@pytest.mark.asyncio
async def test_closing_closes_every_connection():
    conns = [await connection.get_connection(port) for port in (9876, 9877)]
    for conn in conns:
        conn.aclose = AsyncMock()
    await connection.close_connection()
    for conn in conns:
        conn.aclose.assert_awaited_once()
    assert connection._connections == {}


# ---- following the only one left -------------------------------------------

@pytest.mark.asyncio
async def test_nothing_to_follow_when_nothing_runs():
    assert await discovery.follow_lone_instance() is None
    assert connection.target_port() == config.PORT


@pytest.mark.asyncio
async def test_follows_the_only_sketchup_running(monkeypatch):
    monkeypatch.setattr(discovery, "discover", AsyncMock(return_value=[LEVEL_2]))
    conn = await discovery.follow_lone_instance()
    assert conn.port == 9877
    assert connection.target_port() == 9877


@pytest.mark.asyncio
async def test_never_guesses_between_several(monkeypatch):
    monkeypatch.setattr(discovery, "discover", AsyncMock(return_value=[LEVEL_2, COPY_2]))
    with pytest.raises(ConnectionError, match="select_sketchup_instance"):
        await discovery.follow_lone_instance()
    assert connection.target_port() == config.PORT


@pytest.mark.asyncio
async def test_a_chosen_sketchup_is_never_swapped(monkeypatch):
    finder = AsyncMock(return_value=[LEVEL_2])
    monkeypatch.setattr(discovery, "discover", finder)
    connection.select_port(9878)
    with pytest.raises(ConnectionError, match="chosen with select_sketchup_instance"):
        await discovery.follow_lone_instance()
    finder.assert_not_awaited()
    assert connection.target_port() == 9878


@pytest.mark.asyncio
async def test_a_refused_call_goes_to_the_one_left(monkeypatch):
    from sketchup_mcp import tools

    gone = MagicMock()
    gone.send_command = AsyncMock(side_effect=ConnectionError("refused"))
    other = MagicMock()
    other.send_command = AsyncMock(return_value={"content": [{"type": "text", "text": "ok"}]})
    monkeypatch.setattr(tools, "get_connection", AsyncMock(return_value=gone))
    monkeypatch.setattr(discovery, "follow_lone_instance", AsyncMock(return_value=other))
    result = await tools._raw_call(None, "get_model_info")
    assert result["content"][0]["text"] == "ok"
    other.send_command.assert_awaited_once_with("get_model_info", {})


@pytest.mark.asyncio
async def test_a_refused_call_with_nowhere_to_go_says_so(monkeypatch):
    from sketchup_mcp import tools

    gone = MagicMock()
    gone.send_command = AsyncMock(side_effect=ConnectionError("refused"))
    monkeypatch.setattr(tools, "get_connection", AsyncMock(return_value=gone))
    with pytest.raises(ConnectionError, match="refused"):
        await tools._raw_call(None, "get_model_info")


# ---- the two tools ---------------------------------------------------------

@pytest.mark.asyncio
async def test_list_marks_the_one_the_tools_act_on(monkeypatch):
    monkeypatch.setattr(discovery, "discover", AsyncMock(return_value=[LEVEL_1, LEVEL_2]))
    listed = json.loads(_text(await mcp.call_tool("list_sketchup_instances", {})))
    assert listed["target_port"] == config.PORT
    assert [(one["port"], one["target"]) for one in listed["instances"]] == [
        (9876, True), (9877, False)]
    assert listed["instances"][1]["model_title"] == "Level 2"


@pytest.mark.asyncio
async def test_select_by_model_name(monkeypatch):
    monkeypatch.setattr(discovery, "discover", AsyncMock(return_value=[LEVEL_1, LEVEL_2]))
    chosen = json.loads(_text(await mcp.call_tool("select_sketchup_instance", {"model": "level2.SKP"})))
    assert chosen["target_port"] == 9877
    assert connection.target_port() == 9877


@pytest.mark.asyncio
async def test_select_refuses_a_name_matching_several(monkeypatch):
    monkeypatch.setattr(discovery, "discover", AsyncMock(return_value=[LEVEL_1, LEVEL_2, COPY_2]))
    text = _text(await mcp.call_tool("select_sketchup_instance", {"model": "level 2"}))
    assert "2 SketchUp instances match" in text
    assert connection.target_port() == config.PORT


@pytest.mark.asyncio
async def test_select_refuses_what_is_not_running(monkeypatch):
    monkeypatch.setattr(discovery, "discover", AsyncMock(return_value=[LEVEL_1]))
    text = _text(await mcp.call_tool("select_sketchup_instance", {"pid": 999}))
    assert text.startswith("No running SketchUp matches")


@pytest.mark.asyncio
async def test_select_refuses_a_busy_one(monkeypatch):
    busy = Instance(9877, "busy", detail="handshake timed out after 3.0s")
    monkeypatch.setattr(discovery, "discover", AsyncMock(return_value=[LEVEL_1, busy]))
    text = _text(await mcp.call_tool("select_sketchup_instance", {"port": 9877}))
    assert "busy" in text
    assert connection.target_port() == config.PORT


@pytest.mark.asyncio
async def test_automatic_drops_the_choice():
    connection.select_port(9877)
    dropped = json.loads(_text(await mcp.call_tool("select_sketchup_instance", {"automatic": True})))
    assert dropped["target_port"] == config.PORT
    assert connection.selected_port() is None
