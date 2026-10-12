"""Finding the SketchUp processes this server can reach, and choosing one.

On Windows every open model is its own SketchUp process, and each runs the
plugin's server: the first on ``config.PORT``, the next ones on the following
free ports, up to ``config.PORT_SPAN`` in all (the plugin's
``Config::PORT_SPAN``). Each is found by connecting to it, as any client does
- the handshake, then ``get_instance_info`` - and let go again; nothing is
kept but what it said. The tools act on one of them at a time, chosen in
:mod:`sketchup_mcp.connection` (``target_port``).

No MCP imports here, so ``tools.py`` can use it without a cycle.
"""
import asyncio
import json
import logging
from dataclasses import asdict, dataclass
from typing import Any

from sketchup_mcp import config, connection
from sketchup_mcp.connection import SketchUpConnection
from sketchup_mcp.errors import IncompatibleVersionError, SketchUpError

logger = logging.getLogger("sketchup_mcp.discovery")

# Long enough for a SketchUp between timer ticks (0.1 s) to answer, short
# enough that one stuck in a long operation does not hold up the list: it is
# reported as "busy".
PROBE_TIMEOUT = 3.0


@dataclass
class Instance:
    """One SketchUp found on a port."""

    port: int
    status: str  # "ready", "busy", "incompatible" or "error"
    pid: int | None = None
    model_title: str | None = None
    model_path: str | None = None
    sketchup_version: str | None = None
    server_version: str | None = None
    detail: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return {key: value for key, value in asdict(self).items() if value is not None}


def _payload(result: Any) -> dict[str, Any]:
    """A handler's Hash, out of the MCP content envelope Ruby wraps it in."""
    content = result.get("content") if isinstance(result, dict) else None
    if isinstance(content, list) and content and isinstance(content[0], dict):
        try:
            parsed = json.loads(content[0].get("text", ""))
        except (TypeError, ValueError):
            return {}
        return parsed if isinstance(parsed, dict) else {}
    return {}


async def probe(port: int, timeout: float = PROBE_TIMEOUT) -> Instance | None:
    """What answers on ``port`` - or None where nothing listens."""
    conn = SketchUpConnection(host=config.HOST, port=port, timeout=timeout)
    try:
        await conn.connect()
    except OSError:
        return None
    except IncompatibleVersionError as e:
        return Instance(port, "incompatible", detail=str(e))
    except SketchUpError as e:
        if e.message.startswith("connect timed out"):
            # Windows can take seconds to refuse a connection on a loopback
            # port nothing listens on: nothing there.
            return None
        if e.message.startswith("handshake timed out"):
            # The port took the connection and never answered the handshake:
            # a SketchUp in the middle of a long operation, usually.
            return Instance(port, "busy", detail=e.message)
        return Instance(port, "error", detail=e.message)
    try:
        try:
            info = _payload(await conn.send_command("get_instance_info", {}))
        except SketchUpError as e:
            if e.code != -32601:
                raise
            # A plugin from before multi-instance: its model, at least.
            model = _payload(await conn.send_command("get_model_info", {}))
            info = {"model_title": model.get("title"), "model_path": model.get("path")}
        return Instance(
            port,
            "ready",
            pid=info.get("pid"),
            model_title=info.get("model_title"),
            model_path=info.get("model_path"),
            sketchup_version=info.get("sketchup_version"),
            server_version=info.get("server_version"),
        )
    except (SketchUpError, OSError) as e:
        return Instance(port, "error", detail=str(e))
    finally:
        await conn.disconnect()


def ports() -> list[int]:
    """Every port a SketchUp may be on, first one first."""
    return list(range(config.PORT, min(config.PORT + config.PORT_SPAN, 65536)))


async def discover(timeout: float = PROBE_TIMEOUT) -> list[Instance]:
    """Every SketchUp answering on :func:`ports`, in port order."""
    found = await asyncio.gather(*(probe(port, timeout) for port in ports()))
    return [instance for instance in found if instance is not None]


def describe(instance: Instance) -> str:
    """One line naming an instance, for messages."""
    name = instance.model_title or "(untitled)"
    pid = f", pid {instance.pid}" if instance.pid is not None else ""
    return f"port {instance.port}: {name}{pid}"


async def follow_lone_instance() -> SketchUpConnection | None:
    """After the SketchUp the tools act on refused a connection: the
    connection to the one other SketchUp running, which the tools then act on,
    or None where none is.

    Only when nothing was chosen. A SketchUp chosen with
    select_sketchup_instance is never swapped for another behind the caller's
    back, and neither is a guess made between several: both raise
    ``ConnectionError`` saying what is running instead.
    """
    gone = connection.target_port()
    if connection.selected_port() is not None:
        raise ConnectionError(
            f"the SketchUp chosen with select_sketchup_instance (port {gone}) is not "
            "reachable - it may have closed. Call list_sketchup_instances and choose "
            "again with select_sketchup_instance."
        )
    ready = [instance for instance in await discover() if instance.status == "ready"]
    if not ready:
        return None
    if len(ready) > 1:
        names = "; ".join(describe(instance) for instance in ready)
        raise ConnectionError(
            f"nothing answers on port {gone}, and {len(ready)} other SketchUp windows "
            f"are running ({names}). Choose one with select_sketchup_instance."
        )
    connection.follow_port(ready[0].port)
    logger.info("following the only SketchUp running: %s", describe(ready[0]))
    return await connection.get_connection()


def matching(
    instances: list[Instance],
    port: int | None = None,
    pid: int | None = None,
    model: str | None = None,
) -> list[Instance]:
    """The instances a port, a process id or part of a model's title or path
    (any case) picks out."""
    picked = instances
    if port is not None:
        picked = [instance for instance in picked if instance.port == port]
    if pid is not None:
        picked = [instance for instance in picked if instance.pid == pid]
    if model:
        wanted = model.casefold()
        picked = [
            instance
            for instance in picked
            if wanted in (instance.model_title or "").casefold()
            or wanted in (instance.model_path or "").casefold()
        ]
    return picked
