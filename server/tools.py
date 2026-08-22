"""
Business logic behind every MCP tool: resolves the calling user_id, calls
the matching SQL function or view, and returns JSON-serializable results.
server.py wires these functions to MCP tool decorators and does no logic
of its own.

find_prior_meal and search_log are NOT backed by dedicated SQL functions -
db/schema.sql only ships fn_* functions for the commit path and read-back.
They're implemented here as parameterized queries over the existing views/
tables (pg_trgm similarity for fuzzy matching), scoped by user_id the same
way everything else is.
"""

from __future__ import annotations

import re
from datetime import date
from functools import lru_cache

from mcp.server.auth.middleware.auth_context import get_access_token

from server import config, db
from server.db import ToolError
from server.models import CommitPayload


@lru_cache(maxsize=1)
def _stdio_user_id() -> int:
    """
    stdio only: one process = one user, so this is safe to resolve once
    and cache for the process's whole lifetime - the same trust model as
    always (MACROMCP_USERNAME picks who this instance acts as).
    """
    return db.resolve_user_id(config.USERNAME)


def _user_id() -> int:
    """
    streamable-http: resolved FRESH on every call from the current
    request's verified token (server/auth.py already checked its
    signature/issuer/audience before this ever runs) - caching this across
    requests would leak one user's identity into another's calls, which is
    exactly the cross-user bug class db/tests.sql's T14-T18 exist to catch
    at the database layer. Don't memoize this branch.
    """
    if config.TRANSPORT == "streamable-http":
        token = get_access_token()
        if token is None or not token.subject:
            raise ToolError("no authenticated identity on this request")
        return db.resolve_user_id_by_auth0_sub(token.subject)
    return _stdio_user_id()


def _slugify(food_name: str) -> str:
    """Mirrors item_ingredients.food_key's GENERATED expression exactly."""
    return re.sub(r"[^a-zA-Z0-9]+", "_", food_name).strip("_").lower()


# ---------------------------------------------------------------- resolve

def new_staging_id() -> dict:
    return {"staging_id": db.call_scalar("SELECT fn_new_staging_id()", ())}


def find_attachable_meals(eaten_at: str, meal_type_key: str) -> list[dict]:
    return db.call_rows(
        "SELECT * FROM fn_find_attachable_meals(%s, %s, %s)",
        (_user_id(), eaten_at, meal_type_key),
    )


def find_prior_meal(description: str, date_hint: str | None = None) -> list[dict]:
    """
    date_hint only understands an exact ISO date (YYYY-MM-DD) today. Free-form
    hints like "Tuesday" or "last week" are ignored rather than guessed at -
    resolving those is a parsing feature to build deliberately, not a silent
    best-effort.
    """
    parsed_date = None
    if date_hint:
        try:
            parsed_date = date.fromisoformat(date_hint)
        except ValueError:
            pass

    base = """
        SELECT m.id AS meal_id, m.name, m.log_date, m.meal_type_key,
               round(similarity(m.name, %s)::numeric, 3) AS name_similarity
        FROM meals m
        WHERE m.user_id = %s
    """
    if parsed_date is not None:
        sql = base + " AND m.log_date = %s ORDER BY name_similarity DESC, m.log_date DESC LIMIT 5"
        params = (description, _user_id(), parsed_date)
    else:
        sql = base + " ORDER BY name_similarity DESC, m.log_date DESC LIMIT 5"
        params = (description, _user_id())
    return db.call_rows(sql, params)


# ----------------------------------------------------------------- commit

def commit_log(
    staging_id: str,
    payload: CommitPayload,
    confirm_duplicate: bool = False,
    confirm_atwater: bool = False,
    confirm_material_defaults: bool = False,
) -> dict:
    result = db.call_scalar(
        "SELECT fn_commit_log(%s, %s, %s, %s, %s, %s)",
        (
            _user_id(),
            staging_id,
            db.as_jsonb(payload.model_dump(mode="json", exclude_none=True)),
            confirm_duplicate,
            confirm_atwater,
            confirm_material_defaults,
        ),
    )
    return result


def supersede_log(old_log_id: int, staging_id: str, payload: CommitPayload) -> dict:
    return db.call_scalar(
        "SELECT fn_supersede_log(%s, %s, %s, %s)",
        (
            _user_id(),
            old_log_id,
            staging_id,
            db.as_jsonb(payload.model_dump(mode="json", exclude_none=True)),
        ),
    )


def rename_meal(meal_id: int, name: str) -> dict:
    return db.call_scalar(
        "SELECT fn_rename_meal(%s, %s, %s)", (_user_id(), meal_id, name)
    )


# ------------------------------------------------------------------ query

