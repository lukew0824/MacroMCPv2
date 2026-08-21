# MacroMCP

An MCP server that turns an LLM into a nutrition assistant with a real memory.

You talk to it the way you'd talk to a person: *"7oz chicken and a cup of rice."*
It asks what it needs to, confirms, commits, and reads the numbers back. Later
you ask *"how's my protein this week"* and it answers from a database instead of
guessing.

---

## The problem

Nutrition tracking apps fail in one of two ways.

**Manual loggers** (MyFitnessPal and friends) are accurate but exhausting. Search
a database, pick from six near-identical entries, set a serving size, repeat for
every ingredient. The friction is the product's main feature and its main cause
of abandonment.

**LLM chat wrappers** are frictionless and quietly wrong. You say "chicken and
rice," the model invents plausible numbers, and there's no persistence, no
provenance, and nothing to check. Ask it a week later what you ate and it has no
idea.

MacroMCP is the middle: conversational intake with the model doing the
understanding, a database doing the enforcement and the arithmetic, and a
structured confirmation step in between.

---

## The core tension

**Rigor and friction are directly opposed.** Every clarifying question improves
data quality and makes you slightly less likely to log tomorrow. Most of the
design work is buying accuracy without paying for it in turns.

The second organising principle:

**Enforcement belongs in the server, not the system prompt.** A prompt that says
"never guess quantities" holds for a while and then quietly fails on turn 40 of a
long conversation. A commit function that returns a rejection with the specific
list of problems cannot fail. The prompt handles tone and question phrasing;
the database handles what's representable.

---

## How it works

### Intake: parse → classify → resolve → confirm → commit → read back

**Parse** turns an utterance into a structured draft. Its job is transcription
and segmentation, *not inference*. "Chicken and rice" produces two items with
most fields empty, and that is the correct output.

Two invariants, both enforced at commit:
- **Span coverage.** Every item points at a character range of what you said.
  Food-bearing text that produced no item gets reported, so dropped items are
  caught mechanically rather than noticed in a weekly total three months later.
- **No unanchored items.** An item with no span is a hallucination and is
  rejected. This is specifically what stops the model helpfully adding cooking
  oil you never mentioned.

**Classify** tags each gap by *kind*, so the assistant asks something targeted
instead of a generic "how much?". The taxonomy is the interesting part:

| Gap | Example | Why it matters |
|---|---|---|
| Vague vessel | "a bowl", "a cup" | Is that a measuring cup or one from your cupboard? |
| Ambiguous dimension | "8 oz" | Fluid for milk, weight for chicken. Decided by the food. |
| Prep state | "rice" | Dry vs cooked is ~3x. Largest single error source. |
| Cooking fat | "pan-fried" | Routinely omitted, routinely 100–200 kcal |
| Variant | "chicken", "milk" | Breast vs thigh is a 2x fat swing |
| Composite | "a sandwich" | Decompose it, or it's a guess |
| Quantity scope | "two eggs and sausages" | Does the 2 distribute? |

**The materiality gate** is what keeps this from becoming an interrogation. Each
gap carries the calorie spread between its top interpretations. Under threshold,
take the best reading, mark it estimated, and spend no turn. Vessel-vs-measure on
black coffee is noise; on rice it's 200 kcal.

**Resolve** produces grams and macro densities. **Confirm** shows the whole plan
in one block and asks every outstanding question in one turn — serial questioning
is what makes tracking apps get abandoned.

**Commit** is the gate. It rejects unresolved items, unanchored items, dropped
spans, open material gaps, and macros that fail a coherence check.

**Read back** returns the committed entry with grams, per-item macros, meal
totals, and day totals. The assistant reports numbers *the server computed*, so
if the draft drifted during a long conversation, this is where it shows.

### Storage: four levels

