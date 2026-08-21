"""
Postgres access: a connection pool, and thin wrappers for calling
MacroMCP's SQL functions and views. This module does no business logic of
its own - every function here maps directly to something in db/schema.sql.
"""

from __future__ import annotations

import atexit

import psycopg
from mcp.server.mcpserver.exceptions import ToolError
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb
from psycopg_pool import ConnectionPool

from server.config import DATABASE_URL

_pool = ConnectionPool(
    DATABASE_URL,
    min_size=1,
    max_size=4,
    kwargs={"row_factory": dict_row, "autocommit": True},
)
# Without this, the pool's background worker thread gets joined during
# interpreter finalization instead of before it, which raises a noisy (but
# harmless) PythonFinalizationError on every clean exit under 3.13+.
atexit.register(_pool.close)

# Re-exported: a rejection raised by an fn_* function (duplicate warning,
# Atwater mismatch, structural problem, ownership check failing) is not a
# bug - it's meant to be read by the calling model and explained to the
# user, per "When commit_log rejects the payload" in docs/intake-agent.md.
# Using the SDK's own ToolError means the MCP layer surfaces it as a
# structured tool error to the caller instead of crashing the connection.
__all__ = [
    "ToolError",
    "resolve_user_id",
    "resolve_user_id_by_auth0_sub",
    "call_scalar",
    "call_rows",
    "call_row",
    "as_jsonb",
]


def resolve_user_id(username: str) -> int:
    with _pool.connection() as conn:
        row = conn.execute(
            "SELECT id FROM users WHERE username = %s", (username,)
        ).fetchone()
    if row is None:
        raise ToolError(
            f"no such user {username!r} - create it first with: "
            f"INSERT INTO users (username, display_name) VALUES ('{username}', '...')"
        )
    return row["id"]


def resolve_user_id_by_auth0_sub(auth0_sub: str) -> int:
    """
    For streamable-http: auth0_sub comes from an ALREADY-VERIFIED token
    (server/auth.py checked its signature, issuer, and audience before this
    is ever called) - this function only maps that verified identity to a
    users.id, the same trust boundary fn_commit_log already assumes for
    p_user_id. A miss here means the website's JIT provisioning
    (web/src/lib/db.ts) hasn't run for this identity yet, not that the
    token itself is bad.
    """
    with _pool.connection() as conn:
        row = conn.execute(
            "SELECT id FROM users WHERE auth0_sub = %s", (auth0_sub,)
        ).fetchone()
    if row is None:
        raise ToolError(
            "no MacroMCP account linked to this identity yet - log in at "
            "the website first so it can be provisioned"
        )
    return row["id"]


def _run(fn):
    try:
        return fn()
    except psycopg.errors.RaiseException as e:
        raise ToolError(_clean(e)) from None
    except psycopg.errors.UniqueViolation as e:
        raise ToolError(_clean(e)) from None
    except psycopg.errors.CheckViolation as e:
        raise ToolError(_clean(e)) from None


def _clean(e: Exception) -> str:
    # psycopg's exception message is prefixed with the SQLSTATE diagnostic
    # context Postgres adds (function name, line number). Keep only the
    # RAISE EXCEPTION message itself - the part the human/model should read.
    msg = str(e).strip()
    return msg.splitlines()[0]


def call_scalar(sql: str, params: tuple):
    """One row, one column."""
    def go():
        with _pool.connection() as conn:
            row = conn.execute(sql, params).fetchone()
        return None if row is None else next(iter(row.values()))
    return _run(go)


def call_rows(sql: str, params: tuple) -> list[dict]:
    def go():
        with _pool.connection() as conn:
            return conn.execute(sql, params).fetchall()
    return _run(go)


def call_row(sql: str, params: tuple) -> dict | None:
    rows = call_rows(sql, params)
    return rows[0] if rows else None


def as_jsonb(payload: dict) -> Jsonb:
    return Jsonb(payload)
