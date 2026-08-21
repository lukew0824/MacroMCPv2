"""
Pydantic models for fn_commit_log's payload contract (db/schema.sql,
docs/intake-agent.md). These exist for two reasons: MCP derives each tool's
JSON schema from these types, and validating here gives a fast, structured
error before a round trip to Postgres for the common mistakes (wrong enum
value, missing required macro, malformed span).

This is NOT a replacement for the database's own checks - fn_commit_log
still re-validates everything it cares about (composite guard, Atwater
identity, missing macros, physical bounds) and is the actual source of
truth. Treat validation failures here and rejections from the database as
the same kind of event to the caller: a specific, fixable reason the
payload didn't commit.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field, model_validator

MacroSource = Literal["llm_knowledge", "llm_estimate", "user_stated"]
ResolutionConfidence = Literal["exact", "user_confirmed", "estimated"]
UnitClass = Literal[
    "mass", "standard_volume", "vessel", "countable",
    "fraction_of_whole", "gestural", "branded_serving",
]
GapKind = Literal[
    "missing_quantity", "vessel_unit", "ambiguous_unit_dimension",
    "volumetric_on_solid", "prep_state", "cooking_fat", "variant", "brand",
    "composite", "quantity_scope", "reference_ambiguous", "portion_unclear",
    "attachment_ambiguous", "macro_uncertain",
]
NameSource = Literal["derived", "user"]
# Matches the meal_types seed rows in db/schema.sql. If that table ever
# grows custom rows, this literal needs to grow with it.
MealTypeKey = Literal[
    "breakfast", "lunch", "dinner", "snack", "pre_workout", "post_workout"
]
GapStatus = Literal["open", "answered", "defaulted"]


class Quantity(BaseModel):
    num: int
    den: int


class PortionFraction(BaseModel):
    num: int = Field(gt=0)
    den: int = Field(gt=0)


class MealRef(BaseModel):
    meal_id: int | None = Field(
        default=None,
        description="Non-null attaches to an existing meal. This IS the user's confirmation to attach.",
    )
    name: str | None = None
    name_source: NameSource | None = None
    meal_type_key: MealTypeKey
    meal_type_inferred: bool | None = None


class Gap(BaseModel):
    kind: GapKind
    item_ordinal: int | None = None
    status: GapStatus
    is_material: bool


class Ingredient(BaseModel):
    ordinal: int
    food_name: str = Field(min_length=1, description="Include prep state, e.g. 'chicken breast, cooked'.")
    grams: float = Field(gt=0, description="After converting the user's unit, before the item's portion_fraction is applied - the server applies the fraction.")
    kcal_per_100g: float = Field(ge=0, le=900)
    protein_per_100g: float = Field(ge=0, le=100)
    carbs_per_100g: float = Field(ge=0, le=100)
    fat_per_100g: float = Field(ge=0, le=100)
    fiber_per_100g: float | None = Field(default=None, ge=0)
    atwater_override: str | None = Field(
        default=None,
        description="Only set for a food that legitimately breaks 4P+4C+9F (alcohol, sugar alcohols) - explain why.",
    )
    macro_source: MacroSource
    resolution_confidence: ResolutionConfidence
    quantity: Quantity | None = None
    unit_label: str | None = None
    unit_class: UnitClass | None = None
    quantity_min: float | None = None
    quantity_max: float | None = None
    raw_text: str | None = Field(default=None, description="Omit if this ingredient is a decomposition the user didn't say directly.")
    span: tuple[int, int] | None = None

    @model_validator(mode="after")
    def _check_macro_sum(self) -> "Ingredient":
        total = self.protein_per_100g + self.carbs_per_100g + self.fat_per_100g
        if total > 100.5:
            raise ValueError(
                f"protein + carbs + fat = {total:.1f}g per 100g for "
                f"{self.food_name!r} - 100g of anything cannot contain more "
                f"than 100g of macronutrients"
            )
        return self

    @model_validator(mode="after")
    def _check_quantity_range(self) -> "Ingredient":
        if self.quantity_min is not None and self.quantity_max is not None:
            if self.quantity_min > self.quantity_max:
                raise ValueError("quantity_min must be <= quantity_max")
        return self


class Item(BaseModel):
    ordinal: int
    name: str = Field(min_length=1)
    raw_text: str = Field(min_length=1, description="The exact substring of raw_utterance this item came from.")
    span: tuple[int, int]
    portion_fraction: PortionFraction | None = None
    ingredients: list[Ingredient] = Field(min_length=1)


class CommitPayload(BaseModel):
    raw_utterance: str
    eaten_at: str = Field(description="ISO 8601 timestamp with offset.")
    note: str | None = None
    meal: MealRef
    unconsumed_spans: list[tuple[int, int]] = Field(default_factory=list)
    gaps: list[Gap] = Field(default_factory=list)
    items: list[Item] = Field(min_length=1)
