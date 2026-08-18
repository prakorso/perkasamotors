-- ══════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 4 · LIVE VALIDATION (rollback test)
-- Run AFTER deploying (in order): phase3_capital_seed.sql,
-- phase3b_decisions.sql, phase4_settlement_engine.sql.
-- This test inserts a synthetic CURRENT unit, settles it, prints the
-- reconciliation, then ROLLS BACK — leaving NO test data in production.
-- ══════════════════════════════════════════════════════════════
begin;
do $$
declare v_id bigint; r json;
begin
  insert into units(nama,jenis,status,tgl,tgl_jual,harga_jual,
                    biaya_panji,biaya_pandu,partners,model_class,reserve_rate,settlement_status)
  values('__VALIDATE__ Avanza','Mobil','terjual','2026-08-20','2026-08-25',90000000,
         '[{"nominal":40000000,"keterangan":"Modal"}]'::jsonb,
         '[{"nominal":40000000,"keterangan":"Modal"}]'::jsonb,
         '[]'::jsonb,'current',0.10,'pending')
  returning id into v_id;

  insert into capital_allocations(account_id,unit_id,amount,kind,status,allocated_date)
    select ca.id, v_id, 40000000,'core_capital','active','2026-08-20'
    from capital_accounts ca where ca.name in ('Panji','Pandu');

  perform pm_reserve_advance(v_id,'maintenance',1000000,'validate');   -- reserve fronts Rp1jt
  r := pm_settle_unit(v_id);

  raise notice '── PHASE 4 VALIDATION ──';
  raise notice 'Result: %', r;
  -- Expected: unit_cost 81,000,000 · profit 9,000,000 · reserve 900,000
  --           distributable 8,100,000 · distributed 8,100,000 · residual 0
  --           proceeds_reconcile 90,000,000 · proceeds_ok true
  assert (r->>'proceeds_ok')::boolean = true, 'PROCEEDS DO NOT RECONCILE';
  assert (r->>'residual')::numeric = 0,       'RESIDUAL NOT ZERO';
  assert (r->>'reserve')::numeric = 900000,   'RESERVE != 900k';
  assert (r->>'profit')::numeric = 9000000,   'PROFIT != 9jt';
  raise notice 'ALL ASSERTIONS PASSED ✓';
end $$;
rollback;   -- nothing persists
