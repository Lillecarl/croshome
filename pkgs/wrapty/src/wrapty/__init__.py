"""wrapty: a PTY wrapper with a JSON-RPC control socket, plus the Claude Code
statusline, MCP server and hooks that talk to it.

Nothing is re-exported here. Each console script names its own module, and the
modules are independent enough that importing one should not drag in the rest:
`wrapty.mcp` pulls in the mcp package, `wrapty.hooks` pulls in jinja2, and the
wrapper itself needs neither.
"""

__version__ = "0.1.0"
