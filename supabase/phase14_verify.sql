-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 14 (D4) LIVE VERIFICATION + CONTROLLED TEST + CLEANUP
-- Run AFTER phase14_unit_funding.sql. Creates a temporary '__D4_TEST__' perkasa
-- unit, proves funding/gap/status + constraints + partner exposure + funding≠
-- profit-share independence, checks historical PRE/POST, then DELETES all test
-- rows so production is left spotless. Returns one results table — paste it back.
-- ══════════════════════════════════════════════════════════════════════════
create temp table _d4(step text, result text) on commit drop;

-- 1) PRE snapshot (historical baselines)
insert into _d4 values ('PRE units total',      (select count(*)::text from units));
insert into _d4 values ('PRE units legacy',     (select count(*)::text from units where funding_model='legacy'));
insert into _d4 values ('PRE units non-legacy', (select count(*)::text from units where funding_model<>'legacy'));
insert into _d4 values ('PRE v_pnl realized',   (select realized_unit_profit::text from v_pnl));
insert into _d4 values ('PRE v_pnl revenue',    (select revenue::text from v_pnl));
insert into _d4 values ('PRE reserve_balance',  (select reserve_balance::text from v_reserve_summary));
insert into _d4 values ('PRE capital_recon rows',(select count(*)::text from v_capital_reconcile));
insert into _d4 values ('PRE capital_recon deployed',(select coalesce(sum(deployed),0)::text from v_capital_reconcile));

-- 2) Object existence
insert into _d4 values ('obj unit_funding',          (to_regclass('public.unit_funding') is not null)::text);
insert into _d4 values ('obj unit_partner_agreement',(to_regclass('public.unit_partner_agreement') is not null)::text);
insert into _d4 values ('obj v_unit_funding',        (to_regclass('public.v_unit_funding') is not null)::text);
insert into _d4 values ('obj v_external_unit_funding',(to_regclass('public.v_external_unit_funding') is not null)::text);
insert into _d4 values ('rpc pm_partner_agreement_save',  (to_regproc('public.pm_partner_agreement_save') is not null)::text);
insert into _d4 values ('rpc pm_partner_agreement_delete',(to_regproc('public.pm_partner_agreement_delete') is not null)::text);

-- 3) Security model: unit_funding anon writable; unit_partner_agreement anon read-only (no write)
insert into _d4 values ('sec unit_funding anon INSERT (expect true)',
  (exists(select 1 from information_schema.role_table_grants where table_schema='public' and table_name='unit_funding' and grantee='anon' and privilege_type='INSERT'))::text);
insert into _d4 values ('sec upa anon INSERT (expect false)',
  (exists(select 1 from information_schema.role_table_grants where table_schema='public' and table_name='unit_partner_agreement' and grantee='anon' and privilege_type='INSERT'))::text);
insert into _d4 values ('sec upa anon SELECT (expect true)',
  (exists(select 1 from information_schema.role_table_grants where table_schema='public' and table_name='unit_partner_agreement' and grantee='anon' and privilege_type='SELECT'))::text);
insert into _d4 values ('sec policies present',
  ((exists(select 1 from pg_policies where schemaname='public' and tablename='unit_funding'))
   and (exists(select 1 from pg_policies where schemaname='public' and tablename='unit_partner_agreement')))::text);

