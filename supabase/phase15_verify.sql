-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 15 (D5) LIVE VERIFICATION + CONTROLLED TESTS + CLEANUP
-- Run AFTER phase15_sale_settlement.sql. Creates temporary '__D5_TEST__*' perkasa
-- units, exercises profit/loss/no-partner/selling-cost/immutable/reversal, checks
-- zero reserve posting + legacy PRE/POST, then deletes ALL test rows. Returns one
-- results table — paste it back.
-- ══════════════════════════════════════════════════════════════════════════
create temp table _d5(step text, result text) on commit drop;

-- PRE baselines
insert into _d5 values ('PRE v_pnl realized',   (select realized_unit_profit::text from v_pnl));
insert into _d5 values ('PRE v_pnl revenue',    (select revenue::text from v_pnl));
insert into _d5 values ('PRE reserve_balance',  (select reserve_balance::text from v_reserve_summary));
insert into _d5 values ('PRE reserve_ledger rows',(select count(*)::text from reserve_ledger));
insert into _d5 values ('PRE units total',      (select count(*)::text from units));
insert into _d5 values ('PRE units legacy',     (select count(*)::text from units where funding_model='legacy'));

-- object existence
insert into _d5 values ('obj unit_settlement',        (to_regclass('public.unit_settlement') is not null)::text);
insert into _d5 values ('obj v_unit_settlement',      (to_regclass('public.v_unit_settlement') is not null)::text);
insert into _d5 values ('obj v_retained_profit',      (to_regclass('public.v_retained_profit') is not null)::text);
insert into _d5 values ('rpc pm_unit_settle_v2',      (to_regproc('public.pm_unit_settle_v2') is not null)::text);
insert into _d5 values ('rpc pm_unit_settle_reverse', (to_regproc('public.pm_unit_settle_reverse') is not null)::text);
insert into _d5 values ('sec unit_settlement anon INSERT (expect false)',
  (exists(select 1 from information_schema.role_table_grants where table_schema='public' and table_name='unit_settlement' and grantee='anon' and privilege_type='INSERT'))::text);

