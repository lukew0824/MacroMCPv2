-- MacroMCP v5 tests. Run once against a freshly loaded schema.sql.
\set ON_ERROR_STOP off
\pset format aligned

\echo '=== T1: normal commit. Model supplies per-100g densities; server multiplies ==='
SELECT jsonb_pretty(fn_commit_log(fn_new_staging_id(), jsonb_build_object(
 'raw_utterance','7oz chicken and a cup of rice','eaten_at','2026-08-19T19:40:00-04:00',
 'meal', jsonb_build_object('name','chicken and rice','name_source','derived',
                            'meal_type_key','dinner','meal_type_inferred',true),
 'items', jsonb_build_array(
  jsonb_build_object('ordinal',1,'name','chicken','raw_text','7oz chicken','span',jsonb_build_array(0,11),
   'ingredients',jsonb_build_array(jsonb_build_object('ordinal',1,'food_name','chicken breast, cooked',
     'grams',198.4,'kcal_per_100g',165,'protein_per_100g',31,'carbs_per_100g',0,'fat_per_100g',3.6,
     'quantity',jsonb_build_object('num',7,'den',1),'unit_label','oz','unit_class','mass',
     'macro_source','llm_knowledge','resolution_confidence','user_confirmed'))),
  jsonb_build_object('ordinal',2,'name','rice','raw_text','a cup of rice','span',jsonb_build_array(16,29),
   'ingredients',jsonb_build_array(jsonb_build_object('ordinal',1,'food_name','white rice, cooked',
     'grams',158,'kcal_per_100g',130,'protein_per_100g',2.7,'carbs_per_100g',28,'fat_per_100g',0.3,
     'quantity',jsonb_build_object('num',1,'den',1),'unit_label','cup','unit_class','standard_volume',
     'macro_source','llm_knowledge','resolution_confidence','user_confirmed'))))))
 #> '{logs,0,items}') AS committed_items;
\echo '(expected: chicken 327.4 kcal, rice 205.4 kcal - server computed both)'

\echo '\n=== T2: ATWATER gate catches an incoherent estimate ==='
SELECT fn_commit_log(fn_new_staging_id(), jsonb_build_object(
 'raw_utterance','a protein bar','eaten_at','2026-08-19T15:00:00-04:00',
 'meal', jsonb_build_object('name','bar','meal_type_key','snack'),
 'items', jsonb_build_array(jsonb_build_object('ordinal',1,'name','bar',
  'raw_text','a protein bar','span',jsonb_build_array(0,13),
  'ingredients',jsonb_build_array(jsonb_build_object('ordinal',1,'food_name','protein bar',
    'grams',60,'kcal_per_100g',700,'protein_per_100g',30,'carbs_per_100g',40,'fat_per_100g',10,
    'macro_source','llm_estimate','resolution_confidence','estimated'))))));
\echo '(expected: ERROR - 700 stated but 4P+4C+9F implies 370)'

\echo '\n=== T3: same payload passes with confirm_atwater ==='
SELECT (fn_commit_log(fn_new_staging_id(), jsonb_build_object(
 'raw_utterance','a protein bar','eaten_at','2026-08-19T15:00:00-04:00',
 'meal', jsonb_build_object('name','bar','meal_type_key','snack'),
 'items', jsonb_build_array(jsonb_build_object('ordinal',1,'name','bar',
  'raw_text','a protein bar','span',jsonb_build_array(0,13),
  'ingredients',jsonb_build_array(jsonb_build_object('ordinal',1,'food_name','protein bar',
    'grams',60,'kcal_per_100g',700,'protein_per_100g',30,'carbs_per_100g',40,'fat_per_100g',10,
    'macro_source','llm_estimate','resolution_confidence','estimated'))))),
 false, true) ->> 'meal_id') AS committed_with_confirm;

\echo '\n=== T4: alcohol legitimately breaks Atwater; override records why ==='
SELECT (fn_commit_log(fn_new_staging_id(), jsonb_build_object(
 'raw_utterance','a glass of red wine','eaten_at','2026-08-19T20:30:00-04:00',
 'meal', jsonb_build_object('name','wine','meal_type_key','dinner'),
 'items', jsonb_build_array(jsonb_build_object('ordinal',1,'name','wine',
  'raw_text','a glass of red wine','span',jsonb_build_array(0,19),
  'ingredients',jsonb_build_array(jsonb_build_object('ordinal',1,'food_name','red wine',
    'grams',148,'kcal_per_100g',85,'protein_per_100g',0.1,'carbs_per_100g',2.6,'fat_per_100g',0,
    'atwater_override','alcohol contributes 7 kcal/g',
    'macro_source','llm_knowledge','resolution_confidence','estimated'))))))
 ->> 'meal_id') AS wine_ok;
SELECT food_name, kcal_per_100g, atwater_kcal, atwater_override FROM v_atwater_overrides;

\echo '\n=== T5: a self-consistent but WRONG estimate passes. Atwater cannot see it ==='
SELECT (fn_commit_log(fn_new_staging_id(), jsonb_build_object(
 'raw_utterance','a bagel','eaten_at','2026-08-19T08:00:00-04:00',
 'meal', jsonb_build_object('name','bagel','meal_type_key','breakfast'),
 'items', jsonb_build_array(jsonb_build_object('ordinal',1,'name','bagel',
  'raw_text','a bagel','span',jsonb_build_array(0,7),
  'ingredients',jsonb_build_array(jsonb_build_object('ordinal',1,'food_name','bagel',
    'grams',100,'kcal_per_100g',100,'protein_per_100g',5,'carbs_per_100g',15,'fat_per_100g',2,
    'macro_source','llm_estimate','resolution_confidence','estimated'))))))
 IS NOT NULL) AS passed;
\echo '(a real bagel is ~270 kcal/100g. Internally coherent, so it commits. This is the ceiling of the check.)'

\echo '\n=== T6: missing macros are NOT storable ==='
SELECT fn_commit_log(fn_new_staging_id(), jsonb_build_object(
 'raw_utterance','grandmas sauce','eaten_at','2026-08-19T12:00:00-04:00',
 'meal', jsonb_build_object('name','sauce','meal_type_key','lunch'),
 'items', jsonb_build_array(jsonb_build_object('ordinal',1,'name','sauce',
  'raw_text','grandmas sauce','span',jsonb_build_array(0,14),
  'ingredients',jsonb_build_array(jsonb_build_object('ordinal',1,'food_name','grandmas sauce',
    'grams',240,'macro_source','llm_estimate','resolution_confidence','estimated'))))));
\echo '(expected: ERROR - all four per-100g macros required)'

\echo '\n=== T7: physically impossible densities are rejected outright ==='
SELECT fn_commit_log(fn_new_staging_id(), jsonb_build_object(
 'raw_utterance','mystery','eaten_at','2026-08-19T12:00:00-04:00',
 'meal', jsonb_build_object('name','mystery','meal_type_key','lunch'),
 'items', jsonb_build_array(jsonb_build_object('ordinal',1,'name','mystery',
  'raw_text','mystery','span',jsonb_build_array(0,7),
  'ingredients',jsonb_build_array(jsonb_build_object('ordinal',1,'food_name','mystery',
    'grams',100,'kcal_per_100g',400,'protein_per_100g',60,'carbs_per_100g',60,'fat_per_100g',30,
    'macro_source','llm_estimate','resolution_confidence','estimated'))))), false, true);
\echo '(expected: ERROR - P+C+F = 150g per 100g is impossible)'

\echo '\n=== T8: item-level fraction still scales grams only ==='
SELECT jsonb_pretty(fn_commit_log(fn_new_staging_id(), jsonb_build_object(
 'raw_utterance','half a cheeseburger and all the fries','eaten_at','2026-08-20T18:00:00-04:00',
 'meal', jsonb_build_object('name','burger and fries','meal_type_key','dinner'),
 'gaps', jsonb_build_array(jsonb_build_object('kind','composite','item_ordinal',1,'status','answered','is_material',true)),
 'items', jsonb_build_array(
  jsonb_build_object('ordinal',1,'name','cheeseburger','raw_text','half a cheeseburger','span',jsonb_build_array(0,19),
   'portion_fraction',jsonb_build_object('num',1,'den',2),
   'ingredients',jsonb_build_array(
     jsonb_build_object('ordinal',1,'food_name','hamburger bun','grams',60,
       'kcal_per_100g',279,'protein_per_100g',9.5,'carbs_per_100g',50,'fat_per_100g',4.2,
       'macro_source','llm_knowledge','resolution_confidence','user_confirmed'),
     jsonb_build_object('ordinal',2,'food_name','beef patty, cooked','grams',113,
       'kcal_per_100g',250,'protein_per_100g',26,'carbs_per_100g',0,'fat_per_100g',16,
       'macro_source','llm_knowledge','resolution_confidence','user_confirmed'))),
  jsonb_build_object('ordinal',2,'name','fries','raw_text','all the fries','span',jsonb_build_array(24,37),
   'ingredients',jsonb_build_array(jsonb_build_object('ordinal',1,'food_name','french fries',
     'grams',117,'kcal_per_100g',312,'protein_per_100g',3.4,'carbs_per_100g',41,'fat_per_100g',15,
     'macro_source','llm_knowledge','resolution_confidence','estimated'))))))
 #> '{logs,0,items}') AS half_and_whole;
\echo '(expected: bun 30g and patty 56.5g; fries stay 117g)'

\echo '\n=== T9: composite guard still applies with no reference DB ==='
SELECT fn_commit_log(fn_new_staging_id(), jsonb_build_object(
 'raw_utterance','a burrito','eaten_at','2026-08-20T13:00:00-04:00',
 'meal', jsonb_build_object('name','burrito','meal_type_key','lunch'),
 'items', jsonb_build_array(jsonb_build_object('ordinal',1,'name','burrito',
  'raw_text','a burrito','span',jsonb_build_array(0,9),
  'ingredients',jsonb_build_array(
    jsonb_build_object('ordinal',1,'food_name','flour tortilla','grams',70,
      'kcal_per_100g',310,'protein_per_100g',8,'carbs_per_100g',52,'fat_per_100g',7,
      'macro_source','llm_knowledge','resolution_confidence','estimated'),
    jsonb_build_object('ordinal',2,'food_name','sour cream','grams',30,
      'kcal_per_100g',193,'protein_per_100g',2.4,'carbs_per_100g',4.6,'fat_per_100g',19,
      'macro_source','llm_estimate','resolution_confidence','estimated')))))); 
\echo '(expected: ERROR - the sour cream nobody mentioned is exactly what this guards)'

\echo '\n=== T10: trend grouping via the generated slug ==='
SELECT food_key, example_name, log_date, round(grams,1) AS grams, round(kcal,1) AS kcal
  FROM v_food_trends ORDER BY log_date, food_key;

\echo '\n=== T11: provenance mix, the only honesty signal left ==='
SELECT log_date, ingredients, pct_kcal_llm_knowledge, pct_kcal_llm_estimate,
       pct_kcal_user_stated FROM v_daily_data_quality ORDER BY log_date;

\echo '\n=== T12: day totals ==='
SELECT log_date, round(kcal,1) AS kcal, round(protein_g,1) AS protein FROM v_daily_totals ORDER BY 1;

\echo '\n=== T13: append-only + idempotency still hold ==='
UPDATE meal_logs SET eaten_at = now() WHERE id = 1;
DELETE FROM item_ingredients WHERE id = 1;
SELECT count(*) AS logs_before FROM meal_logs;