-- 4) Controlled test on a TEMP perkasa unit (Base Cost 100m via cost ledger)
do $$
declare v_id bigint; v_base numeric; v_status text; v_gap numeric; v_ext numeric;
begin
  insert into units(nama,jenis,status,tgl,funding_model)
    values('__D4_TEST__','Mobil','aktif',current_date,'perkasa') returning id into v_id;
  insert into unit_cost_entries(unit_id,category,description,amount) values (v_id,'Purchase','base',100000000);

  -- 4a) funded case: Perkasa 70 + Partner 30 = 100, gap 0, status funded
  insert into unit_funding(unit_id,source,amount) values (v_id,'perkasa',70000000);
  insert into unit_funding(unit_id,source,partner_name,amount) values (v_id,'partner','Reivan',30000000);
  select base_unit_cost, funding_gap, funding_status into v_base, v_gap, v_status from v_unit_funding where unit_id=v_id;
  insert into _d4 values ('TEST base_unit_cost (100000000)', v_base::text);
  insert into _d4 values ('TEST total funded gap (0)', v_gap::text);
  insert into _d4 values ('TEST funded status (funded)', v_status);
  insert into _d4 values ('TEST perkasa_funding (70000000)', (select perkasa_funding::text from v_unit_funding where unit_id=v_id));
  insert into _d4 values ('TEST partner_funding (30000000)', (select partner_funding::text from v_unit_funding where unit_id=v_id));

  -- 4b) partner exposure appears in v_external_unit_funding
  select outstanding_external_capital into v_ext from v_external_unit_funding where partner_name='Reivan';
  insert into _d4 values ('TEST partner exposure Reivan (>=30000000)', v_ext::text);

  -- 4c) under-funded: remove partner → gap 70m, status under
  delete from unit_funding where unit_id=v_id and source='partner';
  select funding_gap, funding_status into v_gap, v_status from v_unit_funding where unit_id=v_id;
  insert into _d4 values ('TEST under gap (70000000)', v_gap::text);
  insert into _d4 values ('TEST under status (under)', v_status);

  -- 4d) over-funded: add 40m → total 110m, gap -10m, status over
  insert into unit_funding(unit_id,source,amount) values (v_id,'perkasa',40000000);
  select funding_gap, funding_status into v_gap, v_status from v_unit_funding where unit_id=v_id;
  insert into _d4 values ('TEST over gap (-10000000)', v_gap::text);
  insert into _d4 values ('TEST over status (over)', v_status);

  -- 4e) constraint: negative amount rejected
  begin insert into unit_funding(unit_id,source,amount) values(v_id,'perkasa',-1);
    insert into _d4 values ('CONSTRAINT negative amount','FAIL — allowed');
  exception when others then insert into _d4 values ('CONSTRAINT negative amount','PASS — rejected'); end;

  -- 4f) constraint: partner without name rejected
  begin insert into unit_funding(unit_id,source,amount) values(v_id,'partner',1000);
    insert into _d4 values ('CONSTRAINT partner no-name','FAIL — allowed');
  exception when others then insert into _d4 values ('CONSTRAINT partner no-name','PASS — rejected'); end;

  -- 4g) constraint: invalid agreement type rejected
  begin insert into unit_partner_agreement(unit_id,partner_name,agreement_type) values(v_id,'Reivan','interest');
    insert into _d4 values ('CONSTRAINT bad agreement_type','FAIL — allowed');
  exception when others then insert into _d4 values ('CONSTRAINT bad agreement_type','PASS — rejected'); end;

  -- 4h) independence: partner funds 30% but agreement profit_share 20% — different tables, no shared column
  insert into unit_funding(unit_id,source,partner_name,amount) values (v_id,'partner','Reivan',30000000);  -- 30% of 100m base
  insert into unit_partner_agreement(unit_id,partner_name,agreement_type,profit_share_pct,loss_exposure_pct)
    values (v_id,'Reivan','profit_share_pct',20,null);  -- share 20% ≠ funding 30%; loss_exposure NULL ⇒ funding%
  insert into _d4 values ('INDEP funding% (partner/base=~30)',
    round((select partner_funding from v_unit_funding where unit_id=v_id)/1000000,0)::text||'m of 100m');
  insert into _d4 values ('INDEP profit_share% stored (20)',
    (select profit_share_pct::text from unit_partner_agreement where unit_id=v_id and partner_name='Reivan'));
  insert into _d4 values ('INDEP loss_exposure NULL⇒funding% (null)',
    coalesce((select loss_exposure_pct::text from unit_partner_agreement where unit_id=v_id and partner_name='Reivan'),'null'));

  -- 5) cleanup: delete temp unit (cascades funding + agreement + cost entries)
  delete from units where id=v_id;
  insert into _d4 values ('CLEANUP funding remain (0)',   (select count(*)::text from unit_funding where unit_id=v_id));
  insert into _d4 values ('CLEANUP agreement remain (0)', (select count(*)::text from unit_partner_agreement where unit_id=v_id));
  insert into _d4 values ('CLEANUP temp unit remain (0)', (select count(*)::text from units where nama='__D4_TEST__'));
end $$;

-- 6) POST snapshot (must equal PRE — historical integrity; funding never touched P&L/reserve)
insert into _d4 values ('POST units total',       (select count(*)::text from units));
insert into _d4 values ('POST units non-legacy',  (select count(*)::text from units where funding_model<>'legacy'));
insert into _d4 values ('POST v_pnl realized',    (select realized_unit_profit::text from v_pnl));
insert into _d4 values ('POST v_pnl revenue',     (select revenue::text from v_pnl));
insert into _d4 values ('POST reserve_balance',   (select reserve_balance::text from v_reserve_summary));
insert into _d4 values ('POST capital_recon deployed',(select coalesce(sum(deployed),0)::text from v_capital_reconcile));

select * from _d4;
