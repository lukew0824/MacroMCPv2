-- =============================================================================
-- MacroMCP - schema v6 (small multi-user)
-- PostgreSQL 15+
--
-- CHANGE FROM v5: MULTI-USER. A `users` table, `meals` and `intake_events`
--   carry `user_id`, `user_settings` becomes one row per user instead of a
--   singleton, and every commit-path / query-side function takes p_user_id
--   as an explicit parameter and scopes its work by it.
--
-- WHAT THIS FILE DOES NOT DO:
--   - No authentication. No passwords, tokens, or sessions live here. p_user_id
--     is trusted as-given by every function in this file. The API/MCP layer is
--     responsible for resolving "who is calling" from real credentials BEFORE
--     it ever calls fn_commit_log or anything else - never from a field inside
--     the JSON payload, which the model could get wrong. Treat p_user_id the
--     way you'd treat a session's authenticated identity, not user input.
--   - No row-level security (RLS). Cross-user isolation is enforced by every
--     function filtering explicitly on user_id, matching how this schema
--     already enforces everything else - in code, not by a database policy
--     layer. The sharp edge: an ad-hoc SELECT against the base tables or views
--     that skips the user_id filter WILL return every user's data. There is
--     nothing in the schema that stops that. If a second surface (an admin
--     dashboard, a raw reporting query) gets built later that doesn't go
--     through these functions, add RLS policies then rather than trusting
--     every future query author to remember the filter.
--   - meal_types stays global/shared. Breakfast/lunch/dinner/snack are
--     categories, not user data. Per-user customization is not built.
--
-- Everything else - the append-only log, the per-100g macro contract, the
-- Atwater gate, the composite guard, idempotent commits - is unchanged from
-- v5. See docs/design-notes.md for that rationale (or `git log -p` on this
-- file for the exact single-user version this evolved from).
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================ SECTION 1: ENUMS ===============================

CREATE TYPE macro_source AS ENUM (
    'llm_knowledge',  -- model recalled a well-known food's density
    'llm_estimate',   -- model guessed: unusual, restaurant, or composite dish
    'user_stated');   -- user read a label or gave the numbers directly

CREATE TYPE unit_class AS ENUM (
    'mass','standard_volume','vessel','countable',
    'fraction_of_whole','gestural','branded_serving');

CREATE TYPE resolution_confidence AS ENUM ('exact','user_confirmed','estimated');

CREATE TYPE gap_kind AS ENUM (
    'missing_quantity','vessel_unit','ambiguous_unit_dimension',
    'volumetric_on_solid','prep_state','cooking_fat','variant','brand',
    'composite','quantity_scope','reference_ambiguous','portion_unclear',
    'attachment_ambiguous','macro_uncertain');

CREATE TYPE name_source AS ENUM ('derived','user');
CREATE TYPE intake_outcome AS ENUM ('committed','superseded','rejected');


-- ============================ SECTION 2: USERS & CONFIG ======================

-- Deliberately minimal. No password/token column: this table exists so other
-- tables have something stable to point a foreign key at. Whatever the
-- API/MCP layer uses to authenticate a request, it resolves to one of these
-- ids before touching anything below.
CREATE TABLE users (
    id           bigserial PRIMARY KEY,
    username     text NOT NULL UNIQUE CHECK (username ~ '^[a-z0-9_]{2,32}$'),
    display_name text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now()
);

