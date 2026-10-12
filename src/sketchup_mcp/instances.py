"""MCP tools for working with several SketchUp processes at once.

On Windows every open model is its own SketchUp process with its own server
(see :mod:`sketchup_mcp.discovery`). These two tools show which are running
and choose the one every other tool acts on.
"""
import json
from typing import Annotated, Optional

from mcp.server.fastmcp import Context
from pydantic import Field

from sketchup_mcp import connection, discovery
from sketchup_mcp.app import mcp


@mcp.tool()
async def list_sketchup_instances(ctx: Context) -> str:
    """List every running SketchUp this server can reach, and which one the
    other tools act on.

    On Windows each open model window is its own SketchUp process with its
    own MCP server: the first on port 9876 (SKETCHUP_MCP_PORT), the next ones
    on the following free ports. Each entry gives the port, the process id,
    the model's title and path and the SketchUp version; status is "ready",
    or "busy" for one in the middle of a long operation. Use
    select_sketchup_instance to act on another one.
    """
    found = await discovery.discover()
    target = connection.target_port()
    return json.dumps(
        {
            "target_port": target,
            "target": connection.target_reason(),
            "instances": [
                {**instance.as_dict(), "target": instance.port == target}
                for instance in found
            ],
        },
        indent=2,
    )


@mcp.tool()
async def select_sketchup_instance(
    ctx: Context,
    port: Annotated[
        Optional[int], Field(description="The instance's port, from list_sketchup_instances")
    ] = None,
    pid: Annotated[Optional[int], Field(description="The instance's process id")] = None,
    model: Annotated[
        Optional[str],
        Field(description="Part of the model's title or file path, any case"),
    ] = None,
    automatic: Annotated[
        bool,
        Field(
            description="Drop the choice: act on the first port's SketchUp, or on "
            "the only one running when that one has gone"
        ),
    ] = False,
) -> str:
    """Choose the SketchUp every other tool acts on, by port, process id or
    model name.

    The choice holds until it is changed, or the SketchUp closes - then the
    tools say so rather than turning to another one. Give one of port, pid or
    model; a model name matching more than one instance is refused with the
    candidates. automatic=true drops the choice.
    """
    if automatic:
        connection.select_port(None)
        return json.dumps(
            {"target_port": connection.target_port(), "target": connection.target_reason()},
            indent=2,
        )
    if port is None and pid is None and not model:
        return "Give port, pid or model - or automatic=true to drop the choice."
    found = await discovery.discover()
    picked = discovery.matching(found, port=port, pid=pid, model=model)
    if not picked:
        running = "; ".join(discovery.describe(one) for one in found) or "none"
        return f"No running SketchUp matches that. Running: {running}."
    if len(picked) > 1:
        names = "; ".join(discovery.describe(one) for one in picked)
        return f"{len(picked)} SketchUp instances match - be more specific: {names}."
    chosen = picked[0]
    if chosen.status != "ready":
        return (
            f"The SketchUp on {discovery.describe(chosen)} is {chosen.status} "
            f"({chosen.detail}) - not chosen."
        )
    connection.select_port(chosen.port)
    return json.dumps(
        {"target_port": chosen.port, "target": "selected", "instance": chosen.as_dict()},
        indent=2,
    )
