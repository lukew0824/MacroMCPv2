"""
MCP server entrypoint. Registers each MacroMCP tool from server/tools.py.
This module wires the MCP SDK to that logic and does nothing else - see
docs/intake-agent.md for the tool contract this implements, and
docs/design-notes.md for why the underlying database is shaped this way.

Run with: MACROMCP_USERNAME=luke python -m server.server
"""

from __future__ import annotations

from mcp.server.mcpserver import MCPServer

from server import tools
from server.models import CommitPayload

app = MCPServer(
    name="macromcp",
    instructions=(
        "Tools for logging and querying one person's food intake. Macros "
        "are always per-100g, never absolute - the server does every "
        "multiplication. Call new_staging_id immediately before commit_log. "
        "Every fn_commit_log rejection is a specific, fixable reason, not a "
        "dead end - read the message and either fix the payload or resubmit "
        "with the matching confirm flag after checking with the user."
    ),
)


@app.tool()
def new_staging_id() -> dict:
    """Mint a fresh id for the entry you're about to commit. Call this immediately before commit_log, using the returned staging_id in that call."""
    return tools.new_staging_id()


@app.tool()
def find_attachable_meals(eaten_at: str, meal_type_key: str) -> list[dict]:
    """Find meals already logged today, near this time, of this meal type, that a new entry might belong to (e.g. 'oh and I also had...'). Returns candidates only - never attaches anything."""
    return tools.find_attachable_meals(eaten_at, meal_type_key)


@app.tool()
def find_prior_meal(description: str, date_hint: str | None = None) -> list[dict]:
    """Look up a previously logged meal by rough description and an optional exact date (YYYY-MM-DD). Use to reuse a prior meal's composition for a new entry, or to locate a meal_id to attach a forgotten detail to or supersede with a correction. Does not change anything by itself - always confirm which specific meal it found with the user first."""
    return tools.find_prior_meal(description, date_hint)


@app.tool()
def commit_log(
    staging_id: str,
    payload: CommitPayload,
    confirm_duplicate: bool = False,
    confirm_atwater: bool = False,
) -> dict:
    """Commit a fully-resolved, user-confirmed food log entry. Rejected if items are unanchored, ingredients are missing macros, a composite item's decomposition wasn't confirmed, or the stated macros are internally incoherent - read the error and fix the specific problem, don't retry blindly."""
    return tools.commit_log(staging_id, payload, confirm_duplicate, confirm_atwater)


@app.tool()
def supersede_log(old_log_id: int, staging_id: str, payload: CommitPayload) -> dict:
    """Correct an already-committed log entry (e.g. the user says 'actually it was 10oz not 7oz'). Marks the old entry superseded and commits a new one in its place. For a missing detail that was never stated at all (e.g. forgotten cooking oil), use commit_log with meal.meal_id set instead - don't supersede for that."""
    return tools.supersede_log(old_log_id, staging_id, payload)


@app.tool()
def rename_meal(meal_id: int, name: str) -> dict:
    """Change a meal's display name. Only call when the user explicitly asks to rename something."""
    return tools.rename_meal(meal_id, name)


@app.tool()
def get_day(log_date: str) -> dict:
    """Get all meals and totals for one day (YYYY-MM-DD)."""
    return tools.get_day(log_date)


@app.tool()
def get_meal(meal_id: int) -> dict:
    """Get full detail (items, ingredients, macros) for one meal."""
    return tools.get_meal(meal_id)


@app.tool()
def get_totals(start_date: str, end_date: str) -> dict:
    """Get summed macros over a date range (YYYY-MM-DD, inclusive), e.g. for 'how's my protein this week'."""
    return tools.get_totals(start_date, end_date)


@app.tool()
def get_trend(food_name_or_key: str, start_date: str | None = None, end_date: str | None = None) -> list[dict]:
    """Get how often and how much of a specific food has been logged over time. Grouping is by a generated slug, so near-duplicate names ('chicken breast' vs 'grilled chicken breast') won't merge."""
    return tools.get_trend(food_name_or_key, start_date, end_date)


@app.tool()
def search_log(query: str) -> list[dict]:
    """Fuzzy free-text search over previously logged food names."""
    return tools.search_log(query)


@app.tool()
def get_data_quality(start_date: str, end_date: str | None = None) -> list[dict]:
    """Get the provenance breakdown (how much of the day's calories came from recalled knowledge vs. estimates vs. user-stated numbers) for a date or range."""
    return tools.get_data_quality(start_date, end_date)


def main() -> None:
    app.run()


if __name__ == "__main__":
    main()
