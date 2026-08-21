-- =============================================================================
-- MacroMCP - schema v5 (v0 build)
-- PostgreSQL 15+
--
-- CHANGE FROM v4: THE REFERENCE DATABASE IS GONE.
--   No foods table. No food_portions. No barcode path. No FDC/OFF ingest.
--   Macro densities come from LLM knowledge or from the user, and are stored
--   denormalized on the ingredient. Nine tables became seven, and the entire
--   bulk-ingest pipeline disappears.
--
-- Consequences, good and bad:
--   + History is FROZEN at log time. No upstream data source can silently
--     change what your past logs say.
--   + No lookup latency, so intake is fast, and slow intake means no intake.
--   - Trend grouping is approximate: food_key is a slug derived from the name,
--     so "chicken breast" and "grilled chicken breast" are different keys.
--   - Nothing external cross-checks the numbers. The Atwater identity is the
--     only automated check that remains. See fn_commit_log.
--
-- Load-bearing decisions:
--
--  1. MACROS ARE SENT PER 100g, NEVER ABSOLUTE. "Chicken breast is 165 kcal per
--     100g" is RECALL; "213g of chicken is 351 kcal" is ARITHMETIC. Models are
--     reliable at the first and unreliable at the second. Per-100g also keeps
--     item fractions scaling correctly: the server multiplies, always.
--
--  2. The model supplies densities and grams; the SERVER does every
--     multiplication and every sum. An LLM adding 40 numbers will be wrong
--     occasionally and SILENTLY.
--
--  3. Enforcement lives HERE, not in the system prompt.
--
--  4. meal_logs / log_items / item_ingredients are APPEND-ONLY.
--     meals is mutable in exactly one place: the name.
--
--  5. ITEMS MUST BE SPAN-ANCHORED. INGREDIENTS NEED NOT BE - a cheeseburger's
--     bun is a decomposition, not something the user said. That hole is closed
--     by requiring an answered 'composite' gap for multi-ingredient items.
--
--  6. ATTACHMENT IS NEVER SILENT. Attaching "I forgot the sauce" to the wrong
--     meal corrupts a meal that was already correct.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================ SECTION 1: ENUMS ===============================

-- Where the macro numbers came from. This is now the ONLY provenance signal,
-- since there is no reference database to point at.
CREATE TYPE macro_source AS ENUM (
    'llm_knowledge',  -- model recalled a well-known food's density
    'llm_estimate',   -- model guessed: unusual, restaurant, or composite dish
    'user_stated');   -- user read a label or gave the numbers directly

-- Kept for audit of what the USER said, even though the model now does the
-- conversion. The same token means different things by food and context.
CREATE TYPE unit_class AS ENUM (
    'mass','standard_volume','vessel','countable',
    'fraction_of_whole','gestural','branded_serving');

-- Distinct from source ON PURPOSE: exact arithmetic on an eyeballed portion is
-- still an estimate. Precision must not get laundered into accuracy.
CREATE TYPE resolution_confidence AS ENUM ('exact','user_confirmed','estimated');

CREATE TYPE gap_kind AS ENUM (
    'missing_quantity','vessel_unit','ambiguous_unit_dimension',
    'volumetric_on_solid','prep_state','cooking_fat','variant','brand',
    'composite','quantity_scope','reference_ambiguous','portion_unclear',
    'attachment_ambiguous','macro_uncertain');

CREATE TYPE name_source AS ENUM ('derived','user');
CREATE TYPE intake_outcome AS ENUM ('committed','superseded','rejected');


-- ============================ SECTION 2: CONFIG ==============================

CREATE TABLE user_settings (
    id                smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    timezone          text     NOT NULL DEFAULT 'America/New_York',
    -- A 1:30am snack belongs to the day you are still awake in.
    day_rollover_hour smallint NOT NULL DEFAULT 4 CHECK (day_rollover_hour BETWEEN 0 AND 11),
    -- MATERIALITY GATE. Under BOTH thresholds, do not spend a turn asking.
    materiality_kcal  numeric(8,2) NOT NULL DEFAULT 25.0,
    materiality_pct   numeric(5,2) NOT NULL DEFAULT 10.0,
    -- ATWATER TOLERANCE. kcal should approximate 4P + 4C + 9F. Tolerance must
    -- be generous: fiber contributes ~2, sugar alcohols ~2.4, alcohol 7.
    atwater_tol_kcal  numeric(6,2) NOT NULL DEFAULT 35.0,
    atwater_tol_pct   numeric(5,2) NOT NULL DEFAULT 30.0,
    updated_at        timestamptz NOT NULL DEFAULT now()
);
INSERT INTO user_settings (id) VALUES (1);

CREATE TABLE meal_types (
    key                text PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_]*$'),
    display_name       text NOT NULL,
    -- Explicit: alphabetical sort puts dinner before lunch. When rendering a
    -- day, sort by MIN(eaten_at) and use ordinal only as a tiebreak.
    ordinal            int  NOT NULL UNIQUE,
    is_builtin         boolean NOT NULL DEFAULT false,
    -- Doubles as the ATTACHMENT window. Snacks collapse into one group per day,
    -- so they need a tighter window than a long dinner.
    dup_window_minutes int NOT NULL DEFAULT 90 CHECK (dup_window_minutes > 0),
    infer_from_local   time,
    infer_to_local     time,
    CHECK ((infer_from_local IS NULL) = (infer_to_local IS NULL))
);

INSERT INTO meal_types
  (key, display_name, ordinal, is_builtin, dup_window_minutes, infer_from_local, infer_to_local)
VALUES
  ('breakfast','Breakfast',100,true,120,'04:00','10:30'),
  ('lunch','Lunch',200,true,120,'10:30','15:00'),
  ('dinner','Dinner',300,true,150,'17:00','22:00'),
  ('snack','Snack',400,true,45,NULL,NULL),
  ('pre_workout','Pre-workout',500,true,45,NULL,NULL),
  ('post_workout','Post-workout',600,true,45,NULL,NULL);