```
meals               the eating event.  "chicken and rice", dinner, Aug 19
  meal_logs         one submission.    eaten_at + logged_at
    log_items       one named thing.   "cheeseburger", fraction 1/2
      item_ingredients                 bun 60g, patty 113g, cheese 19g
```

Why each level exists:

- **meals** because an eating event has a name and can be logged more than once.
  "I forgot the sauce" attaches to the meal rather than creating a second dinner.
  This is also the level a meal is *owned* at — see "Multi-user" below.
- **meal_logs** because forgetting something is normal, and because *when you ate*
  and *when you told the system* are different facts worth keeping apart.
- **log_items** because **the portion fraction lives here.** "Half the burger and
  all the fries" isn't representable if the fraction sits on the log. Composites
  also get a name, so read-back says "cheeseburger, 263 kcal" instead of three
  rows you have to reassemble.
- **item_ingredients** because a cheeseburger is a bun, a patty, and cheese. Every
  item has ingredients including simple ones — "a cup of rice" is an item with one
  ingredient — which costs a wrapper row and buys a single rollup path with no
  polymorphism anywhere.

Everything below `meals` is **append-only**. Corrections are new rows that
supersede old ones. `meals.name` is the only mutable field in the entire log.

### Query

**The model never does arithmetic.** Every total, average, and trend is computed
in SQL and returned as structured JSON. An LLM summing 40 numbers will be wrong
occasionally and *silently*, which defeats the entire point of having a database.

Rollups go ingredient → item → log → meal → day, unrounded throughout, rounded
once at display. Components that visibly fail to add up to the total destroy
trust faster than any single wrong entry.

---

## Multi-user

MacroMCP started single-user and is now built for a small group — a
household or a few friends sharing one self-hosted instance, not a public
multi-tenant product.

**Every meal is owned by a user.** `meals.user_id` is the source of truth;
everything below it (`meal_logs`, `log_items`, `item_ingredients`) is scoped
by joining up to it rather than carrying its own copy. Every commit-path
function — `commit_log`, `rename_meal`, `supersede_log`,
`find_attachable_meals` — takes the calling user's id as an explicit
argument and checks ownership before doing anything, the same way
`staging_id` is server-minted rather than trusted from the model.

**What multi-user buys:** two people can share one instance without their
logs, duplicate-detection, or trends colliding. Sam logging the same chicken
and rice Luke logged five minutes earlier isn't a duplicate. Luke's Tuesday
total isn't quietly merged with Sam's.

**What it deliberately doesn't include:** authentication. There's no
password or token in this schema — `user_id` is trusted as given, and
resolving *who's actually calling* (API key, login session, one MCP server
per person) is an API-layer decision, not a database one. There's also no
sharing model: users are fully isolated from each other, not members of a
household that can see each other's logs. If shared visibility turns out to
matter, that's an additive feature on top of this, not a rework of it.

See `docs/design-notes.md` for the full list of what got a cross-user guard
and why, and the tradeoffs behind skipping row-level security for now.

---

## The v0 bet

**No reference database.** No USDA ingest, no Open Food Facts, no barcode path,
no portion tables. Macro densities come from the model's own knowledge or from
you, and are stored on the ingredient.

This is a real bet, so here's both sides.

**For:** modern models know that chicken breast is ~165 kcal/100g and that a cup
of cooked rice is ~158g. Looking that up costs latency, and slow intake means no
intake. It removes an entire ingest pipeline. And history gets **frozen
at log time** — no upstream data source can silently change what your past logs
say.

**Against:** nothing external cross-checks the numbers. The only automated check
left is the **Atwater identity** — kcal should ≈ 4·protein + 4·carbs + 9·fat —
which catches transposed digits and incoherent guesses but *cannot* catch a
self-consistent wrong answer. A bagel entered at 100 kcal/100g with plausible
macros will commit; a real bagel is ~270. The confirmation step is where that
gets caught, which is why the confirmation block shows macros and not just grams.

Two things make the bet survivable:

**Macros are sent per 100g, never absolute.** "Chicken is 165 kcal per 100g" is
*recall*; "213g of chicken is 351 kcal" is *arithmetic*. Models are reliable at
the first and unreliable at the second. Per-100g also means the server still does
every multiplication, so item fractions keep working.

**Provenance is recorded on every ingredient**: `llm_knowledge`, `llm_estimate`,
or `user_stated`. `v_daily_data_quality` reports what share of a day's calories
came from each. A day that's 80% model-guessed deserves different trust than one
that's 80% label-read, and this is the only thing that can tell you which you had.

Note: barcode lookup is on the deferred list below, and it's downstream of
this same bet, not a separate cut — there's no UPC→macro lookup table because
there's no reference database at all. Building one is what un-defers both at
once.

---

## Design decisions worth knowing

**Staging lives in the context window.** No draft tables, no Redis. The
conversation already carries the in-flight state. Redis with write-through is the
planned next step; the commit gate won't change when it lands, because it already
takes the payload as an argument rather than reading a table.

**Duplicates are identified by content, not by the clock.** A `(meal, timestamp)`
key would reject "oh, and a banana" — the most common logging pattern there is.
Instead: hash the resolved ingredients, compare within a window against the
existing row's timestamp, scoped to one user. Two-scoped (same meal / other
meal), both soft, because two identical protein shakes in one day is real.

**Idempotency comes from one unique column.** The server mints a `staging_id`; it
is UNIQUE across all users. Retries, agent-loop re-fires, and concurrent calls all
return the existing entry instead of duplicating.

**Attachment is never silent.** Attaching "I forgot the sauce" to the *wrong*
meal is worse than creating a spurious one, because it corrupts a meal that was
already correct. The server proposes candidates within the caller's own meals;
a single match still requires confirmation.

**Names never regenerate.** Add the sauce you forgot and "chicken and rice" stays
"chicken and rice" rather than becoming "chicken, rice, and sriracha". A name that
shifts under you is worse than one that's slightly incomplete.

**Days roll over at 4am, not midnight.** A 1:30am snack belongs to the day you're
still awake in. `log_date` is materialised at commit and derived from the meal's
first log, so a meal can never split across two days.

**Precision is not accuracy.** Exact rational arithmetic on an eyeballed portion
is still recorded as `estimated`. The system never launders one into the other.

---

## What's deliberately not in v0

- **Barcode lookup**, and the reference food database it depends on. No
  USDA/OFF ingest, no UPC lookup table — this is the same cut as "no reference
  database" above, not two separate omissions.
- **Prior-resolution reuse** ("same as last time?") — the main friction fix, and its
  absence means every meal pays full confirmation cost
- **Batch tracking** (nothing enforces that fractions of one dish sum to ≤ 1)
- **Recipe templates**
- **Micronutrients** — when they return, add a separate long-format table rather than
  migrating back, since macros and micros have different shapes and query patterns
- **Authentication and cross-user sharing** — see "Multi-user" above. `user_id`
  scoping exists; verifying who a `user_id` actually is, and any notion of
  users sharing visibility into each other's logs, does not.

---

## Stack

FastAPI + Postgres 16, small multi-user, self-hosted. Exposed over MCP so any
MCP client can be the front end.

## Files

- `db/schema.sql` — full DDL, multi-user commit gate, rollup views. Loads clean on PG16.
- `db/tests.sql` — 18 invariant tests (13 core, 5 cross-user isolation checks), all passing.
- `docs/design-notes.md` — full design rationale, the multi-user tradeoffs, sharp edges.
- `docs/intake-agent.md` — the system prompt and tool/function-calling contract for the
  conversational front end (GPT Realtime mini), matched field-for-field to `fn_commit_log`'s payload.
- `docs/erd/` — schema diagram (still shows the single-user shape; not yet regenerated for multi-user).
- prior single-user design history: `git log db/schema.sql`.
