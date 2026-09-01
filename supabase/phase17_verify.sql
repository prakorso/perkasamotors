-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 17 VERIFICATION  (run AFTER phase17_partner_policy.sql)
-- Creates temp Perkasa units, exercises the policy engine + orchestration, checks
-- the frozen applied %, proves a later policy edit does NOT change a settled unit,
-- confirms the loss case ignores policy, verifies legacy P&L PRE=POST, then deletes
-- all test rows. Paste the final result table.
-- ══════════════════════════════════════════════════════════════════════════
create temp table _p17(step text, result text) on commit drop;

-- PRE (legacy invariants must be identical POST)
insert into _p17 values ('PRE v_pnl realized', (select realized_unit_profit::text from v_pnl));
insert into _p17 values ('PRE retained total', (select total_retained::text from v_retained_profit));

-- Engine boundary checks (pure lookup, no writes)
insert into _p17 values ('ENGINE Mobil 30% 75d bracket', (fn_partner_policy_rate('Mobil',30,75)->>'bracket_label'));
insert into _p17 values ('ENGINE Mobil 30% 75d share=17', (fn_partner_policy_rate('Mobil',30,75)->>'share_pct'));
insert into _p17 values ('ENGINE 40% → 40-50% tier', (fn_partner_policy_rate('Mobil',40,75)->>'bracket_label'));
insert into _p17 values ('ENGINE 49.99% → 40-50% tier', (fn_partner_policy_rate('Mobil',49.99,75)->>'bracket_label'));
insert into _p17 values ('ENGINE 50% → >50% highest tier', (fn_partner_policy_rate('Mobil',50,75)->>'bracket_label'));
insert into _p17 values ('ENGINE 39.99% → 30-40% tier', (fn_partner_policy_rate('Mobil',39.99,75)->>'bracket_label'));

do $$
declare up bigint; ul bigint; j json; snap_pct numeric; snap_fee numeric; edited_pct numeric;
begin
  -- U_PROFIT: Mobil, base 100M, Perkasa 70M + Partner 30M (exposure 30%),
  -- settle at 150M with holding ~75 days (61-90 tier) → policy 17% of true profit 50M = 8.5M
  insert into units(nama,jenis,status,tgl,funding_model)
    values('__P17_PROFIT__','Mobil','aktif', current_date - 75, 'perkasa') returning id into up;
  insert into unit_cost_entries(unit_id,category,amount) values(up,'Purchase',100000000);
  insert into unit_funding(unit_id,source,amount) values(up,'perkasa',70000000);
  insert into unit_funding(unit_id,source,partner_name,amount) values(up,'partner','Reivan',30000000);

  j := pm_unit_settle_policy('__internal__', up, 150000000, 0, current_date);
  insert into _p17 values('SETTLE ok', (j->>'ok'));
  insert into _p17 values('SETTLE policy bucket', ((j->'policy')->>'bracket_label')||' · '||((j->'policy')->>'holding_label'));
  insert into _p17 values('SETTLE applied % (17)', (j->>'applied_partner_profit_pct'));

  select applied_partner_profit_pct, partner_fee into snap_pct, snap_fee
    from unit_settlement where unit_id=up and status='settled';
  insert into _p17 values('SNAPSHOT frozen applied % (17)', snap_pct::text);
  insert into _p17 values('SNAPSHOT partner_fee (8500000)', snap_fee::text);

  -- EDIT the policy AFTER settlement; settled snapshot must NOT change.
  perform pm_partner_policy_save('__internal__',
    '[{"vehicle_type":"Mobil","bracket_label":"30-40%","holding_label":"61-90","share_pct":18}]'::jsonb);
  select applied_partner_profit_pct into edited_pct from unit_settlement where unit_id=up and status='settled';
  insert into _p17 values('FREEZE snapshot unchanged after policy edit (17)', edited_pct::text);
  insert into _p17 values('FREEZE new lookup reflects edit (18)', (fn_partner_policy_rate('Mobil',30,75)->>'share_pct'));
  -- restore policy value
  perform pm_partner_policy_save('__internal__',
    '[{"vehicle_type":"Mobil","bracket_label":"30-40%","holding_label":"61-90","share_pct":17}]'::jsonb);

  -- U_LOSS: Motor, base 100M, Perkasa 70M + Partner 30M, settle at 90M (loss 10M).
  -- Loss ignores policy; partner shares downside by funding/loss exposure (30%).
  insert into units(nama,jenis,status,tgl,funding_model)
    values('__P17_LOSS__','Motor','aktif', current_date - 40, 'perkasa') returning id into ul;
  insert into unit_cost_entries(unit_id,category,amount) values(ul,'Purchase',100000000);
  insert into unit_funding(unit_id,source,amount) values(ul,'perkasa',70000000);
  insert into unit_funding(unit_id,source,partner_name,amount) values(ul,'partner','Reivan',30000000);
  j := pm_unit_settle_policy('__internal__', ul, 90000000, 0, current_date);
  insert into _p17 values('LOSS settle ok (policy not required)', (j->>'ok'));
  insert into _p17 values('LOSS applied % null (policy irrelevant)', coalesce(j->>'applied_partner_profit_pct','null'));
  insert into _p17 values('LOSS partner_loss (3000000 = 30% of 10M)',
    (select partner_loss::text from unit_settlement where unit_id=ul and status='settled'));

  -- CLEANUP
  delete from units where nama like '__P17_%';
  insert into _p17 values('CLEANUP units remain (0)', (select count(*)::text from units where nama like '__P17_%'));
end $$;

-- POST legacy invariants (must equal PRE)
insert into _p17 values ('POST v_pnl realized', (select realized_unit_profit::text from v_pnl));
insert into _p17 values ('POST retained total', (select total_retained::text from v_retained_profit));

select * from _p17;
