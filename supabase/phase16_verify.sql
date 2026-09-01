-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 16 (D6) LIVE VERIFICATION + CONTROLLED TESTS + CLEANUP
-- Run AFTER phase16_reporting.sql (and phase13–15). Creates temporary perkasa
-- units (1 active-deployed, 1 profit-settled this month, 1 loss-settled last
-- month), checks unified P&L / period vs as-of / layer separation / routing /
-- filters, verifies legacy PRE=POST, then deletes all test rows. Paste result.
-- ══════════════════════════════════════════════════════════════════════════
create temp table _d6(step text, result text) on commit drop;

-- PRE
insert into _d6 values ('PRE v_pnl realized',   (select realized_unit_profit::text from v_pnl));
insert into _d6 values ('PRE v_pnl revenue',    (select revenue::text from v_pnl));
insert into _d6 values ('PRE reserve_balance',  (select reserve_balance::text from v_reserve_summary));
insert into _d6 values ('PRE reserve_ledger rows',(select count(*)::text from reserve_ledger));
insert into _d6 values ('PRE retained total',   (select total_retained::text from v_retained_profit));

-- objects
insert into _d6 values ('obj v_company_capital', (to_regclass('public.v_company_capital') is not null)::text);
insert into _d6 values ('obj v_financing',       (to_regclass('public.v_financing') is not null)::text);
insert into _d6 values ('obj v_cash_position',   (to_regclass('public.v_cash_position') is not null)::text);
insert into _d6 values ('obj v_unit_pnl_unified',(to_regclass('public.v_unit_pnl_unified') is not null)::text);
insert into _d6 values ('fn fn_pnl',             (to_regproc('public.fn_pnl') is not null)::text);
insert into _d6 values ('fn fn_position',        (to_regproc('public.fn_position') is not null)::text);

do $$
declare ua bigint; up bigint; ul bigint; j json; d_this date; d_last date;
  act1 numeric; act2 numeric; dep1 numeric; rl_pre int;