def get_meal(meal_id: int) -> dict:
    result = db.call_scalar(
        "SELECT fn_meal_readback(%s, %s)", (_user_id(), meal_id)
    )
    if result is None:
        raise ToolError(f"no meal_id {meal_id} for this user")
    return result


def get_day(log_date_str: str) -> dict:
    meals = db.call_rows(
        """
        SELECT meal_id, name, meal_type_key, started_at, log_count,
               round(kcal,1) AS kcal, round(protein_g,1) AS protein_g,
               round(carbs_g,1) AS carbs_g, round(fat_g,1) AS fat_g,
               round(fiber_g,1) AS fiber_g
        FROM v_meal_macros WHERE user_id = %s AND log_date = %s
        ORDER BY started_at
        """,
        (_user_id(), log_date_str),
    )
    totals = db.call_row(
        """
        SELECT round(kcal,1) AS kcal, round(protein_g,1) AS protein_g,
               round(carbs_g,1) AS carbs_g, round(fat_g,1) AS fat_g,
               round(fiber_g,1) AS fiber_g
        FROM v_daily_totals WHERE user_id = %s AND log_date = %s
        """,
        (_user_id(), log_date_str),
    )
    quality = db.call_row(
        "SELECT * FROM v_daily_data_quality WHERE user_id = %s AND log_date = %s",
        (_user_id(), log_date_str),
    )
    return {
        "log_date": log_date_str,
        "meals": meals,
        "totals": totals,
        "data_quality": quality,
    }


def get_totals(start_date: str, end_date: str) -> dict:
    days = db.call_rows(
        """
        SELECT log_date, round(kcal,1) AS kcal, round(protein_g,1) AS protein_g,
               round(carbs_g,1) AS carbs_g, round(fat_g,1) AS fat_g,
               round(fiber_g,1) AS fiber_g
        FROM v_daily_totals WHERE user_id = %s AND log_date BETWEEN %s AND %s
        ORDER BY log_date
        """,
        (_user_id(), start_date, end_date),
    )
    agg = {
        "kcal": round(sum(d["kcal"] or 0 for d in days), 1),
        "protein_g": round(sum(d["protein_g"] or 0 for d in days), 1),
        "carbs_g": round(sum(d["carbs_g"] or 0 for d in days), 1),
        "fat_g": round(sum(d["fat_g"] or 0 for d in days), 1),
        "fiber_g": round(sum(d["fiber_g"] or 0 for d in days), 1),
    }
    return {"start_date": start_date, "end_date": end_date, "days": days, "total": agg}


def get_trend(food_name_or_key: str, start_date: str | None = None, end_date: str | None = None) -> list[dict]:
    food_key = _slugify(food_name_or_key)
    if start_date and end_date:
        sql = """
            SELECT food_key, example_name, log_date, round(grams,1) AS grams,
                   round(kcal,1) AS kcal, round(protein_g,1) AS protein_g, times
            FROM v_food_trends WHERE user_id = %s AND food_key = %s
              AND log_date BETWEEN %s AND %s ORDER BY log_date
        """
        params = (_user_id(), food_key, start_date, end_date)
    else:
        sql = """
            SELECT food_key, example_name, log_date, round(grams,1) AS grams,
                   round(kcal,1) AS kcal, round(protein_g,1) AS protein_g, times
            FROM v_food_trends WHERE user_id = %s AND food_key = %s ORDER BY log_date
        """
        params = (_user_id(), food_key)
    return db.call_rows(sql, params)


def search_log(query: str) -> list[dict]:
    return db.call_rows(
        """
        SELECT ii.food_name, m.log_date, m.name AS meal_name, m.id AS meal_id,
               round(ii.grams,1) AS grams,
               round(ii.grams * ii.kcal_per_100g / 100.0, 1) AS kcal,
               round(similarity(ii.food_name, %s)::numeric, 3) AS name_similarity
        FROM item_ingredients ii
        JOIN log_items li ON li.id = ii.item_id
        JOIN meal_logs ml ON ml.id = li.log_id AND NOT ml.is_superseded
        JOIN meals m ON m.id = ml.meal_id
        WHERE m.user_id = %s AND ii.food_name %% %s
        ORDER BY name_similarity DESC, m.log_date DESC
        LIMIT 20
        """,
        (query, _user_id(), query),
    )


def get_data_quality(start_date: str, end_date: str | None = None) -> list[dict]:
    return db.call_rows(
        """
        SELECT log_date, meals, logs, ingredients, pct_kcal_user_stated,
               pct_kcal_llm_knowledge, pct_kcal_llm_estimate,
               pct_kcal_estimated_portion, ingredients_missing_fiber,
               avg_log_delay_minutes
        FROM v_daily_data_quality
        WHERE user_id = %s AND log_date BETWEEN %s AND %s
        ORDER BY log_date
        """,
        (_user_id(), start_date, end_date or start_date),
    )
