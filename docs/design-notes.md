# MacroMCP: build brief (v5 / v0 build)

Stack: FastAPI + Postgres 16. Single-user, self-hosted.

`db/schema.sql` loads clean on Postgres 16. `db/tests.sql` exercises 13
invariants and all 13 pass. Run both before writing application code.

```
meals               eating event. name, meal_type, log_date
  meal_logs         one submission. eaten_at + logged_at
    log_items       one named thing. "cheeseburger", fraction 1/2
      item_ingredients   food_name, grams, macros per 100g
```

**Seven tables. No reference database, no food lookup, no bulk ingest, no
barcode path.** Macro densities come from LLM knowledge or from the user, and
are stored denormalized on the ingredient.

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
  keys. Fine for v0; the fix is a canonicalisation pass, not a reference table.
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
kcal" is **arithmetic**. Models are reliable at the first and unreliable at the
second. Per-100g also keeps item fractions scaling correctly: the fraction
multiplies grams, densities are untouched, and the views multiply the two. One
code path, and sending absolute macros would break it immediately.

The model supplies densities and grams; **the server does every multiplication
and every sum.** An LLM adding 40 numbers will be wrong occasionally and
silently.

Honest note: this does weaken the older "model carries no derived value" rule,
since densities now live in context across turns. It doesn't collapse it —
per-100g values are stable constants rather than computed numbers, and the
confirmation block now shows macros, not just grams — but the drift window
within a single draft is real.

---

## The Atwater gate

kcal should approximate **4·protein + 4·carbs + 9·fat**. With no reference
database this is the only automated check on the model's numbers.

Soft gate, matching the duplicate check: it raises with the food name, the
stated kcal, the implied kcal, and the delta. The assistant confirms with the
user and either passes `confirm_atwater` or sets `atwater_override` on the
specific ingredient with a reason.

Tolerance is `greatest(atwater_tol_kcal, atwater_tol_pct % of kcal)`, defaulting
to 35 kcal / 30%. It must be generous: alcohol is 7 kcal/g, sugar alcohols ~2.4,
fiber ~2. `v_atwater_overrides` shows where the model and its own arithmetic
disagreed and the user waved it through. A cluster there means the model is
guessing badly in some category.

**Know the ceiling.** Atwater catches *incoherent* numbers, not *wrong* ones.
Test T5 logs a bagel at 100 kcal/100g with protein 5 / carbs 15 / fat 2. That's
internally consistent, so it commits — and a real bagel is around 270. Nothing in
this system will catch that except you reading the confirmation block. That is
the actual price of dropping the reference database, and the confirmation step is
where it gets paid.

Two hard checks back it up and cannot be overridden:
- `kcal_per_100g` between 0 and 900 (pure fat is 900)
- `protein + carbs + fat <= 100.5` per 100g — 100g of anything cannot contain
  more than 100g of macronutrients (T7)

---

## Missing macros are not storable

All four core densities are `NOT NULL`. This is a correctness guarantee, not
tidiness: `sum()` **skips** NULLs, so a macro-less ingredient wouldn't make the
day total NULL — it would make it **silently low while still looking complete**.
An earlier version had exactly this bug, reporting 205.4 kcal for a day that also
contained an unquantified sauce.

Consequence for the assistant: when the user names something it can't estimate,
it **must** ask for a rough figure and store it as `llm_estimate` or
`user_stated`. "I don't know" has no representation, deliberately.

`fiber_per_100g` stays nullable, since it genuinely gets skipped.

---

## Provenance is the honesty signal

Every number is now either model knowledge or a user assertion, so
`macro_source` is the only thing that tells you which:

- `llm_knowledge` — model recalled a well-known food's density
- `llm_estimate` — model guessed: unusual, restaurant, or composite dish
- `user_stated` — user read a label or gave the numbers

`v_daily_data_quality` reports what share of the day's calories came from each.
Surface it. A day that's 80% `llm_estimate` deserves a different level of trust
than one that's 80% `user_stated`, and only this view can tell you.