begin
  d_this := date_trunc('month',current_date)::date + 5;               -- this month
  d_last := (date_trunc('month',current_date) - interval '1 month')::date + 5; -- last month
  select count(*) into rl_pre from reserve_ledger;

  -- U_ACTIVE: deployed, not settled (perkasa 40m)
  insert into units(nama,jenis,status,tgl,funding_model) values('__D6_ACTIVE__','Mobil','aktif',current_date,'perkasa') returning id into ua;
  insert into unit_cost_entries(unit_id,category,amount) values(ua,'Purchase',40000000);
  insert into unit_funding(unit_id,source,amount) values(ua,'perkasa',40000000);

  select actual_cash, deployed_capital into act1, dep1 from v_cash_position;
  insert into _d6 values('SEP deployed includes active (>=40000000)', dep1::text);

  -- Partner funding on active unit must NOT change actual cash or deployed
  insert into unit_funding(unit_id,source,partner_name,amount) values(ua,'partner','Reivan',10000000);
  select actual_cash, deployed_capital into act2, dep1 from v_cash_position;
  insert into _d6 values('SEP partner does NOT change actual_cash (same)', (act1=act2)::text);
  insert into _d6 values('SEP partner does NOT change deployed (40000000)', dep1::text);

  -- U_PROFIT: settle this month → retained 20m
  insert into units(nama,jenis,status,tgl,funding_model) values('__D6_PROFIT__','Mobil','aktif',current_date,'perkasa') returning id into up;
  insert into unit_cost_entries(unit_id,category,amount) values(up,'Purchase',100000000);
  insert into unit_funding(unit_id,source,amount) values(up,'perkasa',70000000);
  insert into unit_funding(unit_id,source,partner_name,amount) values(up,'partner','Reivan',30000000);
  insert into unit_partner_agreement(unit_id,partner_name,agreement_type,profit_share_pct) values(up,'Reivan','profit_share_pct',20);
  perform pm_unit_settle_v2('__internal__',up,125000000,0,d_this);

  -- U_LOSS: settle last month → retained -7m
  insert into units(nama,jenis,status,tgl,funding_model) values('__D6_LOSS__','Mobil','aktif',current_date,'perkasa') returning id into ul;
  insert into unit_cost_entries(unit_id,category,amount) values(ul,'Purchase',100000000);
  insert into unit_funding(unit_id,source,amount) values(ul,'perkasa',70000000);
  insert into unit_funding(unit_id,source,partner_name,amount) values(ul,'partner','Reivan',30000000);
  perform pm_unit_settle_v2('__internal__',ul,90000000,0,d_last);

  -- (1) Unified all-time = legacy+future = v_retained_profit.total
  j := fn_pnl('1900-01-01', current_date);
  insert into _d6 values('UNIFIED fn_pnl unit_retained == retained_total',
    (( (j->>'unit_retained')::numeric ) = (select total_retained from v_retained_profit))::text);
  insert into _d6 values('UNIFIED = legacy + future',
    (( (j->>'unit_retained')::numeric ) = ((j->>'legacy_retained')::numeric + (j->>'future_retained')::numeric))::text);

  -- (14) Filters: this-month vs last-month vs year return DIFFERENT future slices
  insert into _d6 values('FILTER this-month future_retained (20000000)',
    (fn_pnl(date_trunc('month',current_date)::date, (date_trunc('month',current_date)+interval '1 month -1 day')::date)->>'future_retained'));
  insert into _d6 values('FILTER last-month future_retained (-7000000)',
    (fn_pnl((date_trunc('month',current_date)-interval '1 month')::date, (date_trunc('month',current_date)-interval '1 day')::date)->>'future_retained'));
  insert into _d6 values('FILTER year future_retained (13000000)',
    (fn_pnl(date_trunc('year',current_date)::date, (date_trunc('year',current_date)+interval '1 year -1 day')::date)->>'future_retained'));

  -- (7) capital return not in period profit: this-month unit_retained = 20m (retained), not 125m/100m
  insert into _d6 values('ROUTE period profit excludes capital return (20000000)',
    (fn_pnl(date_trunc('month',current_date)::date, (date_trunc('month',current_date)+interval '1 month -1 day')::date)->>'unit_retained'));

  -- (13) partner loss not double-subtracted: last-month future_retained = -7m (not -10m)
  insert into _d6 values('ROUTE partner loss not double (-7000000)',
    (fn_pnl((date_trunc('month',current_date)-interval '1 month')::date, (date_trunc('month',current_date)-interval '1 day')::date)->>'future_retained'));

  -- (3) actual ≠ available ≠ deployed
  insert into _d6 values('SEP actual<>available', ((select actual_cash from v_cash_position) <> (select available_cash from v_cash_position))::text);
  insert into _d6 values('SEP deployed distinct (>0)', ((select deployed_capital from v_cash_position) > 0)::text);

  -- (12) zero reserve posting from settlements
  insert into _d6 values('ZERO reserve rows added (0)', ((select count(*) from reserve_ledger) - rl_pre)::text);

  -- (15) as-of not a period sum: fn_position returns balances (retained = total, not a range)
  insert into _d6 values('ASOF retained == total (point-in-time)',
    ((fn_position(current_date)->>'retained_profit')::numeric = (select total_retained from v_retained_profit))::text);

  -- (10) interest-only in P&L (no debt principal); here no test debt so 0
  insert into _d6 values('ROUTE fn_pnl has interest key (0 here)',
    coalesce(fn_pnl('1900-01-01',current_date)->>'interest','x'));

  -- CLEANUP
  delete from units where nama like '__D6_%';
  insert into _d6 values('CLEANUP units remain (0)', (select count(*)::text from units where nama like '__D6_%'));
  insert into _d6 values('CLEANUP settlements remain (0)', (select count(*)::text from unit_settlement s join units u on u.id=s.unit_id where u.nama like '__D6_%'));
end $$;

-- POST legacy reconciliation (must equal PRE)
insert into _d6 values ('POST v_pnl realized',   (select realized_unit_profit::text from v_pnl));
insert into _d6 values ('POST v_pnl revenue',    (select revenue::text from v_pnl));
insert into _d6 values ('POST reserve_balance',  (select reserve_balance::text from v_reserve_summary));
insert into _d6 values ('POST reserve_ledger rows',(select count(*)::text from reserve_ledger));
insert into _d6 values ('POST retained total',   (select total_retained::text from v_retained_profit));

select * from _d6;
