# MacroMCP: design notes

Stack: FastAPI + Postgres 16. Small multi-user, self-hosted.

`db/schema.sql` loads clean on Postgres 16. `db/tests.sql` exercises 18
invariants (13 core + 5 multi-user isolation) and all 18 pass. Run both
before writing application code. For the conversational front end's system
prompt and tool contract, see `docs/intake-agent.md` — this document covers
the database design; that one covers what the model must do to use it well.

```
users                who owns the data
  meals               eating event. name, meal_type, log_date
    meal_logs         one submission. eaten_at + logged_at
      log_items       one named thing. "cheeseburger", fraction 1/2
        item_ingredients   food_name, grams, macros per 100g
```

**No reference database, no food lookup, no bulk ingest, no barcode path.**
Macro densities come from LLM knowledge or from the user, and are stored
denormalized on the ingredient.

---

## What this trade actually buys and costs

**Buys:** no FDC/OFF ingest pipeline, no lookup latency (slow intake means no
intake), and history **frozen at log time** — no upstream data source can
silently change what your past logs say.

**Costs:**
- Nothing external cross-checks the numbers. The Atwater identity is the only
  automated check left, and it has a hard ceiling (below).
- Trend grouping is approximate. `food_key` is a slug generated from
  `food_name`, so "chicken breast" and "grilled chicken breast" are different
  keys. Fine for now; the fix is a canonicalisation pass, not a reference table.
- Cross-session consistency isn't guaranteed. The same food estimated on Monday
  and Thursday can differ, which puts noise into weekly trends that isn't real
  variation. Prior-resolution reuse would fix it and is deferred.

---

## Two rules that shape everything

**1. Enforcement lives in the database, not in the system prompt.** A prompt that
says "never guess quantities" holds for a while and then quietly fails on turn
40. `fn_commit_log()` cannot.

**2. Macros are sent PER 100g, never absolute.**

"Chicken breast is 165 kcal per 100g" is **recall**. "213g of chicken is 351
kcal" is **arithmetic**. Models are reliable at the first and unreliable at
the second. Per-100g also keeps item fractions scaling correctly: the fraction
multiplies grams, densities are untouched, and the views multiply the two. One
code path, and sending absolute macros would break it immediately.

The model supplies densities and grams; **the server does every multiplication
and every sum.** An LLM adding 40 numbers will be wrong occasionally and
silently.

---

## The Atwater gate

kcal should approximate **4·protein + 4·carbs + 9·fat**. With no reference
database this is the only automated check on the model's numbers.

Soft gate: it raises with the food name, the stated kcal, the implied kcal,
and the delta. The assistant confirms with the user and either passes
`confirm_atwater` or sets `atwater_override` on the specific ingredient with
a reason.

Tolerance is `greatest(atwater_tol_kcal, atwater_tol_pct % of kcal)`, read
from the calling user's own `user_settings` row, defaulting to 35 kcal / 30%.
It must be generous: alcohol is 7 kcal/g, sugar alcohols ~2.4, fiber ~2.
`v_atwater_overrides` shows where the model and its own arithmetic disagreed
and the user waved it through, per user. A cluster there means that user's
model calls are guessing badly in some category.

**Know the ceiling.** Atwater catches *incoherent* numbers, not *wrong* ones.
Logging a bagel at 100 kcal/100g with protein 5 / carbs 15 / fat 2 is internally
consistent, so it commits — and a real bagel is around 270. Nothing in this
system will catch that except a human reading the confirmation. That is the
actual price of dropping the reference database, and the confirmation step is
where it gets paid.

Two hard checks back it up and cannot be overridden:
- `kcal_per_100g` between 0 and 900 (pure fat is 900)
- `protein + carbs + fat <= 100.5` per 100g — 100g of anything cannot contain
  more than 100g of macronutrients

---

## Missing macros are not storable

All four core densities are `NOT NULL`. This is a correctness guarantee, not
tidiness: `sum()` **skips** NULLs, so a macro-less ingredient wouldn't make the
day total NULL — it would make it **silently low while still looking complete**.
An earlier version had exactly this bug, reporting 205.4 kcal for a day that also
contained an unquantified sauce.