-- ====================== SECTION 3: THE LOG (4 levels) ========================
--   meals              the eating event.  "chicken and rice", dinner
--     meal_logs        one submission.    eaten_at + logged_at
--       log_items      one named thing.   "cheeseburger", fraction 1/2
--         item_ingredients                bun 60g, patty 113g, cheese 19g

CREATE TABLE meals (
    id                   bigserial PRIMARY KEY,
    -- Derived from the FIRST log's items, or user-supplied. A later log does
    -- NOT regenerate a derived name: add the sauce you forgot and "chicken and
    -- rice" stays "chicken and rice". A name that shifts under you is worse
    -- than one that is slightly incomplete.
    name                 text        NOT NULL,
    name_source          name_source NOT NULL DEFAULT 'derived',
    meal_type_key        text        NOT NULL REFERENCES meal_types(key),
    meal_type_inferred   boolean     NOT NULL DEFAULT false,
    -- From the FIRST log's eaten_at; later logs inherit it. Guarantees a meal
    -- never splits across two days when it straddles the 4am rollover.
    log_date             date        NOT NULL,
    tz                   text        NOT NULL,
    derived_from_meal_id bigint REFERENCES meals(id),
    created_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX meals_day_type ON meals (log_date, meal_type_key);

CREATE OR REPLACE FUNCTION trg_meals_name_only() RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'meals cannot be deleted (id=%)', OLD.id;
    END IF;
    IF  NEW.meal_type_key IS DISTINCT FROM OLD.meal_type_key
     OR NEW.log_date      IS DISTINCT FROM OLD.log_date
     OR NEW.tz            IS DISTINCT FROM OLD.tz THEN
        RAISE EXCEPTION 'only meals.name / name_source may change (id=%)', OLD.id;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER meals_name_only BEFORE UPDATE OR DELETE ON meals
    FOR EACH ROW EXECUTE FUNCTION trg_meals_name_only();


CREATE TABLE meal_logs (
    id                bigserial PRIMARY KEY,
    meal_id           bigint      NOT NULL REFERENCES meals(id),
    eaten_at          timestamptz NOT NULL,   -- what this log asserts
    logged_at         timestamptz NOT NULL DEFAULT now(),  -- when it was written
    content_hash      bytea NOT NULL,
    -- IDEMPOTENCY. Server-minted, UNIQUE. The entire replay guarantee.
    staging_id        uuid  NOT NULL UNIQUE,
    supersedes_log_id bigint REFERENCES meal_logs(id),
    is_superseded     boolean NOT NULL DEFAULT false,
    raw_utterance     text,
    note              text
);
CREATE UNIQUE INDEX meal_logs_supersedes_uniq ON meal_logs (supersedes_log_id)
    WHERE supersedes_log_id IS NOT NULL;
CREATE INDEX meal_logs_meal     ON meal_logs (meal_id) WHERE NOT is_superseded;
CREATE INDEX meal_logs_dupcheck ON meal_logs (content_hash, eaten_at)
    WHERE NOT is_superseded;


CREATE TABLE log_items (
    id                   bigserial PRIMARY KEY,
    log_id               bigint NOT NULL REFERENCES meal_logs(id) ON DELETE CASCADE,
    ordinal              int    NOT NULL,
    name                 text   NOT NULL,   -- "cheeseburger", "side salad"
    -- THE FRACTION LIVES HERE, not on the log. "Half the burger and all the
    -- fries" is not representable otherwise. Exact integers: thirds must close.
    portion_fraction_num int CHECK (portion_fraction_num > 0),
    portion_fraction_den int CHECK (portion_fraction_den > 0),
    CHECK ((portion_fraction_num IS NULL) = (portion_fraction_den IS NULL)),
    -- ANCHOR, REQUIRED. An item with no span is a hallucination.
    raw_text             text NOT NULL CHECK (raw_text <> ''),
    span_start           int  NOT NULL,
    span_end             int  NOT NULL CHECK (span_end > span_start),
    UNIQUE (log_id, ordinal)
);
CREATE INDEX log_items_log ON log_items (log_id);


CREATE TABLE item_ingredients (
    id                    bigserial PRIMARY KEY,
    item_id               bigint NOT NULL REFERENCES log_items(id) ON DELETE CASCADE,
    ordinal               int    NOT NULL,

    -- Identity is now just a name. There is no foods table to point at.
    food_name             text   NOT NULL CHECK (food_name <> ''),
    -- Slug for trend grouping. GENERATED so it is predictable rather than a
    -- per-call model decision. Grouping is therefore APPROXIMATE: "chicken
    -- breast" and "grilled chicken breast" are different keys. Accepted for v0.
    food_key              text GENERATED ALWAYS AS (
                              trim(both '_' from
                                lower(regexp_replace(food_name,'[^a-zA-Z0-9]+','_','g')))
                          ) STORED,

    grams                 numeric(10,3) NOT NULL CHECK (grams > 0),  -- AFTER item fraction
    grams_before_fraction numeric(10,3) NOT NULL CHECK (grams_before_fraction > 0),

    -- MACRO DENSITIES, per 100g, NOT NULL. Never absolute: absolute values would
    -- break item-fraction scaling and would be arithmetic rather than recall.
    -- NOT NULL because sum() SKIPS nulls, so one macro-less ingredient does not
    -- make a total null - it makes the total SILENTLY LOW while still looking
    -- complete.
    kcal_per_100g         numeric(9,3) NOT NULL CHECK (kcal_per_100g BETWEEN 0 AND 900),
    protein_per_100g      numeric(9,3) NOT NULL CHECK (protein_per_100g BETWEEN 0 AND 100),
    carbs_per_100g        numeric(9,3) NOT NULL CHECK (carbs_per_100g   BETWEEN 0 AND 100),
    fat_per_100g          numeric(9,3) NOT NULL CHECK (fat_per_100g     BETWEEN 0 AND 100),
    fiber_per_100g        numeric(9,3) CHECK (fiber_per_100g >= 0),
    -- Hard physical bound: 100g of anything cannot contain more than 100g of
    -- macronutrients. Cheap, and it catches a whole class of garbage.
    CHECK (protein_per_100g + carbs_per_100g + fat_per_100g <= 100.5),

    -- Set when the user overrode a failed Atwater check (alcohol, sugar
    -- alcohols, or a label that simply disagrees with the identity).
    atwater_override      text,

    macro_source          macro_source          NOT NULL,
    resolution_confidence resolution_confidence NOT NULL,

    -- What the USER said, kept for audit even though the model did the
    -- conversion to grams. "like 6 or 7 oz" is an interval, NOT 6.5.
    quantity_num          int,
    quantity_den          int,
    unit_label            text,
    unit_class_used       unit_class,
    quantity_min          numeric(10,3),
    quantity_max          numeric(10,3),
    CHECK (quantity_min IS NULL OR quantity_max IS NULL OR quantity_min <= quantity_max),

    -- NULLABLE, unlike log_items.raw_text: a cheeseburger's bun is a
    -- decomposition, not something the user said.
    raw_text              text,
    span_start            int,
    span_end              int,

    UNIQUE (item_id, ordinal)
);
CREATE INDEX item_ingredients_item ON item_ingredients (item_id);
CREATE INDEX item_ingredients_key  ON item_ingredients (food_key);
CREATE INDEX item_ingredients_name_trgm ON item_ingredients USING gin (food_name gin_trgm_ops);


CREATE OR REPLACE FUNCTION trg_append_only() RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION '% is append-only: supersede instead of deleting', TG_TABLE_NAME;
    END IF;
    IF TG_TABLE_NAME = 'meal_logs' THEN
        IF  NEW.meal_id      IS DISTINCT FROM OLD.meal_id
         OR NEW.eaten_at     IS DISTINCT FROM OLD.eaten_at
         OR NEW.content_hash IS DISTINCT FROM OLD.content_hash
         OR NEW.staging_id   IS DISTINCT FROM OLD.staging_id THEN
            RAISE EXCEPTION 'meal_logs is append-only: only is_superseded / supersedes_log_id may change (id=%)', OLD.id;
        END IF;
        RETURN NEW;
    END IF;
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER meal_logs_append_only BEFORE UPDATE OR DELETE ON meal_logs
    FOR EACH ROW EXECUTE FUNCTION trg_append_only();
CREATE TRIGGER log_items_append_only BEFORE UPDATE OR DELETE ON log_items
    FOR EACH ROW EXECUTE FUNCTION trg_append_only();
CREATE TRIGGER item_ingredients_append_only BEFORE UPDATE OR DELETE ON item_ingredients
    FOR EACH ROW EXECUTE FUNCTION trg_append_only();


-- ======================== SECTION 4: QUERY VIEWS =============================
-- The server does ALL arithmetic. Rollup: ingredient -> item -> log -> meal ->
-- day, UNROUNDED throughout. Round once, at display: components that visibly
-- fail to add up to the total destroy trust faster than any single wrong entry.

CREATE VIEW v_ingredient_macros AS
SELECT ii.id AS ingredient_id, ii.item_id, li.log_id, ml.meal_id,
       m.log_date, m.meal_type_key, ml.eaten_at,
       ii.food_name, ii.food_key, ii.grams,
       ii.macro_source, ii.resolution_confidence,
       ii.grams * ii.kcal_per_100g    / 100.0 AS kcal,
       ii.grams * ii.protein_per_100g / 100.0 AS protein_g,
       ii.grams * ii.carbs_per_100g   / 100.0 AS carbs_g,
       ii.grams * ii.fat_per_100g     / 100.0 AS fat_g,
       ii.grams * ii.fiber_per_100g   / 100.0 AS fiber_g
FROM item_ingredients ii
JOIN log_items li ON li.id = ii.item_id
JOIN meal_logs ml ON ml.id = li.log_id AND NOT ml.is_superseded
JOIN meals     m  ON m.id  = ml.meal_id;

CREATE VIEW v_item_macros AS
SELECT item_id, log_id, meal_id, log_date, sum(grams) AS grams,
       sum(kcal) AS kcal, sum(protein_g) AS protein_g,
       sum(carbs_g) AS carbs_g, sum(fat_g) AS fat_g, sum(fiber_g) AS fiber_g
FROM v_ingredient_macros GROUP BY 1,2,3,4;

CREATE VIEW v_log_macros AS
SELECT log_id, meal_id, log_date, sum(kcal) AS kcal, sum(protein_g) AS protein_g,
       sum(carbs_g) AS carbs_g, sum(fat_g) AS fat_g
FROM v_ingredient_macros GROUP BY 1,2,3;

CREATE VIEW v_meal_macros AS
SELECT m.id AS meal_id, m.name, m.meal_type_key, m.log_date,
       min(vim.eaten_at) AS started_at,      -- no need to store it
       count(DISTINCT vim.log_id) AS log_count,
       sum(vim.kcal) AS kcal, sum(vim.protein_g) AS protein_g,
       sum(vim.carbs_g) AS carbs_g, sum(vim.fat_g) AS fat_g, sum(vim.fiber_g) AS fiber_g
FROM meals m LEFT JOIN v_ingredient_macros vim ON vim.meal_id = m.id
GROUP BY m.id, m.name, m.meal_type_key, m.log_date;

CREATE VIEW v_daily_totals AS
SELECT log_date, sum(kcal) AS kcal, sum(protein_g) AS protein_g,
       sum(carbs_g) AS carbs_g, sum(fat_g) AS fat_g, sum(fiber_g) AS fiber_g
FROM v_ingredient_macros GROUP BY 1;

-- THE HONESTY VIEW, and it matters more now than it ever did. With no reference
-- database, EVERY number is either model knowledge or a user assertion. This is
-- the only thing that tells you which.
CREATE VIEW v_daily_data_quality AS
SELECT vim.log_date,
       count(DISTINCT vim.meal_id) AS meals,
       count(DISTINCT vim.log_id)  AS logs,
       count(*) AS ingredients,
       round(100.0*sum(vim.kcal) FILTER (WHERE vim.macro_source='user_stated')
             /nullif(sum(vim.kcal),0),1) AS pct_kcal_user_stated,
       round(100.0*sum(vim.kcal) FILTER (WHERE vim.macro_source='llm_knowledge')
             /nullif(sum(vim.kcal),0),1) AS pct_kcal_llm_knowledge,
       round(100.0*sum(vim.kcal) FILTER (WHERE vim.macro_source='llm_estimate')
             /nullif(sum(vim.kcal),0),1) AS pct_kcal_llm_estimate,
       round(100.0*sum(vim.kcal) FILTER (WHERE vim.resolution_confidence='estimated')
             /nullif(sum(vim.kcal),0),1) AS pct_kcal_estimated_portion,
       count(*) FILTER (WHERE vim.fiber_g IS NULL) AS ingredients_missing_fiber,
       -- Negative when a meal is logged before it is eaten. Report the median
       -- or clamp at zero if pre-logging is common.
       round(avg(extract(epoch FROM (ml.logged_at - ml.eaten_at))/60.0)::numeric,1)
             AS avg_log_delay_minutes
FROM v_ingredient_macros vim JOIN meal_logs ml ON ml.id = vim.log_id
GROUP BY vim.log_date;

-- Approximate trend grouping, the cost of dropping the reference database.
CREATE VIEW v_food_trends AS
SELECT food_key, min(food_name) AS example_name, log_date,
       count(*) AS times, sum(grams) AS grams, sum(kcal) AS kcal,
       sum(protein_g) AS protein_g
FROM v_ingredient_macros GROUP BY food_key, log_date;

-- Where the model and its own arithmetic disagreed and the user waved it
-- through. Worth reviewing: a cluster here means the model is guessing badly.
CREATE VIEW v_atwater_overrides AS
SELECT ii.id, m.log_date, ii.food_name, ii.kcal_per_100g,
       round(4*ii.protein_per_100g + 4*ii.carbs_per_100g + 9*ii.fat_per_100g, 1) AS atwater_kcal,
       ii.atwater_override, ii.macro_source
FROM item_ingredients ii
JOIN log_items li ON li.id = ii.item_id
JOIN meal_logs ml ON ml.id = li.log_id AND NOT ml.is_superseded
JOIN meals m ON m.id = ml.meal_id
WHERE ii.atwater_override IS NOT NULL;


-- ========================= SECTION 5: TELEMETRY ==============================
-- Abandoned drafts are invisible: they never reach a commit call. Accepted.

CREATE TABLE intake_events (
    id               bigserial PRIMARY KEY,
    staging_id       uuid        NOT NULL,
    occurred_at      timestamptz NOT NULL DEFAULT now(),
    outcome          intake_outcome NOT NULL,
    log_id           bigint REFERENCES meal_logs(id),
    meal_id          bigint REFERENCES meals(id),
    attached         boolean,
    raw_utterance    text,
    item_count       int,
    gaps             jsonb NOT NULL DEFAULT '[]'::jsonb,
    unconsumed_spans jsonb NOT NULL DEFAULT '[]'::jsonb,
    reject_reason    text
);
CREATE INDEX intake_events_time ON intake_events (occurred_at);


-- ======================== SECTION 6: COMMIT PATH =============================

CREATE OR REPLACE FUNCTION fn_new_staging_id() RETURNS uuid AS $$
    SELECT gen_random_uuid();
$$ LANGUAGE sql VOLATILE;

CREATE OR REPLACE FUNCTION fn_log_date(p_at timestamptz, p_tz text, p_rollover smallint)
RETURNS date AS $$
    SELECT ((p_at AT TIME ZONE p_tz) - make_interval(hours => p_rollover))::date;
$$ LANGUAGE sql IMMUTABLE;

-- ATWATER IDENTITY. kcal should approximate 4P + 4C + 9F. With no reference
-- database this is the ONLY automated check on the model's numbers, and it
-- catches transposed digits and internally incoherent guesses for free.
-- It cannot catch a self-consistent but wrong estimate.
CREATE OR REPLACE FUNCTION fn_atwater_delta(
    p_kcal numeric, p_protein numeric, p_carbs numeric, p_fat numeric
) RETURNS numeric AS $$
    SELECT p_kcal - (4*p_protein + 4*p_carbs + 9*p_fat);
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION fn_atwater_ok(
    p_kcal numeric, p_protein numeric, p_carbs numeric, p_fat numeric
) RETURNS boolean AS $$
    SELECT abs(fn_atwater_delta(p_kcal,p_protein,p_carbs,p_fat))
           <= greatest((SELECT atwater_tol_kcal FROM user_settings WHERE id=1),
                       (SELECT atwater_tol_pct  FROM user_settings WHERE id=1)/100.0 * p_kcal);
$$ LANGUAGE sql STABLE;


-- ATTACHMENT CANDIDATES. Proposes; never attaches. A single match is still only
-- a proposal, because attaching to the wrong meal corrupts a correct one.
CREATE OR REPLACE FUNCTION fn_find_attachable_meals(
    p_eaten_at timestamptz, p_meal_type_key text
) RETURNS TABLE (meal_id bigint, name text, started_at timestamptz, minutes_apart numeric) AS $$
    SELECT m.id, m.name, vm.started_at,
           round(abs(extract(epoch FROM (vm.started_at - p_eaten_at))/60.0)::numeric,1)
    FROM meals m
    JOIN v_meal_macros vm ON vm.meal_id = m.id
    JOIN meal_types mt ON mt.key = m.meal_type_key
    WHERE m.meal_type_key = p_meal_type_key
      AND m.log_date = fn_log_date(p_eaten_at,
            (SELECT timezone FROM user_settings WHERE id=1),
            (SELECT day_rollover_hour FROM user_settings WHERE id=1))
      AND abs(extract(epoch FROM (vm.started_at - p_eaten_at))) <= mt.dup_window_minutes*60
    ORDER BY abs(extract(epoch FROM (vm.started_at - p_eaten_at)));
$$ LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION fn_find_duplicate_log(
    p_hash bytea, p_meal_id bigint, p_eaten_at timestamptz, p_meal_type_key text
) RETURNS TABLE (log_id bigint, meal_id bigint, scope text, minutes_apart numeric) AS $$
    SELECT ml.id, ml.meal_id,
           CASE WHEN ml.meal_id = p_meal_id THEN 'same_meal' ELSE 'other_meal' END,
           round(abs(extract(epoch FROM (ml.eaten_at - p_eaten_at))/60.0)::numeric,1)
    FROM meal_logs ml
    JOIN meals m ON m.id = ml.meal_id
    JOIN meal_types mt ON mt.key = m.meal_type_key
    WHERE ml.content_hash = p_hash AND NOT ml.is_superseded
      AND (ml.meal_id = p_meal_id
           OR (m.meal_type_key = p_meal_type_key
               -- WINDOW against the existing row's timestamp, not equality of a
               -- rounded bucket: bucketing collides 12:00:01 with 12:04:59
               -- while splitting 12:04:59 from 12:05:01.
               AND abs(extract(epoch FROM (ml.eaten_at - p_eaten_at))) <= mt.dup_window_minutes*60))
    ORDER BY (ml.meal_id = p_meal_id) DESC,
             abs(extract(epoch FROM (ml.eaten_at - p_eaten_at)));
$$ LANGUAGE sql STABLE;


-- Nested read-back: meal > logs > items > ingredients. The assistant reports
-- THESE numbers. The server did every multiplication and every sum.
CREATE OR REPLACE FUNCTION fn_meal_readback(p_meal_id bigint) RETURNS jsonb AS $$
    SELECT jsonb_build_object(
      'meal_id', m.id, 'name', m.name, 'name_source', m.name_source,
      'meal', m.meal_type_key, 'meal_type_inferred', m.meal_type_inferred,
      'log_date', m.log_date, 'log_count', vm.log_count,
      'started_at_local', to_char(vm.started_at AT TIME ZONE m.tz,'YYYY-MM-DD HH24:MI'),
      'meal_totals', jsonb_build_object('kcal',round(vm.kcal,1),
          'protein_g',round(vm.protein_g,1),'carbs_g',round(vm.carbs_g,1),
          'fat_g',round(vm.fat_g,1)),
      'logs', (
        SELECT jsonb_agg(jsonb_build_object(
          'log_id', ml.id,
          'eaten_at_local',  to_char(ml.eaten_at  AT TIME ZONE m.tz,'YYYY-MM-DD HH24:MI'),
          'logged_at_local', to_char(ml.logged_at AT TIME ZONE m.tz,'YYYY-MM-DD HH24:MI'),
          'items', (
            SELECT jsonb_agg(jsonb_build_object(
              'name', li.name, 'as_stated', li.raw_text,
              'portion_fraction', CASE WHEN li.portion_fraction_num IS NULL THEN NULL
                  ELSE li.portion_fraction_num||'/'||li.portion_fraction_den END,
              'grams', round(vi.grams,1),
              'macros', jsonb_build_object('kcal',round(vi.kcal,1),
                  'protein_g',round(vi.protein_g,1),'carbs_g',round(vi.carbs_g,1),
                  'fat_g',round(vi.fat_g,1)),
              'ingredients', (
                SELECT jsonb_agg(jsonb_build_object(
                  'food', ii.food_name,
                  'grams', round(ii.grams,1),
                  'grams_before_fraction', round(ii.grams_before_fraction,1),
                  'per_100g', jsonb_build_object('kcal',ii.kcal_per_100g,
                      'protein_g',ii.protein_per_100g,'carbs_g',ii.carbs_per_100g,
                      'fat_g',ii.fat_per_100g),
                  'quantity', CASE WHEN ii.unit_label IS NULL THEN NULL
                      ELSE (ii.quantity_num||'/'||ii.quantity_den||' '||ii.unit_label) END,
                  'macro_source', ii.macro_source,
                  'confidence', ii.resolution_confidence,
                  'atwater_override', ii.atwater_override
                ) ORDER BY ii.ordinal)
                FROM item_ingredients ii WHERE ii.item_id = li.id)
            ) ORDER BY li.ordinal)
            FROM log_items li JOIN v_item_macros vi ON vi.item_id = li.id
            WHERE li.log_id = ml.id)
          ) ORDER BY ml.eaten_at)
        FROM meal_logs ml WHERE ml.meal_id = m.id AND NOT ml.is_superseded),
      'day_totals_after', (
        SELECT jsonb_build_object('kcal',round(kcal,1),'protein_g',round(protein_g,1),
               'carbs_g',round(carbs_g,1),'fat_g',round(fat_g,1))
        FROM v_daily_totals WHERE log_date = m.log_date),
      'day_quality', (
        SELECT jsonb_build_object('pct_kcal_user_stated',pct_kcal_user_stated,
               'pct_kcal_llm_knowledge',pct_kcal_llm_knowledge,
               'pct_kcal_llm_estimate',pct_kcal_llm_estimate)
        FROM v_daily_data_quality WHERE log_date = m.log_date))
    FROM meals m JOIN v_meal_macros vm ON vm.meal_id = m.id WHERE m.id = p_meal_id;
$$ LANGUAGE sql STABLE;


-- Called by the API layer AFTER catching a rejection, on its own transaction.
-- RAISE EXCEPTION rolls back the throwing transaction, so a function cannot log
-- its own rejects.
CREATE OR REPLACE FUNCTION fn_log_reject(p_staging_id uuid, p_payload jsonb, p_reason text)
RETURNS void AS $$
    INSERT INTO intake_events (staging_id, outcome, raw_utterance, item_count,
                               gaps, unconsumed_spans, reject_reason)
    VALUES (p_staging_id,'rejected',p_payload->>'raw_utterance',
            jsonb_array_length(coalesce(p_payload->'items','[]'::jsonb)),
            coalesce(p_payload->'gaps','[]'::jsonb),
            coalesce(p_payload->'unconsumed_spans','[]'::jsonb), p_reason);
$$ LANGUAGE sql VOLATILE;


-- =============================================================================
-- THE GATE.
--
-- Payload:
-- {
--   "raw_utterance": "half a cheeseburger and a cup of rice",
--   "eaten_at": "2026-08-20T18:00:00-04:00",
--   "meal": {"meal_id": null,        -- non-null => ATTACH to that meal
--            "name": "cheeseburger and rice", "name_source": "derived",
--            "meal_type_key": "dinner", "meal_type_inferred": true},
--   "unconsumed_spans": [],
--   "gaps": [{"kind":"composite","item_ordinal":1,"status":"answered","is_material":true}],
--   "items": [
--     {"ordinal":1,"name":"cheeseburger","raw_text":"half a cheeseburger",
--      "span":[0,19],"portion_fraction":{"num":1,"den":2},
--      "ingredients":[
--        {"ordinal":1,"food_name":"hamburger bun","grams":60,
--         "kcal_per_100g":279,"protein_per_100g":9.5,"carbs_per_100g":50,"fat_per_100g":4.2,
--         "quantity":{"num":1,"den":1},"unit_label":"bun","unit_class":"countable",
--         "macro_source":"llm_knowledge","resolution_confidence":"user_confirmed"}]}
--   ]
-- }
--
-- MACROS ARE PER 100g. grams is the model's conversion of what the user said;
-- quantity + unit_label record what the user actually said, for audit.
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_commit_log(
    p_staging_id        uuid,
    p_payload           jsonb,
    p_confirm_duplicate boolean DEFAULT false,
    p_confirm_atwater   boolean DEFAULT false
) RETURNS jsonb AS $$
DECLARE
    v_existing bigint; v_meal_id bigint; v_log_id bigint; v_item_id bigint;
    v_item jsonb; v_ing jsonb;
    v_items jsonb := p_payload -> 'items';
    v_spans jsonb := coalesce(p_payload->'unconsumed_spans','[]'::jsonb);
    v_gaps  jsonb := coalesce(p_payload->'gaps','[]'::jsonb);
    v_reject text; v_hash bytea; v_grams numeric;
    v_num int; v_den int; v_ord int; v_iord int;
    v_dup record; v_bad record; v_attached boolean := false;
    v_tz text; v_rollover smallint;
    v_eaten timestamptz := (p_payload ->> 'eaten_at')::timestamptz;
BEGIN
    -- 1. IDEMPOTENCY. The entire replay guarantee, in one lookup.
    SELECT ml.meal_id INTO v_existing FROM meal_logs ml WHERE ml.staging_id = p_staging_id;
    IF FOUND THEN
        RETURN fn_meal_readback(v_existing) || jsonb_build_object('replayed', true);
    END IF;

    SELECT timezone, day_rollover_hour INTO v_tz, v_rollover FROM user_settings WHERE id=1;

    -- 2. STRUCTURAL VALIDATION. Reasons collected so the assistant can ask
    --    everything in ONE turn rather than serially.
    IF v_items IS NULL OR jsonb_array_length(v_items) = 0 THEN
        v_reject := 'no items';
    ELSIF jsonb_array_length(v_spans) > 0 THEN
        -- SPAN COVERAGE: food-bearing text that produced no item means an item
        -- was dropped. Do not put non-food text here.
        v_reject := 'unconsumed spans (dropped items?): ' || v_spans::text;
    END IF;

    IF v_reject IS NULL THEN
        SELECT 'open material gap(s): ' || jsonb_agg(g)::text INTO v_reject
        FROM jsonb_array_elements(v_gaps) g
        WHERE (g->>'status')='open' AND (g->>'is_material')::boolean;
    END IF;

    IF v_reject IS NULL THEN
      FOR v_item IN SELECT jsonb_array_elements(v_items) LOOP
        IF coalesce(v_item->>'raw_text','')='' OR v_item->'span' IS NULL THEN
            v_reject := 'unanchored item - possible hallucination: '||coalesce(v_item->>'name','?');
        ELSIF coalesce(jsonb_array_length(v_item->'ingredients'),0)=0 THEN
            v_reject := 'item has no ingredients: '||(v_item->>'name');
        ELSIF jsonb_array_length(v_item->'ingredients') > 1
              -- COMPOSITE GUARD. Ingredients are not span-anchored, so a
              -- decomposition needs explicit confirmation. This is where
              -- unrequested mayo gets added.
              AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_gaps) g
                              WHERE (g->>'kind')='composite'
                                AND (g->>'item_ordinal')::int = (v_item->>'ordinal')::int
                                AND (g->>'status') <> 'open')
        THEN
            v_reject := 'composite item "'||(v_item->>'name')
                        ||'" needs an answered composite gap (ingredients are not anchored)';
        ELSE
          FOR v_ing IN SELECT jsonb_array_elements(v_item->'ingredients') LOOP
            IF coalesce(v_ing->>'food_name','')='' THEN
                v_reject := 'ingredient has no food_name in "'||(v_item->>'name')||'"';
            ELSIF v_ing->>'grams' IS NULL THEN
                v_reject := 'ingredient "'||(v_ing->>'food_name')||'" has no grams';
            ELSIF v_ing->>'kcal_per_100g' IS NULL OR v_ing->>'protein_per_100g' IS NULL
               OR v_ing->>'carbs_per_100g' IS NULL OR v_ing->>'fat_per_100g' IS NULL THEN
                -- With no reference database there is nothing to fall back on.
                -- "I don't know" is not storable, and that is deliberate.
                v_reject := 'ingredient "'||(v_ing->>'food_name')
                            ||'" is missing per-100g macros (all four required)';
            END IF;
            EXIT WHEN v_reject IS NOT NULL;
          END LOOP;
        END IF;
        EXIT WHEN v_reject IS NOT NULL;
      END LOOP;
    END IF;

    IF v_reject IS NOT NULL THEN
        RAISE EXCEPTION 'cannot commit: %', v_reject;
    END IF;

    -- 3. Apply the ITEM fraction to grams. Macros are densities, so they are
    --    NOT scaled - the views multiply grams by density. One code path.
    CREATE TEMP TABLE _res (
        item_ord int, item_name text, item_raw text, item_s int, item_e int,
        fnum int, fden int, ing_ord int, food_name text,
        grams numeric, grams_before numeric,
        kcal numeric, protein numeric, carbs numeric, fat numeric, fiber numeric,
        atwater_override text, msource macro_source, conf resolution_confidence,
        qnum int, qden int, unit_label text, unit_class unit_class,
        qmin numeric, qmax numeric, ing_raw text, ing_s int, ing_e int
    ) ON COMMIT DROP;

    v_ord := 0;
    FOR v_item IN SELECT jsonb_array_elements(v_items) LOOP
        v_ord := v_ord + 1;
        v_num := coalesce((v_item#>>'{portion_fraction,num}')::int, 1);
        v_den := coalesce((v_item#>>'{portion_fraction,den}')::int, 1);
        v_iord := 0;
        FOR v_ing IN SELECT jsonb_array_elements(v_item->'ingredients') LOOP
            v_iord := v_iord + 1;
            v_grams := (v_ing->>'grams')::numeric;
            INSERT INTO _res VALUES (
                coalesce((v_item->>'ordinal')::int, v_ord),
                v_item->>'name', v_item->>'raw_text',
                (v_item#>>'{span,0}')::int, (v_item#>>'{span,1}')::int,
                CASE WHEN v_num=1 AND v_den=1 THEN NULL ELSE v_num END,
                CASE WHEN v_num=1 AND v_den=1 THEN NULL ELSE v_den END,
                coalesce((v_ing->>'ordinal')::int, v_iord),
                v_ing->>'food_name',
                v_grams * v_num::numeric / v_den::numeric, v_grams,
                (v_ing->>'kcal_per_100g')::numeric, (v_ing->>'protein_per_100g')::numeric,
                (v_ing->>'carbs_per_100g')::numeric, (v_ing->>'fat_per_100g')::numeric,
                (v_ing->>'fiber_per_100g')::numeric,
                v_ing->>'atwater_override',
                (v_ing->>'macro_source')::macro_source,
                (v_ing->>'resolution_confidence')::resolution_confidence,
                (v_ing#>>'{quantity,num}')::int, (v_ing#>>'{quantity,den}')::int,
                v_ing->>'unit_label', (v_ing->>'unit_class')::unit_class,
                (v_ing->>'quantity_min')::numeric, (v_ing->>'quantity_max')::numeric,
                v_ing->>'raw_text', (v_ing#>>'{span,0}')::int, (v_ing#>>'{span,1}')::int);
        END LOOP;
    END LOOP;

    -- 4. ATWATER GATE. Soft: warn and require confirmation, because alcohol
    --    (7 kcal/g), sugar alcohols and odd labels legitimately break the
    --    identity. An override is recorded so v_atwater_overrides can show you
    --    where the model and its own arithmetic disagreed.
    IF NOT p_confirm_atwater THEN
        SELECT food_name, kcal,
               round(4*protein + 4*carbs + 9*fat, 1) AS implied,
               round(fn_atwater_delta(kcal,protein,carbs,fat),1) AS delta
          INTO v_bad
          FROM _res
         WHERE atwater_override IS NULL
           AND NOT fn_atwater_ok(kcal, protein, carbs, fat)
         LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION
              'macro check failed for "%": stated % kcal/100g but 4P+4C+9F implies % (off by %). Confirm with the user, then pass confirm_atwater or set atwater_override.',
              v_bad.food_name, v_bad.kcal, v_bad.implied, v_bad.delta;
        END IF;
    END IF;

    -- 5. CONTENT HASH over the resolved ingredient set.
    SELECT digest(string_agg(food_key_calc||':'||round(grams,1)::text,'|'
                             ORDER BY food_key_calc, round(grams,1)),'sha256')
      INTO v_hash
      FROM (SELECT trim(both '_' from lower(regexp_replace(food_name,'[^a-zA-Z0-9]+','_','g')))
                   AS food_key_calc, grams FROM _res) t;

    v_meal_id := (p_payload#>>'{meal,meal_id}')::bigint;

    IF NOT p_confirm_duplicate THEN
        SELECT * INTO v_dup FROM fn_find_duplicate_log(
            v_hash, v_meal_id, v_eaten, p_payload#>>'{meal,meal_type_key}') LIMIT 1;
        IF FOUND THEN
            -- SOFT in both scopes. Two identical protein shakes in one day is
            -- real; a hard block is worse than an occasional double row.
            RAISE EXCEPTION
              'possible duplicate (%): log % in meal %, % minutes away; pass confirm_duplicate to override',
              v_dup.scope, v_dup.log_id, v_dup.meal_id, v_dup.minutes_apart
              USING ERRCODE = 'unique_violation';
        END IF;
    END IF;

    -- 6. ATTACH or CREATE. A non-null meal_id IS the user's confirmation.
    IF v_meal_id IS NOT NULL THEN
        PERFORM 1 FROM meals WHERE id = v_meal_id;
        IF NOT FOUND THEN RAISE EXCEPTION 'unknown meal_id %', v_meal_id; END IF;
        v_attached := true;
        -- A later log NEVER regenerates a derived name.
    ELSE
        INSERT INTO meals (name, name_source, meal_type_key, meal_type_inferred,
                           log_date, tz, derived_from_meal_id)
        VALUES (coalesce(p_payload#>>'{meal,name}','Untitled meal'),
                coalesce((p_payload#>>'{meal,name_source}')::name_source,'derived'),
                p_payload#>>'{meal,meal_type_key}',
                coalesce((p_payload#>>'{meal,meal_type_inferred}')::boolean,false),
                fn_log_date(v_eaten, v_tz, v_rollover), v_tz,
                (p_payload->>'derived_from_meal_id')::bigint)
        RETURNING id INTO v_meal_id;
    END IF;

    INSERT INTO meal_logs (meal_id, eaten_at, content_hash, staging_id, raw_utterance, note)
    VALUES (v_meal_id, v_eaten, v_hash, p_staging_id,
            p_payload->>'raw_utterance', p_payload->>'note')
    ON CONFLICT (staging_id) DO NOTHING
    RETURNING id INTO v_log_id;

    IF v_log_id IS NULL THEN   -- lost a race with an identical concurrent call
        SELECT ml.id, ml.meal_id INTO v_log_id, v_meal_id
          FROM meal_logs ml WHERE ml.staging_id = p_staging_id;
        RETURN fn_meal_readback(v_meal_id) || jsonb_build_object('replayed', true);
    END IF;

    FOR v_ord IN SELECT DISTINCT item_ord FROM _res ORDER BY item_ord LOOP
        INSERT INTO log_items (log_id, ordinal, name, portion_fraction_num,
                               portion_fraction_den, raw_text, span_start, span_end)
        SELECT v_log_id, item_ord, item_name, fnum, fden, item_raw, item_s, item_e
          FROM _res WHERE item_ord = v_ord LIMIT 1
        RETURNING id INTO v_item_id;

        INSERT INTO item_ingredients (item_id, ordinal, food_name, grams,
            grams_before_fraction, kcal_per_100g, protein_per_100g, carbs_per_100g,
            fat_per_100g, fiber_per_100g, atwater_override, macro_source,
            resolution_confidence, quantity_num, quantity_den, unit_label,
            unit_class_used, quantity_min, quantity_max, raw_text, span_start, span_end)
        SELECT v_item_id, ing_ord, food_name, grams, grams_before, kcal, protein,
               carbs, fat, fiber, atwater_override, msource, conf, qnum, qden,
               unit_label, unit_class, qmin, qmax, ing_raw, ing_s, ing_e
          FROM _res WHERE item_ord = v_ord ORDER BY ing_ord;
    END LOOP;

    INSERT INTO intake_events (staging_id, outcome, log_id, meal_id, attached,
                               raw_utterance, item_count, gaps, unconsumed_spans)
    VALUES (p_staging_id,'committed',v_log_id,v_meal_id,v_attached,
            p_payload->>'raw_utterance', jsonb_array_length(v_items), v_gaps, v_spans);

    -- 7. READ BACK. The assistant reports these numbers to the user.
    RETURN fn_meal_readback(v_meal_id)
           || jsonb_build_object('replayed',false,'log_id',v_log_id,'attached',v_attached);
END $$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION fn_rename_meal(p_meal_id bigint, p_name text) RETURNS jsonb AS $$
BEGIN
    UPDATE meals SET name = p_name, name_source = 'user' WHERE id = p_meal_id;
    RETURN fn_meal_readback(p_meal_id);
END $$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION fn_supersede_log(
    p_old_log_id bigint, p_staging_id uuid, p_payload jsonb
) RETURNS jsonb AS $$
DECLARE v_res jsonb; v_new bigint; v_meal bigint;
BEGIN
    v_res  := fn_commit_log(p_staging_id, p_payload, true, true);  -- corrections bypass both gates
    v_new  := (v_res->>'log_id')::bigint;
    v_meal := (v_res->>'meal_id')::bigint;
    UPDATE meal_logs SET is_superseded = true WHERE id = p_old_log_id;
    UPDATE meal_logs SET supersedes_log_id = p_old_log_id WHERE id = v_new;
    INSERT INTO intake_events (staging_id, outcome, log_id, meal_id, raw_utterance)
    VALUES (p_staging_id,'superseded',v_new,v_meal,p_payload->>'raw_utterance');
    RETURN fn_meal_readback(v_meal) || jsonb_build_object('supersedes_log_id', p_old_log_id);
END $$ LANGUAGE plpgsql;


CREATE VIEW v_intake_health AS
WITH per_day AS (
    SELECT date_trunc('day', occurred_at)::date AS day, outcome, attached, gaps
    FROM intake_events
), gap_counts AS (
    SELECT p.day, g->>'kind' AS kind, count(*) AS n
    FROM per_day p, jsonb_array_elements(p.gaps) g GROUP BY p.day, g->>'kind'
)
SELECT p.day,
       count(*) FILTER (WHERE p.outcome='committed')  AS committed,
       count(*) FILTER (WHERE p.outcome='rejected')   AS rejected,
       count(*) FILTER (WHERE p.outcome='superseded') AS corrections,
       count(*) FILTER (WHERE p.attached)             AS attachments,
       (SELECT jsonb_object_agg(kind,n) FROM gap_counts gc WHERE gc.day = p.day) AS gap_kinds
FROM per_day p GROUP BY p.day;
