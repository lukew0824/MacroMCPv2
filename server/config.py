"""
Config for a single MCP server process = a single MacroMCP user.

This is the pragmatic answer to the "how does a request resolve to a
user_id" question left open in docs/intake-agent.md: one MCP server
instance is launched per person (matching how Claude Desktop/Code run one
subprocess per configured server), pointed at that person's username via
MACROMCP_USERNAME. There is no per-call auth - the process itself IS the
identity. Revisit if this ever needs to run as a shared multi-tenant service
instead of a local-per-user process.
"""

import os


class ConfigError(RuntimeError):
    pass


DATABASE_URL = os.environ.get("MACROMCP_DATABASE_URL", "postgresql:///macromcp")

USERNAME = os.environ.get("MACROMCP_USERNAME")
if not USERNAME:
    raise ConfigError(
        "MACROMCP_USERNAME is not set. This server is scoped to one user per "
        "process - set it to the username row this server instance should act as."
    )