Consequence for the assistant: when the user names something it can't estimate,
it **must** ask for a rough figure and store it as `llm_estimate` or
`user_stated`. "I don't know" has no representation, deliberately. This
extends to *partial* macro statements too — a user giving "300 calories and
12g protein" for something is two of the four required fields, not a
complete answer; `docs/intake-agent.md` covers how the agent is expected to
notice and close that gap before it ever reaches `fn_commit_log`.

`fiber_per_100g` stays nullable, since it genuinely gets skipped.

---

## Provenance is the honesty signal

Every number is now either model knowledge or a user assertion, so
`macro_source` is the only thing that tells you which:

- `llm_knowledge` — model recalled a well-known food's density
- `llm_estimate` — model guessed: unusual, restaurant, or composite dish
- `user_stated` — user read a label or gave the numbers

`v_daily_data_quality` reports what share of a user's day's calories came
from each. Surface it. A day that's 80% `llm_estimate` deserves a different
level of trust than one that's 80% `user_stated`, and only this view can
tell you.

`resolution_confidence` remains separate and orthogonal: it describes the
*portion*, not the macros. Exact arithmetic on an eyeballed portion is still
`estimated`.

---

## Multi-user

Every meal is owned by a user. `meals.user_id` is the source of truth;
`meal_logs`, `log_items`, and `item_ingredients` don't carry their own copy —
they're scoped by joining up to `meals.user_id`. This is a normalization
choice, not a shortcut: `user_id` doesn't have the `sum()`-skips-NULL hazard
that made this schema denormalize macros and `log_date` in the first place,
so a join is the right level of engineering here. Every commit-path and
resolve-path function takes `p_user_id` as an explicit first argument and
checks ownership before doing anything with it.

**Authentication is explicitly not in this schema.** `p_user_id` is trusted
as given by every function here. Nothing in `db/schema.sql` verifies who is
calling — that's the API/MCP layer's job. Resolve `user_id` from real
authenticated context before calling any `fn_*` function, and never from a
field inside the model-produced JSON payload — the model has no business
asserting whose log it is, the same way `staging_id` is server-minted rather
than model-supplied.

**No row-level security, on purpose (for now).** Every `fn_*` function
filters explicitly on `user_id` — that's the enforcement layer, consistent
with "enforcement lives in the database" applied to the *code path*, not to
a Postgres RLS policy. The sharp edge: an ad-hoc `SELECT * FROM
v_daily_totals` with no `WHERE user_id = ...` returns everyone's data, and
nothing in the schema stops that. Fine as long as the function surface is
the only thing touching these tables; add RLS the moment a second surface
(an admin dashboard, a raw reporting script) queries the views directly.

**What got a cross-user guard, and why:**
- **Attaching to an existing meal** (`fn_commit_log`, non-null `meal.meal_id`)
  — without this, a real `meal_id` belonging to another user could be used to
  silently write into their log.
- **Renaming a meal** (`fn_rename_meal`) and **superseding a log**
  (`fn_supersede_log`) — the latter checks the *old* log belongs to the
  caller before superseding, since a correction is more dangerous than a
  fresh commit: it marks an existing row dead.
- **Reading a meal back** (`fn_meal_readback`) — returns `NULL` on a
  cross-user lookup rather than raising, so a meal that doesn't exist and a
  meal that isn't yours look identical from the outside.
- **Replaying a `staging_id`** that belongs to a different user raises
  loudly rather than silently returning something — this shouldn't be
  reachable in normal operation since `staging_id` is server-minted per call,
  but if it happens it's a bug worth surfacing, not a wrong-user replay
  worth being quiet about.

**Duplicate detection and attachment candidates are scoped, not guarded** —
`fn_find_duplicate_log` and `fn_find_attachable_meals` both take `p_user_id`
and join through it, so two users logging the same food on the same day
never trip each other's dedup or attachment logic. There's no "wrong user"
case to reject here; the query just never sees the other user's rows.

**`meal_types` stays global/shared, on purpose.** Breakfast/lunch/dinner/snack
are categories, not user data — no per-user customization.