-- ONE ROW PER USER now, not a singleton. Created automatically (see trigger
-- below) so the app never has to remember a second insert when it makes a
-- user, and a user can never exist without settings for fn_commit_log to read.
CREATE TABLE user_settings (
    user_id           bigint PRIMARY KEY REFERENCES users(id),
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

CREATE OR REPLACE FUNCTION trg_users_create_settings() RETURNS trigger AS $$
BEGIN
    INSERT INTO user_settings (user_id) VALUES (NEW.id);
    RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER users_create_settings AFTER INSERT ON users
    FOR EACH ROW EXECUTE FUNCTION trg_users_create_settings();


-- Global, shared across all users on purpose - see header note.
CREATE TABLE meal_types (
    key                text PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_]*$'),
    display_name       text NOT NULL,
    ordinal            int  NOT NULL UNIQUE,
    is_builtin         boolean NOT NULL DEFAULT false,
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
--   meals              the eating event.  "chicken and rice", dinner - OWNED BY A USER
--     meal_logs        one submission.    eaten_at + logged_at
--       log_items      one named thing.   "cheeseburger", fraction 1/2
--         item_ingredients                bun 60g, patty 113g, cheese 19g
--
-- user_id lives ONLY on meals, the top of this chain. meal_logs / log_items /
-- item_ingredients are scoped by joining up to meals.user_id rather than
-- carrying their own copy. At "small multi-user" scale this join costs
-- nothing and it means there is exactly one place a row's owner is recorded -
-- no risk of a denormalized copy drifting from the source of truth.

CREATE TABLE meals (
    id                   bigserial PRIMARY KEY,
    user_id              bigint      NOT NULL REFERENCES users(id),
    -- Derived from the FIRST log's items, or user-supplied. A later log does
    -- NOT regenerate a derived name.
    name                 text        NOT NULL,
    name_source          name_source NOT NULL DEFAULT 'derived',
    meal_type_key        text        NOT NULL REFERENCES meal_types(key),
    meal_type_inferred   boolean     NOT NULL DEFAULT false,
    log_date             date        NOT NULL,
    tz                   text        NOT NULL,
    derived_from_meal_id bigint REFERENCES meals(id),
    created_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX meals_user_day_type ON meals (user_id, log_date, meal_type_key);

CREATE OR REPLACE FUNCTION trg_meals_name_only() RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'meals cannot be deleted (id=%)', OLD.id;
    END IF;
    IF  NEW.user_id       IS DISTINCT FROM OLD.user_id
     OR NEW.meal_type_key IS DISTINCT FROM OLD.meal_type_key
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
    -- IDEMPOTENCY. Server-minted, UNIQUE across ALL users - a UUID collision
    -- between two different users' calls is not a realistic risk, and a
    -- global unique constraint is simpler than a composite one.
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
    portion_fraction_num int CHECK (portion_fraction_num > 0),
    portion_fraction_den int CHECK (portion_fraction_den > 0),
    CHECK ((portion_fraction_num IS NULL) = (portion_fraction_den IS NULL)),
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

    food_name             text   NOT NULL CHECK (food_name <> ''),
    food_key              text GENERATED ALWAYS AS (
                              trim(both '_' from
                                lower(regexp_replace(food_name,'[^a-zA-Z0-9]+','_','g')))
                          ) STORED,

    grams                 numeric(10,3) NOT NULL CHECK (grams > 0),  -- AFTER item fraction
    grams_before_fraction numeric(10,3) NOT NULL CHECK (grams_before_fraction > 0),

    kcal_per_100g         numeric(9,3) NOT NULL CHECK (kcal_per_100g BETWEEN 0 AND 900),
    protein_per_100g      numeric(9,3) NOT NULL CHECK (protein_per_100g BETWEEN 0 AND 100),
    carbs_per_100g        numeric(9,3) NOT NULL CHECK (carbs_per_100g   BETWEEN 0 AND 100),
    fat_per_100g          numeric(9,3) NOT NULL CHECK (fat_per_100g     BETWEEN 0 AND 100),
    fiber_per_100g        numeric(9,3) CHECK (fiber_per_100g >= 0),
    CHECK (protein_per_100g + carbs_per_100g + fat_per_100g <= 100.5),

    atwater_override      text,

    macro_source          macro_source          NOT NULL,
    resolution_confidence resolution_confidence NOT NULL,

    quantity_num          int,
    quantity_den          int,
    unit_label            text,
    unit_class_used       unit_class,
    quantity_min          numeric(10,3),
    quantity_max          numeric(10,3),
    CHECK (quantity_min IS NULL OR quantity_max IS NULL OR quantity_min <= quantity_max),

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
-- Every view now carries user_id and every GROUP BY includes it. This is the
-- part that is easy to get wrong silently: a view grouped by log_date alone
-- would merge two users' same-day totals into one number and nothing would
-- error - it would just be quietly wrong, the exact failure mode this schema
-- exists to prevent elsewhere. Treat user_id as a required grouping column
-- everywhere below, the same way log_date is.

CREATE VIEW v_ingredient_macros AS
SELECT ii.id AS ingredient_id, ii.item_id, li.log_id, ml.meal_id,
       m.user_id, m.log_date, m.meal_type_key, ml.eaten_at,
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
SELECT item_id, log_id, meal_id, user_id, log_date, sum(grams) AS grams,
       sum(kcal) AS kcal, sum(protein_g) AS protein_g,
       sum(carbs_g) AS carbs_g, sum(fat_g) AS fat_g, sum(fiber_g) AS fiber_g
FROM v_ingredient_macros GROUP BY 1,2,3,4,5;

CREATE VIEW v_log_macros AS
SELECT log_id, meal_id, user_id, log_date, sum(kcal) AS kcal, sum(protein_g) AS protein_g,
       sum(carbs_g) AS carbs_g, sum(fat_g) AS fat_g
FROM v_ingredient_macros GROUP BY 1,2,3,4;

CREATE VIEW v_meal_macros AS
SELECT m.id AS meal_id, m.user_id, m.name, m.meal_type_key, m.log_date,
       min(vim.eaten_at) AS started_at,      -- no need to store it
       count(DISTINCT vim.log_id) AS log_count,
       sum(vim.kcal) AS kcal, sum(vim.protein_g) AS protein_g,
       sum(vim.carbs_g) AS carbs_g, sum(vim.fat_g) AS fat_g, sum(vim.fiber_g) AS fiber_g
FROM meals m LEFT JOIN v_ingredient_macros vim ON vim.meal_id = m.id
GROUP BY m.id, m.user_id, m.name, m.meal_type_key, m.log_date;

CREATE VIEW v_daily_totals AS
SELECT user_id, log_date, sum(kcal) AS kcal, sum(protein_g) AS protein_g,
       sum(carbs_g) AS carbs_g, sum(fat_g) AS fat_g, sum(fiber_g) AS fiber_g
FROM v_ingredient_macros GROUP BY 1,2;

-- THE HONESTY VIEW. With no reference database, every number is either model
-- knowledge or a user assertion. This is the only thing that tells you which.
CREATE VIEW v_daily_data_quality AS
SELECT vim.user_id, vim.log_date,
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
       round(avg(extract(epoch FROM (ml.logged_at - ml.eaten_at))/60.0)::numeric,1)
             AS avg_log_delay_minutes
FROM v_ingredient_macros vim JOIN meal_logs ml ON ml.id = vim.log_id
GROUP BY vim.user_id, vim.log_date;

-- Approximate trend grouping, the cost of dropping the reference database.
CREATE VIEW v_food_trends AS
SELECT user_id, food_key, min(food_name) AS example_name, log_date,
       count(*) AS times, sum(grams) AS grams, sum(kcal) AS kcal,
       sum(protein_g) AS protein_g
FROM v_ingredient_macros GROUP BY user_id, food_key, log_date;

-- Where the model and its own arithmetic disagreed and the user waved it
-- through. Worth reviewing per-user: a cluster here means that user's model
-- calls are guessing badly in some category.
CREATE VIEW v_atwater_overrides AS
SELECT ii.id, m.user_id, m.log_date, ii.food_name, ii.kcal_per_100g,
       round(4*ii.protein_per_100g + 4*ii.carbs_per_100g + 9*ii.fat_per_100g, 1) AS atwater_kcal,
       ii.atwater_override, ii.macro_source
FROM item_ingredients ii
JOIN log_items li ON li.id = ii.item_id
JOIN meal_logs ml ON ml.id = li.log_id AND NOT ml.is_superseded
JOIN meals m ON m.id = ml.meal_id
WHERE ii.atwater_override IS NOT NULL;


-- ========================= SECTION 5: TELEMETRY ==============================
-- Abandoned drafts are invisible: they never reach a commit call. Accepted.
-- user_id lives here directly rather than via meal_id, because a rejected
-- draft has no meal_id yet - the row it's attached to may never exist.

CREATE TABLE intake_events (
    id               bigserial PRIMARY KEY,
    user_id          bigint      NOT NULL REFERENCES users(id),
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
CREATE INDEX intake_events_user_time ON intake_events (user_id, occurred_at);

CREATE VIEW v_intake_health AS
WITH per_day AS (
    SELECT user_id, date_trunc('day', occurred_at)::date AS day, outcome, attached, gaps
    FROM intake_events
), gap_counts AS (
    SELECT p.user_id, p.day, g->>'kind' AS kind, count(*) AS n
    FROM per_day p, jsonb_array_elements(p.gaps) g GROUP BY p.user_id, p.day, g->>'kind'
)
SELECT p.user_id, p.day,
       count(*) FILTER (WHERE p.outcome='committed')  AS committed,
       count(*) FILTER (WHERE p.outcome='rejected')   AS rejected,
       count(*) FILTER (WHERE p.outcome='superseded') AS corrections,
       count(*) FILTER (WHERE p.attached)             AS attachments,
       (SELECT jsonb_object_agg(kind,n) FROM gap_counts gc
         WHERE gc.user_id = p.user_id AND gc.day = p.day) AS gap_kinds
FROM per_day p GROUP BY p.user_id, p.day;


-- ======================== SECTION 6: COMMIT PATH =============================

CREATE OR REPLACE FUNCTION fn_new_staging_id() RETURNS uuid AS $$
    SELECT gen_random_uuid();
$$ LANGUAGE sql VOLATILE;

CREATE OR REPLACE FUNCTION fn_log_date(p_at timestamptz, p_tz text, p_rollover smallint)
RETURNS date AS $$
    SELECT ((p_at AT TIME ZONE p_tz) - make_interval(hours => p_rollover))::date;
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION fn_atwater_delta(
    p_kcal numeric, p_protein numeric, p_carbs numeric, p_fat numeric
) RETURNS numeric AS $$
    SELECT p_kcal - (4*p_protein + 4*p_carbs + 9*p_fat);
$$ LANGUAGE sql IMMUTABLE;

-- Now reads its tolerance from the CALLING user's settings, not "the" settings.
CREATE OR REPLACE FUNCTION fn_atwater_ok(
    p_user_id bigint, p_kcal numeric, p_protein numeric, p_carbs numeric, p_fat numeric
) RETURNS boolean AS $$
    SELECT abs(fn_atwater_delta(p_kcal,p_protein,p_carbs,p_fat))
           <= greatest((SELECT atwater_tol_kcal FROM user_settings WHERE user_id = p_user_id),
                       (SELECT atwater_tol_pct  FROM user_settings WHERE user_id = p_user_id)/100.0 * p_kcal);
$$ LANGUAGE sql STABLE;


-- ATTACHMENT CANDIDATES, now scoped to p_user_id. Proposes; never attaches.
CREATE OR REPLACE FUNCTION fn_find_attachable_meals(
    p_user_id bigint, p_eaten_at timestamptz, p_meal_type_key text
) RETURNS TABLE (meal_id bigint, name text, started_at timestamptz, minutes_apart numeric) AS $$
    SELECT m.id, m.name, vm.started_at,
           round(abs(extract(epoch FROM (vm.started_at - p_eaten_at))/60.0)::numeric,1)
    FROM meals m
    JOIN v_meal_macros vm ON vm.meal_id = m.id
    JOIN meal_types mt ON mt.key = m.meal_type_key
    WHERE m.user_id = p_user_id
      AND m.meal_type_key = p_meal_type_key
      AND m.log_date = fn_log_date(p_eaten_at,
            (SELECT timezone FROM user_settings WHERE user_id = p_user_id),
            (SELECT day_rollover_hour FROM user_settings WHERE user_id = p_user_id))
      AND abs(extract(epoch FROM (vm.started_at - p_eaten_at))) <= mt.dup_window_minutes*60
    ORDER BY abs(extract(epoch FROM (vm.started_at - p_eaten_at)));
$$ LANGUAGE sql STABLE;


-- DUPLICATE CHECK, now scoped to p_user_id via the join to meals - two users
-- logging the identical chicken-and-rice on the same day are NOT duplicates
-- of each other.
CREATE OR REPLACE FUNCTION fn_find_duplicate_log(
    p_user_id bigint, p_hash bytea, p_meal_id bigint, p_eaten_at timestamptz, p_meal_type_key text
) RETURNS TABLE (log_id bigint, meal_id bigint, scope text, minutes_apart numeric) AS $$
    SELECT ml.id, ml.meal_id,
           CASE WHEN ml.meal_id = p_meal_id THEN 'same_meal' ELSE 'other_meal' END,
           round(abs(extract(epoch FROM (ml.eaten_at - p_eaten_at))/60.0)::numeric,1)
    FROM meal_logs ml
    JOIN meals m ON m.id = ml.meal_id
    JOIN meal_types mt ON mt.key = m.meal_type_key
    WHERE m.user_id = p_user_id
      AND ml.content_hash = p_hash AND NOT ml.is_superseded
      AND (ml.meal_id = p_meal_id
           OR (m.meal_type_key = p_meal_type_key
               AND abs(extract(epoch FROM (ml.eaten_at - p_eaten_at))) <= mt.dup_window_minutes*60))
    ORDER BY (ml.meal_id = p_meal_id) DESC,
             abs(extract(epoch FROM (ml.eaten_at - p_eaten_at)));
$$ LANGUAGE sql STABLE;


-- Read-back, now takes p_user_id and filters on it. This is the load-bearing
-- cross-user guard for read access: pass the wrong user for a real meal_id
-- and you get NULL back, not someone else's meal.
CREATE OR REPLACE FUNCTION fn_meal_readback(p_user_id bigint, p_meal_id bigint) RETURNS jsonb AS $$
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
        FROM v_daily_totals WHERE user_id = m.user_id AND log_date = m.log_date),
      'day_quality', (
        SELECT jsonb_build_object('pct_kcal_user_stated',pct_kcal_user_stated,
               'pct_kcal_llm_knowledge',pct_kcal_llm_knowledge,
               'pct_kcal_llm_estimate',pct_kcal_llm_estimate)
        FROM v_daily_data_quality WHERE user_id = m.user_id AND log_date = m.log_date))
    FROM meals m JOIN v_meal_macros vm ON vm.meal_id = m.id
    WHERE m.id = p_meal_id AND m.user_id = p_user_id;
$$ LANGUAGE sql STABLE;


CREATE OR REPLACE FUNCTION fn_log_reject(p_user_id bigint, p_staging_id uuid, p_payload jsonb, p_reason text)
RETURNS void AS $$
    INSERT INTO intake_events (user_id, staging_id, outcome, raw_utterance, item_count,
                               gaps, unconsumed_spans, reject_reason)
    VALUES (p_user_id, p_staging_id,'rejected',p_payload->>'raw_utterance',
            jsonb_array_length(coalesce(p_payload->'items','[]'::jsonb)),
            coalesce(p_payload->'gaps','[]'::jsonb),
            coalesce(p_payload->'unconsumed_spans','[]'::jsonb), p_reason);
$$ LANGUAGE sql VOLATILE;


-- =============================================================================
-- THE GATE. Same payload shape as v5 - meal_id, macros, spans, gaps all
-- unchanged. The ONLY difference is p_user_id as a new first argument, which
-- must come from the caller's authenticated identity, never from the payload.
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_commit_log(
    p_user_id           bigint,
    p_staging_id        uuid,
    p_payload           jsonb,
    p_confirm_duplicate boolean DEFAULT false,
    p_confirm_atwater   boolean DEFAULT false
) RETURNS jsonb AS $$
DECLARE
    v_existing bigint; v_existing_user bigint; v_meal_id bigint; v_log_id bigint; v_item_id bigint;
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
    -- 0. USER MUST EXIST. Fetch settings now; this is also where an unknown
    --    p_user_id gets caught before anything is written.
    SELECT timezone, day_rollover_hour INTO v_tz, v_rollover
      FROM user_settings WHERE user_id = p_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown user_id %', p_user_id;
    END IF;

    -- 1. IDEMPOTENCY. staging_id is globally unique, but a staging_id that
    --    exists and belongs to someone else is a caller bug worth a loud
    --    error rather than a silent wrong-user replay.
    SELECT ml.meal_id, m.user_id INTO v_existing, v_existing_user
      FROM meal_logs ml JOIN meals m ON m.id = ml.meal_id
     WHERE ml.staging_id = p_staging_id;
    IF FOUND THEN
        IF v_existing_user <> p_user_id THEN
            RAISE EXCEPTION 'staging_id % already committed by a different user', p_staging_id;
        END IF;
        RETURN fn_meal_readback(p_user_id, v_existing) || jsonb_build_object('replayed', true);
    END IF;

    -- 2. STRUCTURAL VALIDATION. Unchanged from v5 - reasons collected so the
    --    assistant can ask everything in ONE turn rather than serially.
    IF v_items IS NULL OR jsonb_array_length(v_items) = 0 THEN
        v_reject := 'no items';
    ELSIF jsonb_array_length(v_spans) > 0 THEN
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

    -- 3. Apply the ITEM fraction to grams. Unchanged from v5.
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

    -- 4. ATWATER GATE, now checked against THIS user's tolerance settings.
    IF NOT p_confirm_atwater THEN
        SELECT food_name, kcal,
               round(4*protein + 4*carbs + 9*fat, 1) AS implied,
               round(fn_atwater_delta(kcal,protein,carbs,fat),1) AS delta
          INTO v_bad
          FROM _res
         WHERE atwater_override IS NULL
           AND NOT fn_atwater_ok(p_user_id, kcal, protein, carbs, fat)
         LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION
              'macro check failed for "%": stated % kcal/100g but 4P+4C+9F implies % (off by %). Confirm with the user, then pass confirm_atwater or set atwater_override.',
              v_bad.food_name, v_bad.kcal, v_bad.implied, v_bad.delta;
        END IF;
    END IF;

    -- 5. CONTENT HASH over the resolved ingredient set. Unchanged.
    SELECT digest(string_agg(food_key_calc||':'||round(grams,1)::text,'|'
                             ORDER BY food_key_calc, round(grams,1)),'sha256')
      INTO v_hash
      FROM (SELECT trim(both '_' from lower(regexp_replace(food_name,'[^a-zA-Z0-9]+','_','g')))
                   AS food_key_calc, grams FROM _res) t;

    v_meal_id := (p_payload#>>'{meal,meal_id}')::bigint;

    -- 6. DUPLICATE CHECK, scoped to p_user_id - two users can log the same
    --    thing on the same day without tripping each other's dedup.
    IF NOT p_confirm_duplicate THEN
        SELECT * INTO v_dup FROM fn_find_duplicate_log(
            p_user_id, v_hash, v_meal_id, v_eaten, p_payload#>>'{meal,meal_type_key}') LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION
              'possible duplicate (%): log % in meal %, % minutes away; pass confirm_duplicate to override',
              v_dup.scope, v_dup.log_id, v_dup.meal_id, v_dup.minutes_apart
              USING ERRCODE = 'unique_violation';
        END IF;
    END IF;

    -- 7. ATTACH or CREATE. A non-null meal_id IS the user's confirmation -
    --    AND it must actually belong to p_user_id, or this is either a bug
    --    or an attempt to write into someone else's meal.
    IF v_meal_id IS NOT NULL THEN
        PERFORM 1 FROM meals WHERE id = v_meal_id AND user_id = p_user_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'unknown meal_id % for this user', v_meal_id;
        END IF;
        v_attached := true;
    ELSE
        INSERT INTO meals (user_id, name, name_source, meal_type_key, meal_type_inferred,
                           log_date, tz, derived_from_meal_id)
        VALUES (p_user_id,
                coalesce(p_payload#>>'{meal,name}','Untitled meal'),
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
        RETURN fn_meal_readback(p_user_id, v_meal_id) || jsonb_build_object('replayed', true);
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

    INSERT INTO intake_events (user_id, staging_id, outcome, log_id, meal_id, attached,
                               raw_utterance, item_count, gaps, unconsumed_spans)
    VALUES (p_user_id, p_staging_id,'committed',v_log_id,v_meal_id,v_attached,
            p_payload->>'raw_utterance', jsonb_array_length(v_items), v_gaps, v_spans);

    -- 8. READ BACK.
    RETURN fn_meal_readback(p_user_id, v_meal_id)
           || jsonb_build_object('replayed',false,'log_id',v_log_id,'attached',v_attached);
END $$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION fn_rename_meal(p_user_id bigint, p_meal_id bigint, p_name text) RETURNS jsonb AS $$
BEGIN
    UPDATE meals SET name = p_name, name_source = 'user'
     WHERE id = p_meal_id AND user_id = p_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown meal_id % for this user', p_meal_id;
    END IF;
    RETURN fn_meal_readback(p_user_id, p_meal_id);
END $$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION fn_supersede_log(
    p_user_id bigint, p_old_log_id bigint, p_staging_id uuid, p_payload jsonb
) RETURNS jsonb AS $$
DECLARE v_res jsonb; v_new bigint; v_meal bigint;
BEGIN
    -- The log being superseded must actually belong to this user, or a stray
    -- log_id would let one user overwrite another user's history.
    PERFORM 1 FROM meal_logs ml JOIN meals m ON m.id = ml.meal_id
      WHERE ml.id = p_old_log_id AND m.user_id = p_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown log_id % for this user', p_old_log_id;
    END IF;

    v_res  := fn_commit_log(p_user_id, p_staging_id, p_payload, true, true);  -- corrections bypass both gates
    v_new  := (v_res->>'log_id')::bigint;
    v_meal := (v_res->>'meal_id')::bigint;
    UPDATE meal_logs SET is_superseded = true WHERE id = p_old_log_id;
    UPDATE meal_logs SET supersedes_log_id = p_old_log_id WHERE id = v_new;
    INSERT INTO intake_events (user_id, staging_id, outcome, log_id, meal_id, raw_utterance)
    VALUES (p_user_id, p_staging_id,'superseded',v_new,v_meal,p_payload->>'raw_utterance');
    RETURN fn_meal_readback(p_user_id, v_meal) || jsonb_build_object('supersedes_log_id', p_old_log_id);
END $$ LANGUAGE plpgsql;