do $$
declare u1 bigint; u2 bigint; u3 bigint; u4 bigint; j jsonb; rl_pre int;
begin
  select count(*) into rl_pre from reserve_ledger;

  -- helper inline: create perkasa unit + cost + funding
  -- 1) PROFIT: base100, perkasa70+partner30(Reivan share 20%), sale125/0
  insert into units(nama,jenis,status,tgl,funding_model) values('__D5_TEST_PROFIT__','Mobil','aktif',current_date,'perkasa') returning id into u1;
  insert into unit_cost_entries(unit_id,category,amount) values(u1,'Purchase',100000000);
  insert into unit_funding(unit_id,source,amount) values(u1,'perkasa',70000000);
  insert into unit_funding(unit_id,source,partner_name,amount) values(u1,'partner','Reivan',30000000);
  insert into unit_partner_agreement(unit_id,partner_name,agreement_type,profit_share_pct) values(u1,'Reivan','profit_share_pct',20);
  j := pm_unit_settle_v2('__internal__',u1,125000000,0,current_date);
  insert into _d5 values('PROFIT true_profit (25000000)', j->>'true_unit_profit');
  insert into _d5 values('PROFIT partner_fee (5000000)',  j->>'partner_fee');
  insert into _d5 values('PROFIT perkasa_retained (20000000)', j->>'perkasa_retained_profit');
  insert into _d5 values('PROFIT total_capital_return (100000000)', j->>'total_capital_return');
  insert into _d5 values('PROFIT is_loss (false)', j->>'is_loss');

  -- 2) LOSS with partner: base100, 70/30, sale90/0 → loss10, perkasa7/partner3, returns63+27
  insert into units(nama,jenis,status,tgl,funding_model) values('__D5_TEST_LOSS__','Mobil','aktif',current_date,'perkasa') returning id into u2;
  insert into unit_cost_entries(unit_id,category,amount) values(u2,'Purchase',100000000);
  insert into unit_funding(unit_id,source,amount) values(u2,'perkasa',70000000);
  insert into unit_funding(unit_id,source,partner_name,amount) values(u2,'partner','Reivan',30000000);
  j := pm_unit_settle_v2('__internal__',u2,90000000,0,current_date);
  insert into _d5 values('LOSS total_loss (10000000)', j->>'total_loss');
  insert into _d5 values('LOSS perkasa_retained (-7000000)', j->>'perkasa_retained_profit');
  insert into _d5 values('LOSS cap_return_perkasa (63000000)', j->>'capital_return_perkasa');
  insert into _d5 values('LOSS cap_return_partner (27000000)', j->>'capital_return_partner');
  insert into _d5 values('LOSS partner_fee (0)', j->>'partner_fee');
  insert into _d5 values('LOSS partner_loss row (3000000)', (select partner_loss::text from v_unit_settlement where unit_id=u2));

  -- 3) NO PARTNER: base50, perkasa50, sale60/0 → true10, retained10, cr 50/0
  insert into units(nama,jenis,status,tgl,funding_model) values('__D5_TEST_NOPARTNER__','Motor','aktif',current_date,'perkasa') returning id into u3;
  insert into unit_cost_entries(unit_id,category,amount) values(u3,'Purchase',50000000);
  insert into unit_funding(unit_id,source,amount) values(u3,'perkasa',50000000);
  j := pm_unit_settle_v2('__internal__',u3,60000000,0,current_date);
  insert into _d5 values('NOPARTNER true_profit (10000000)', j->>'true_unit_profit');
  insert into _d5 values('NOPARTNER retained (10000000)', j->>'perkasa_retained_profit');
  insert into _d5 values('NOPARTNER cap_return_partner (0)', j->>'capital_return_partner');

  -- 4) SELLING COST: base80, perkasa80, sale100 cost5 → net95, true15
  insert into units(nama,jenis,status,tgl,funding_model) values('__D5_TEST_SELLCOST__','Mobil','aktif',current_date,'perkasa') returning id into u4;
  insert into unit_cost_entries(unit_id,category,amount) values(u4,'Purchase',80000000);
  insert into unit_funding(unit_id,source,amount) values(u4,'perkasa',80000000);
  j := pm_unit_settle_v2('__internal__',u4,100000000,5000000,current_date);
  insert into _d5 values('SELLCOST net_proceeds (95000000)', j->>'net_proceeds');
  insert into _d5 values('SELLCOST true_profit (15000000)', j->>'true_unit_profit');

  -- 7) ZERO reserve posting: reserve_ledger unchanged by all settlements
  insert into _d5 values('ZERO reserve rows added (0)', ((select count(*) from reserve_ledger) - rl_pre)::text);

  -- 8) INDEPENDENCE: profit unit used agreement 20% (not funding 30%)
  insert into _d5 values('INDEP fee used share%20 not funding%30 (5000000)', (select partner_fee::text from v_unit_settlement where unit_id=u1));

  -- 9) IMMUTABLE: add cost after settle → snapshot base stays 100m though v_unit_cost changes
  insert into unit_cost_entries(unit_id,category,amount) values(u1,'Repair',10000000);
  insert into _d5 values('IMMUTABLE snapshot base (100000000)', (select base_unit_cost_snap::text from v_unit_settlement where unit_id=u1));
  insert into _d5 values('IMMUTABLE v_unit_cost now (110000000)', (select base_unit_cost::text from v_unit_cost where unit_id=u1));

  -- 10) REVERSAL: reverse profit unit → status reversed + unit active; re-settle allowed
  j := pm_unit_settle_reverse('__internal__',u1,'koreksi harga');
  insert into _d5 values('REVERSE ok', j->>'ok');
  insert into _d5 values('REVERSE unit active again (aktif)', (select status from units where id=u1));
  insert into _d5 values('REVERSE snapshot reversed', (select status from unit_settlement where unit_id=u1 order by id desc limit 1));
  j := pm_unit_settle_v2('__internal__',u1,125000000,0,current_date);  -- re-settle after fix
  insert into _d5 values('REVERSE re-settle ok', j->>'ok');

  -- CLEANUP
  delete from units where nama like '__D5_TEST_%';
  insert into _d5 values('CLEANUP settlements remain (0)', (select count(*)::text from unit_settlement s join units u on u.id=s.unit_id where u.nama like '__D5_TEST_%'));
  insert into _d5 values('CLEANUP test units remain (0)', (select count(*)::text from units where nama like '__D5_TEST_%'));
end $$;

-- 11) POST legacy reconciliation (must equal PRE)
insert into _d5 values ('POST v_pnl realized',    (select realized_unit_profit::text from v_pnl));
insert into _d5 values ('POST v_pnl revenue',     (select revenue::text from v_pnl));
insert into _d5 values ('POST reserve_balance',   (select reserve_balance::text from v_reserve_summary));
insert into _d5 values ('POST reserve_ledger rows',(select count(*)::text from reserve_ledger));
insert into _d5 values ('POST units total',       (select count(*)::text from units));

select * from _d5;
