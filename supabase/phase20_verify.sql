-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 20 VERIFICATION (run AFTER phase20 is applied)
-- Proves: post-baseline OPEX/CAPEX reduce Operating/Total Liquidity by exactly
-- the entered amount, Reserve is untouched, pre-baseline stays out, and a
-- reversal restores the original value. Self-cleaning (rolls back test rows).
-- Paste the final result table.
-- ══════════════════════════════════════════════════════════════════════════
create temp table _p20(step text, result text) on commit drop;

-- Baseline snapshot (no test rows yet)
insert into _p20 values ('0 baseline actual_cash', (select actual_cash::text from v_cash_position));
insert into _p20 values ('0 baseline reserve',     (select reserve::text from v_cash_position));
insert into _p20 values ('0 baseline operating',   (select (actual_cash-reserve)::text from v_cash_position));
insert into _p20 values ('0 opex_paid (expect 0)', (select opex_paid::text from v_cash_position));
insert into _p20 values ('0 capex_paid (expect 0)',(select capex_paid::text from v_cash_position));

do $$
declare base0 numeric; res0 numeric; base1 numeric; res1 numeric; base2 numeric;
        v_baseline date;
begin
  select actual_cash, reserve into base0, res0 from v_cash_position;
  select coalesce(nullif((select value from app_config where key='opening_cash_date'),'')::date,'1900-01-01') into v_baseline;

  -- (A) POST-baseline OPEX Rp300,000 must reduce liquidity by 300,000, reserve unchanged
  insert into kas_keluar(keterangan,nominal,tgl) values ('__P20_OPEX__',300000, v_baseline + 5);
  select actual_cash, reserve into base1, res1 from v_cash_position;
  insert into _p20 values ('A opex 300k → Δactual (expect -300000)', (base1-base0)::text);
  insert into _p20 values ('A reserve unchanged',                    (res1-res0)::text);

  -- (B) POST-baseline CAPEX Rp500,000 must reduce a further 500,000
  insert into aset_inventori(nama,kategori,nilai_beli,nilai_skrg,tgl,status)
    values ('__P20_CAPEX__','Lainnya',500000,500000, v_baseline + 5,'active');
  select actual_cash into base2 from v_cash_position;
  insert into _p20 values ('B capex 500k → Δactual from A (expect -500000)', (base2-base1)::text);
  insert into _p20 values ('B total Δ from baseline (expect -800000)',       (base2-base0)::text);

  -- (C) PRE-baseline OPEX must NOT change liquidity
  insert into kas_keluar(keterangan,nominal,tgl) values ('__P20_PREOPEX__',999000, v_baseline - 5);
  insert into _p20 values ('C pre-baseline opex → Δactual (expect 0 vs B)',
    ((select actual_cash from v_cash_position) - base2)::text);

  -- (D) Reverse all test rows → restore original
  delete from kas_keluar where keterangan in ('__P20_OPEX__','__P20_PREOPEX__');
  delete from aset_inventori where nama='__P20_CAPEX__';
  insert into _p20 values ('D reversed actual_cash (expect = baseline)', (select actual_cash::text from v_cash_position));
  insert into _p20 values ('D reversed matches baseline', ((select actual_cash from v_cash_position)=base0)::text);
end $$;

select * from _p20;
