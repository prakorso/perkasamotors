-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 13 (D3) LIVE VERIFICATION + CONTROLLED TEST + CLEANUP
-- Run AFTER phase13_unit_cost_ledger.sql. Read-mostly: it creates a temporary
-- '__D3_TEST__' unit, proves Base Unit Cost = Rp82jt, checks constraints, then
-- DELETES the temp unit (cascade) so production is left spotless. Returns one
-- results table — paste it back.
-- ══════════════════════════════════════════════════════════════════════════
create temp table _d3(step text, result text) on commit drop;

-- 1) PRE snapshot (historical baselines)
insert into _d3 values ('PRE units total',        (select count(*)::text from units));
insert into _d3 values ('PRE units legacy',       (select count(*)::text from units where funding_model='legacy'));
insert into _d3 values ('PRE units non-legacy',   (select count(*)::text from units where funding_model<>'legacy'));
insert into _d3 values ('PRE v_pnl realized',     (select realized_unit_profit::text from v_pnl));
insert into _d3 values ('PRE v_pnl revenue',      (select revenue::text from v_pnl));
insert into _d3 values ('PRE reserve_balance',    (select reserve_balance::text from v_reserve_summary));
insert into _d3 values ('PRE v_unit_economics n', (select count(*)::text from v_unit_economics));

-- 2) Object existence
insert into _d3 values ('obj unit_cost_entries',  (to_regclass('public.unit_cost_entries') is not null)::text);
insert into _d3 values ('obj v_unit_cost',        (to_regclass('public.v_unit_cost') is not null)::text);
insert into _d3 values ('col units.funding_model',(exists(select 1 from information_schema.columns where table_schema='public' and table_name='units' and column_name='funding_model'))::text);
insert into _d3 values ('rls unit_cost_entries',  (exists(select 1 from pg_policies where schemaname='public' and tablename='unit_cost_entries'))::text);

-- 3) Controlled Rp82jt test on a TEMP 'perkasa' unit, + constraint checks, + routing, + cleanup
do $$
declare v_id bigint; v_legacy bigint;
begin
  insert into units(nama,jenis,status,tgl,funding_model)
    values('__D3_TEST__','Mobil','aktif',current_date,'perkasa') returning id into v_id;
  insert into unit_cost_entries(unit_id,category,description,amount) values
    (v_id,'Purchase','base',75000000),(v_id,'Service','',2000000),(v_id,'Repair','',3000000),
    (v_id,'Transport','',1000000),(v_id,'Document/Tax','',500000),(v_id,'Other','',500000);

  insert into _d3 values ('TEST base_unit_cost (expect 82000000)',
    (select base_unit_cost::text from v_unit_cost where unit_id=v_id));
  insert into _d3 values ('TEST cost_entries (expect 6)',
    (select cost_entries::text from v_unit_cost where unit_id=v_id));
  insert into _d3 values ('ROUTE perkasa uses ledger',
    ((select base_unit_cost from v_unit_cost where unit_id=v_id) = 82000000)::text);

  -- routing: a legacy unit must show 0 ledger cost (its cost lives in legacy model, not here)
  select id into v_legacy from units where funding_model='legacy' order by id limit 1;
  if v_legacy is not null then
    insert into _d3 values ('ROUTE legacy ledger cost = 0',
      ((select base_unit_cost from v_unit_cost where unit_id=v_legacy) = 0)::text);
  end if;

  -- constraint: negative amount must be rejected
  begin
    insert into unit_cost_entries(unit_id,category,amount) values(v_id,'Other',-1);
    insert into _d3 values ('CONSTRAINT negative amount','FAIL — allowed');
  exception when others then insert into _d3 values ('CONSTRAINT negative amount','PASS — rejected'); end;

  -- constraint: invalid category must be rejected
  begin
    insert into unit_cost_entries(unit_id,category,amount) values(v_id,'Payroll',1000);
    insert into _d3 values ('CONSTRAINT invalid category','FAIL — allowed');
  exception when others then insert into _d3 values ('CONSTRAINT invalid category','PASS — rejected'); end;

  -- cleanup: delete temp unit → cost entries cascade
  delete from units where id=v_id;
  insert into _d3 values ('CLEANUP entries remain (expect 0)',
    (select count(*)::text from unit_cost_entries where unit_id=v_id));
  insert into _d3 values ('CLEANUP temp unit remain (expect 0)',
    (select count(*)::text from units where nama='__D3_TEST__'));
end $$;

-- 4) POST snapshot (must equal PRE — historical integrity)
insert into _d3 values ('POST units total',       (select count(*)::text from units));
insert into _d3 values ('POST units non-legacy',  (select count(*)::text from units where funding_model<>'legacy'));
insert into _d3 values ('POST v_pnl realized',    (select realized_unit_profit::text from v_pnl));
insert into _d3 values ('POST v_pnl revenue',     (select revenue::text from v_pnl));
insert into _d3 values ('POST reserve_balance',   (select reserve_balance::text from v_reserve_summary));

select * from _d3;