`resolution_confidence` remains separate and orthogonal: it describes the
*portion*, not the macros. Exact arithmetic on an eyeballed portion is still
`estimated`.

---

## Unchanged from v4, still enforced and tested

**Composite guard.** Items must be span-anchored; ingredients need not be, since
a cheeseburger's bun isn't in the utterance. Any multi-ingredient item needs an
answered `composite` gap carrying `item_ordinal`. T9 shows it catching sour cream
in a burrito nobody mentioned — this matters *more* now, because there's no
branded-lookup exemption left.

**Attachment is never silent.** `fn_find_attachable_meals()` proposes; the
payload carries `meal.meal_id` only after the user confirms. A single candidate
still gets a confirmation, because attaching to the wrong meal corrupts a meal
that was already correct.

**Naming.** Derived from the first log's items; a later log never regenerates it.
`fn_rename_meal()` is the only mutable field in the whole log.

**Times.** `eaten_at` vs `logged_at` on the log; `log_date` from the first log's
`eaten_at` so a meal can't split across the 4am rollover.
`avg_log_delay_minutes` goes negative when a meal is logged before it's eaten —
clamp or use the median.

**Duplicates.** Two-scoped (`same_meal` / `other_meal`), both soft. Content
identifies a duplicate, the clock does not. Windowed against the existing row's
timestamp, never a rounded bucket. Server mints `staging_id`; UNIQUE on
`meal_logs` is the entire replay guarantee.

**Append-only** below `meals`, enforced by trigger at all three levels.

**Telemetry.** `fn_commit_log` can't log its own rejections — `RAISE EXCEPTION`
rolls back the insert. The API layer catches and calls `fn_log_reject` on a fresh
transaction.

---

## Tool surface

Resolve-side: `new_staging_id()`,
`find_attachable_meals(eaten_at, meal_type_key)`,
`find_prior_meal(description, date_hint)`.

No `search_foods`, no `lookup_barcode`, no `get_portions`. The model supplies all
of that from its own knowledge.

Commit-side: `commit_log(staging_id, payload, confirm_duplicate?, confirm_atwater?)`
→ read-back, `supersede_log(...)`, `rename_meal(meal_id, name)`.

Query-side: `get_day`, `get_meal`, `get_totals`, `get_trend`, `search_log`,
`get_data_quality`.

---

## Parse rules the model must hold

- **Never collapse an ambiguous unit** while clarifying. "A cup" is a measuring
  cup or a drinking vessel, and the model now does the gram conversion itself —
  so it must ask when the two readings differ materially, not silently pick.
- **"8 oz"** is fluid for milk, weight for chicken. Decided by the food.
- **Hedges** — "like 6 or 7 oz" is `quantity_min`/`quantity_max`, not 6.5.
- **Quantity scope** — "two eggs and toast" attaches 2 to eggs; "two eggs and
  sausages" is ambiguous, so detect and don't resolve.
- **Prep state is identity.** Dry vs cooked rice is roughly 3x, and with no
  reference table nothing will catch the confusion. Make it part of `food_name`.
- **Materiality gate** — if two interpretations differ by less than both
  `materiality_kcal` and `materiality_pct`, take the top one, mark it
  `estimated`, and spend no turn.
- **Ask everything in one turn.** Serial questioning is what makes tracking apps
  get abandoned, and it matters more here because reuse is deferred, so every
  meal pays full confirmation cost.
- **Show macros at confirmation, not just grams.** They're now the model's claim
  rather than a database fact, so they're what the user is actually verifying.

---

## Deferred (do not build)

- **Barcode lookup.** Cut from v0 entirely.
- **Redis staging with write-through.** The commit gate won't change when it
  lands, since it already takes the payload as an argument.
- **Prior-resolution reuse.** Would fix cross-session density drift.
- **Batch entity.** Nothing enforces `sum(fractions) <= 1`.
- **Recipe templates. Micronutrients. Multi-user.**