Attaching a new log to an *old* meal is not time-windowed at the database
level — `fn_commit_log`'s attach path only checks ownership, not recency. This
is what makes "oh wait, I forgot the sauce" work whether it's said thirty
seconds or five days after the original log; see `docs/intake-agent.md`'s
"Corrections and forgotten details" for how the agent is expected to locate
the right meal and confirm before attaching to something that old.

---

## Still enforced and tested

**Composite guard.** Items must be span-anchored; ingredients need not be, since
a cheeseburger's bun isn't in the utterance. Any multi-ingredient item needs an
answered `composite` gap carrying `item_ordinal`. This matters more without a
reference database, since there's no branded-lookup exemption to fall back on.

**Attachment is never silent.** `fn_find_attachable_meals()` proposes; the
payload carries `meal.meal_id` only after the user confirms — and now that
`meal_id` is also checked against `p_user_id` before anything is written. A
single candidate still gets a confirmation, because attaching to the wrong
meal corrupts a meal that was already correct.

**Naming.** Derived from the first log's items; a later log never regenerates it.
`fn_rename_meal()` is the only mutable field in the whole log, and only the
owning user can call it.

**Times.** `eaten_at` vs `logged_at` on the log; `log_date` from the first log's
`eaten_at` so a meal can't split across the 4am rollover.
`avg_log_delay_minutes` goes negative when a meal is logged before it's eaten —
clamp or use the median.

**Duplicates.** Two-scoped (`same_meal` / `other_meal`), both soft, and scoped
to one user — content identifies a duplicate, the clock does not, and another
user's identical meal is never a duplicate of yours. Windowed against the
existing row's timestamp, never a rounded bucket. Server mints `staging_id`;
UNIQUE on `meal_logs` (global, across all users) is the entire replay
guarantee.

**Append-only** below `meals`, enforced by trigger at all three levels.

**Telemetry.** `fn_commit_log` can't log its own rejections — `RAISE EXCEPTION`
rolls back the insert. The API layer catches and calls `fn_log_reject` on a fresh
transaction, with the same `p_user_id` the original call used.

---

## Tool surface

Every function below takes `p_user_id` as an explicit first argument, sourced
from the caller's authenticated identity, never from the payload.

Resolve-side: `new_staging_id()`,
`find_attachable_meals(user_id, eaten_at, meal_type_key)`,
`find_prior_meal(user_id, description, date_hint)`.

No `search_foods`, no `lookup_barcode`, no `get_portions`. The model supplies all
of that from its own knowledge.

Commit-side: `commit_log(user_id, staging_id, payload, confirm_duplicate?, confirm_atwater?)`
→ read-back, `supersede_log(user_id, old_log_id, staging_id, payload)`,
`rename_meal(user_id, meal_id, name)`.

Query-side: `get_day`, `get_meal`, `get_totals`, `get_trend`, `search_log`,
`get_data_quality` — these aren't stored SQL functions, they're plain
`user_id`-filtered `SELECT`s over the views at the API layer. This is the
easiest thing to get wrong building that layer: omitting the `user_id` filter
fails silently (a merged total, not an error) rather than loudly. See the
"no row-level security" note above.

See `docs/intake-agent.md` for the full tool/function-calling JSON schemas
matched to this contract, and the system prompt covering how the model is
expected to use it — parsing, the gap taxonomy, the materiality gate, and
what to do with each kind of `fn_commit_log` rejection.

---

## Deferred (do not build without the user asking)

- **Barcode lookup, and the reference food database it depends on.** These
  are the same cut, not two separate omissions — there's no UPC→macro lookup
  table because there's no reference database at all.
- **Redis staging with write-through.** The commit gate won't change when it
  lands, since it already takes the payload as an argument.
- **Prior-resolution reuse.** Would fix cross-session density drift.
- **Batch entity.** Nothing enforces `sum(fractions) <= 1`.
- **Recipe templates. Micronutrients.**
- **Authentication and cross-user sharing.** `user_id` scoping exists;
  verifying who a `user_id` actually is, and any notion of users sharing
  visibility into each other's logs, does not.
