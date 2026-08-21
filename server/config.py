"""
Config for the MCP server. Two identity modes, matching two different
consumers this server has to support - see docs/auth-setup.md:

- stdio + MACROMCP_USERNAME: one server process = one user, the process
  itself IS the identity (no verification - matches how Claude Desktop/Code
  run one local subprocess per configured server). The original model,
  still the simplest path for local/personal use.

- streamable-http + Auth0: identity is resolved PER REQUEST from a
  verified bearer token (server/auth.py), looked up via users.auth0_sub.
  Needed once this server is reachable over the network rather than run as
  a trusted local subprocess.

MACROMCP_TRANSPORT selects which. Whichever is selected, its identity
source must actually be configured, or nothing could ever resolve a user.
"""

import os


class ConfigError(RuntimeError):
    pass


DATABASE_URL = os.environ.get("MACROMCP_DATABASE_URL", "postgresql:///macromcp")

TRANSPORT = os.environ.get("MACROMCP_TRANSPORT", "stdio")
if TRANSPORT not in ("stdio", "streamable-http"):
    raise ConfigError(
        f"MACROMCP_TRANSPORT must be 'stdio' or 'streamable-http', got {TRANSPORT!r}"
    )

USERNAME = os.environ.get("MACROMCP_USERNAME")

# AUTH0_AUDIENCE doubles as this resource server's own identifier (the
# Identifier from docs/auth-setup.md Part A) - both the JWT audience
# token_verifier checks against, and the resource_server_url AuthSettings
# needs for the OAuth Protected Resource Metadata endpoint. It's the same
# URL-shaped opaque label either way, no reason to have two env vars for it.
AUTH0_DOMAIN = os.environ.get("AUTH0_DOMAIN")
AUTH0_AUDIENCE = os.environ.get("AUTH0_AUDIENCE")

if TRANSPORT == "stdio":
    if not USERNAME:
        raise ConfigError(
            "MACROMCP_USERNAME is not set. stdio transport is scoped to one "
            "user per process - set it to the username row this server "
            "instance should act as."
        )
else:  # streamable-http
    if not (AUTH0_DOMAIN and AUTH0_AUDIENCE):
        raise ConfigError(
            "AUTH0_DOMAIN and AUTH0_AUDIENCE must both be set for "
            "streamable-http transport - identity is resolved per request "
            "from a verified token, not a fixed process-wide user, so "
            "there's no other way to check one."
        )
