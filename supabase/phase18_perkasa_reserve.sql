-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 18 (D9 P1) · REAL 10% CASH RESERVE on perkasa profit
-- ADDITIVE. Reuses the existing reserve infrastructure (reserve_ledger →
-- v_reserve_summary → v_cash_pool.reserve → subtracted from available/operating
-- cash) so the 10% is genuine restricted cash, not a display-only figure.
--
-- Safety:
--   • Perkasa reserve rows use a DISTINCT tipe='perkasa_reserve' (legacy rows use
--     tipe='retained_profit') → no double-count, legacy reserve untouched.
--   • Keyed by unit_id; a unit is either legacy or perkasa → never both.
--   • Trigger recomputes on settle AND reverse (reverse flips status→'reversed',
--     which fires the trigger and removes the reserve) → self-reconciling.
--   • Reserve only on POSITIVE realized perkasa profit; loss ⇒ 0.
--   • Trigger is exception-safe: a reserve-sync error never blocks a settlement.
--   • Does NOT modify pm_unit_settle_v2 / pm_unit_settle_reverse (D5 locked),
--     v_unit_cost, v_retained_profit, v_cash_position, or any legacy accounting.
-- ══════════════════════════════════════════════════════════════════════════

create or replace function fn_sync_perkasa_reserve() returns trigger
language plpgsql security definer as $$
declare v_unit bigint; v_retained numeric; v_rate numeric; v_reserve numeric;
begin
  v_unit := coalesce(NEW.unit_id, OLD.unit_id);
  if v_unit is null then return null; end if;
  select coalesce(rate,0.10) into v_rate from financial_policy
    where status='active' order by effective_date desc nulls last limit 1;
  if v_rate is null then v_rate := 0.10; end if;
  -- current realized (kept) perkasa profit for this unit, settled rows only
  select coalesce(sum(s.perkasa_retained_profit),0) into v_retained
    from unit_settlement s join units u on u.id=s.unit_id
    where s.unit_id=v_unit and s.status='settled'
      and coalesce(u.funding_model,'legacy')='perkasa';
  v_reserve := case when v_retained>0 then round(v_retained*v_rate) else 0 end;
  delete from reserve_ledger where unit_id=v_unit and tipe='perkasa_reserve';
  if v_reserve>0 then
    insert into reserve_ledger(tgl,tipe,arah,nominal,unit_id,keterangan)
    values (current_date,'perkasa_reserve','in',v_reserve,v_unit,
            'D9 auto reserve 10% of realized perkasa profit');
  end if;
  return null;
exception when others then
  return null;  -- never block a sale settlement on reserve-sync failure
end; $$;

drop trigger if exists trg_perkasa_reserve on unit_settlement;
create trigger trg_perkasa_reserve
  after insert or update or delete on unit_settlement
  for each row execute function fn_sync_perkasa_reserve();

-- Backfill already-settled perkasa units (idempotent; re-runnable)
delete from reserve_ledger where tipe='perkasa_reserve';
insert into reserve_ledger(tgl,tipe,arah,nominal,unit_id,keterangan)
select current_date,'perkasa_reserve','in',round(s.perkasa_retained_profit*0.10),
       s.unit_id,'D9 backfill reserve 10% of realized perkasa profit'
from unit_settlement s join units u on u.id=s.unit_id
where s.status='settled' and coalesce(u.funding_model,'legacy')='perkasa'
  and s.perkasa_retained_profit>0;
