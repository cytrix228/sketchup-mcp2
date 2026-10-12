# Several SketchUp windows, one MCP server

On Windows, SketchUp runs every open model in its own process. Each process
loads the plugin and runs its own MCP server, but only one of them can have
port 9876. The others used to have nowhere to go: starting their server failed
with "address in use", and the autostart skipped them. The MCP client could
only reach the first SketchUp that was opened.

Now every SketchUp gets a server, and one MCP server reaches all of them:

- **Each SketchUp takes the next free port.** The first takes 9876 (the
  plugin's `port` setting), the next 9877, and so on, up to 10 ports in all.
- **The MCP server finds them all** with `list_sketchup_instances`, and
  `select_sketchup_instance` chooses the one every other tool acts on.

## The two tools

| Tool | What it does | Changes the model? |
|---|---|---|
| `list_sketchup_instances` | Lists every SketchUp reachable on the port range: port, process id, model title and path, SketchUp version, status. Marks the one the tools act on. | no |
| `select_sketchup_instance` | Chooses the SketchUp the other tools act on, by `port`, `pid` or `model` (part of the title or file path, any case). `automatic=true` drops the choice. | no |

A model name matching more than one window is refused, with the candidates
listed. So is a SketchUp that is `busy`, meaning it took the connection but
did not answer the handshake in time (usually because it is running a long
operation).

## Which SketchUp the tools act on

1. **The one chosen** with `select_sketchup_instance`. A choice is never
   swapped for another behind your back. If that SketchUp closes, the tools
   say so and ask for a new choice.
2. **Otherwise, the first port's** (9876): the first SketchUp opened. Nothing
   changes for a single window.
3. **If the first port's SketchUp has gone and exactly one other is
   running,** the tools follow that one, and keep following it until it goes
   too. This is safe because a refused connection means the call was never
   sent. If several others are running, the tool refuses to guess and lists
   them.

Each MCP client (each Claude Code session, say) runs its own MCP server, so
each has its own choice.

## Configuration

| Side | Setting | Default | |
|---|---|---|---|
| Python | `SKETCHUP_MCP_PORT` | `9876` | The first port |
| Python | `SKETCHUP_MCP_PORT_SPAN` | `10` | How many ports from the first one to look on |
| Ruby | Settings → port | `9876` | The first port this SketchUp tries |
| Ruby | `Config::PORT_SPAN` | `10` | How many ports it tries before giving up |

Keep the two spans equal. A SketchUp beyond the Python span is running but
cannot be found.

## Upgrading

Both halves must be new for a second SketchUp to be reachable, but mixing
versions is safe:

- **New plugin, old MCP server:** every SketchUp gets a port, but the client
  only ever talks to 9876, as before.
- **Old plugin, new MCP server:** discovery still lists an old-plugin
  SketchUp, by its model's title and path (from `get_model_info`), without a
  process id. An old plugin cannot move on to a free port, so it is only ever
  on 9876.
- **The autostart** (MCP Server Autostart 1.1.0, in `sketchup_tools`) starts
  the server in every SketchUp when the plugin can move on. With an older
  plugin it still skips a SketchUp whose port is taken, as before.

A running SketchUp keeps the plugin code it loaded at launch: restart it to
pick up the new files. The MCP client keeps the server it started, so restart
that too (in Claude Code, `/mcp` → reconnect, or a new session).

## Code map and tests

- **Ruby:**
  - `core/server.rb` — `bind_first_free` and `Server#port`.
  - `core/application.rb` — `running_config[:port]` is the port actually
    bound.
  - `core/config.rb` — `PORT_SPAN`.
  - `handlers/system.rb` — `get_instance_info`, which returns `pid`, `host`,
    `port`, `model_title`, `model_path`, `sketchup_version` and
    `server_version`.
- **Python:**
  - `connection.py` — one connection per port, and the target
    (`target_port`, `select_port`, `follow_port`).
  - `discovery.py` — `probe`, `discover`, `follow_lone_instance`,
    `matching`; no MCP imports.
  - `instances.py` — the two tools.
  - `tools.py::_raw_call` — follows the lone instance on a refused connect.
- **Tests:**
  - `test/test_multi_instance.rb` — port fallback on real sockets, the
    span limit, the bound port, `get_instance_info` and its dispatch.
  - `tests/test_instances.py` — a fake SketchUp speaking the real wire
    protocol, plus discovery, choice and follow.
  - `tests/conftest.py` stubs discovery for every test. Without it, a test
    faking a refused connection could find the SketchUp running on the
    developer's machine and send it the call.

Verified on Windows 11 with SketchUp 2026 on 9876 (an old-plugin window) and
three stand-in SketchUp processes, each running the real plugin files and the
autostart under plain Ruby. They started on 9877, 9878 and 9879. The test
checked, in turn:

- discovery listed all four;
- a selection by model name routed calls to that process;
- an ambiguous name was refused;
- with the first port gone and two others running, a call refused to guess;
- with one other running, the call followed it.
