-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 21+22 VERIFICATION (run AFTER both are applied)
-- Founder capital ledger + running balance; cost attribution additivity;
-- Grand Avega regression; legacy invariants. Self-cleaning (deletes test rows).
-- ══════════════════════════════════════════════════════════════════════════
create temp table _p2122(step text, result text) on commit drop;

-- Legacy invariants BEFORE
insert into _p2122 values('PRE v_pnl realized',        (select realized_unit_profit::text from v_pnl));
insert into _p2122 values('PRE company founder_capital',(select founder_capital::text from v_company_capital));  -- legacy 757.5M unchanged
insert into _p2122 values('PRE GA base_unit_cost',      (select base_unit_cost::text from v_unit_cost where unit_id=62));
insert into _p2122 values('PRE GA realized',            (select perkasa_retained_profit::text from unit_settlement where unit_id=62 and status='settled'));

do $$
declare pid_panji bigint; pid_pandu bigint; b_panji numeric; b_pandu numeric;
begin
  select id into pid_panji from capital_accounts where name='Panji' limit 1;
  select id into pid_pandu from capital_accounts where name='Pandu' limit 1;

  -- FOUNDER TEST: Panji 40M contribution, Pandu 20M contribution, then Panji 5M return
  insert into founder_capital_ledger(account_id,participant,amount,tipe,tgl,notes)
    values (pid_panji,'Panji',40000000,'contribution',current_date,'__P21_TEST__');
  insert into founder_capital_ledger(account_id,participant,amount,tipe,tgl,notes)
    values (pid_pandu,'Pandu',20000000,'contribution',current_date,'__P21_TEST__');
  select balance into b_panji from v_founder_capital where participant='Panji';
  select balance into b_pandu from v_founder_capital where participant='Pandu';
  insert into _p2122 values('Founder Panji balance (expect 40000000)', b_panji::text);
  insert into _p2122 values('Founder Pandu balance (expect 20000000)', b_pandu::text);
  insert into _p2122 values('Founder total (expect 60000000)', (b_panji+b_pandu)::text);

  insert into founder_capital_ledger(account_id,participant,amount,tipe,tgl,notes)
    values (pid_panji,'Panji',5000000,'return',current_date,'__P21_TEST__');
  select balance into b_panji from v_founder_capital where participant='Panji';
  insert into _p2122 values('Founder Panji after 5M return (expect 35000000)', b_panji::text);

  -- COST ATTRIBUTION TEST: attribute GA Service/Transport as paid by company; base cost must NOT change
  update unit_cost_entries set paid_source='company', payment_status='paid', paid_date=current_date
    where unit_id=62 and category in ('Service','Transport');
  insert into _p2122 values('GA base_unit_cost after attribution (expect 84550000)',
    (select base_unit_cost::text from v_unit_cost where unit_id=62));
  insert into _p2122 values('GA realized after attribution (expect 4450000)',
    (select perkasa_retained_profit::text from unit_settlement where unit_id=62 and status='settled'));

  -- CLEANUP (revert attribution to NULL and delete founder test rows)
  update unit_cost_entries set paid_source=null, payment_status=null, paid_date=null
    where unit_id=62 and category in ('Service','Transport');
  delete from founder_capital_ledger where notes='__P21_TEST__';
  insert into _p2122 values('CLEANUP founder test rows remain (expect 0)',
    (select count(*)::text from founder_capital_ledger where notes='__P21_TEST__'));
end $$;

-- Legacy invariants AFTER (must equal PRE)
insert into _p2122 values('POST v_pnl realized',         (select realized_unit_profit::text from v_pnl));
insert into _p2122 values('POST company founder_capital', (select founder_capital::text from v_company_capital));
insert into _p2122 values('POST GA base_unit_cost',       (select base_unit_cost::text from v_unit_cost where unit_id=62));
insert into _p2122 values('POST GA realized',             (select perkasa_retained_profit::text from unit_settlement where unit_id=62 and status='settled'));

select * from _p2122;
