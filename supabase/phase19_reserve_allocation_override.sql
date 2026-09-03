-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 19 · D10 · MANUAL RESERVE/OPERATING SPLIT OVERRIDE
-- APPLIED to production (additive). Lets a user re-split a PERKASA unit's
-- realized profit between Cash Reserve and Operating Profit Pool WITHOUT
-- touching settlement economics (true_unit_profit, perkasa_retained_profit,
-- base cost, selling price, capital return are ALL untouched). Only the
-- reserve/operating split changes, and the REAL restricted-cash reserve_ledger
-- is re-synced so restricted cash matches the chosen split.
--   Invariant: Reserve + Operating = Realized ;  0 <= Reserve <= Realized.
--   Loss (realized <= 0) → Reserve = 0 always (override ignored).
-- Legacy reserve (tipe='retained_profit') is untouched. No double counting.
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists reserve_allocation_override (
  unit_id        bigint primary key,
  reserve_amount numeric not null check (reserve_amount >= 0),
  old_reserve    numeric,
  reason         text,
  updated_at     timestamptz not null default now()
);
alter table reserve_allocation_override enable row level security;
do $$ begin execute 'create policy rao_read on reserve_allocation_override for select to anon,authenticated using(true)'; exception when duplicate_object then null; end $$;
revoke all on reserve_allocation_override from anon, authenticated;
grant select on reserve_allocation_override to anon, authenticated;

-- Realized (kept) perkasa profit for a unit — settled perkasa rows only.
create or replace function fn_perkasa_realized(p_unit bigint)
returns numeric language sql stable as $$
  select coalesce(sum(s.perkasa_retained_profit),0)
    from unit_settlement s join units u on u.id=s.unit_id
   where s.unit_id=p_unit and s.status='settled'
     and coalesce(u.funding_model,'legacy')='perkasa';
$$;
grant execute on function fn_perkasa_realized(bigint) to anon,authenticated;

-- Refresh the restricted reserve_ledger row for one unit from override-or-policy.
create or replace function fn_refresh_perkasa_reserve(p_unit bigint)
returns numeric language plpgsql security definer as $$
declare v_retained numeric; v_rate numeric; v_reserve numeric; v_override numeric;
begin
  select coalesce(rate,0.10) into v_rate from financial_policy
    where status='active' order by effective_date desc nulls last limit 1;
  if v_rate is null then v_rate := 0.10; end if;
  v_retained := fn_perkasa_realized(p_unit);
  v_reserve  := case when v_retained>0 then round(v_retained*v_rate) else 0 end;
  select reserve_amount into v_override from reserve_allocation_override where unit_id=p_unit;
  if v_override is not null and v_retained>0 then
    v_reserve := least(greatest(v_override,0), v_retained);   -- clamp into [0, realized]
  end if;
  if v_retained <= 0 then v_reserve := 0; end if;             -- loss → reserve 0
  delete from reserve_ledger where unit_id=p_unit and tipe='perkasa_reserve';
  if v_reserve>0 then
    insert into reserve_ledger(tgl,tipe,arah,nominal,unit_id,keterangan)
    values (current_date,'perkasa_reserve','in',v_reserve,p_unit,
            case when v_override is not null then 'D10 manual reserve split'
                 else 'D9 auto reserve 10% of realized perkasa profit' end);
  end if;
  return v_reserve;
end; $$;
grant execute on function fn_refresh_perkasa_reserve(bigint) to anon,authenticated;

-- Settlement trigger now delegates to the shared refresh (honors override).
create or replace function fn_sync_perkasa_reserve()
returns trigger language plpgsql security definer as $$
declare v_unit bigint;
begin
  v_unit := coalesce(NEW.unit_id, OLD.unit_id);
  if v_unit is null then return null; end if;
  perform fn_refresh_perkasa_reserve(v_unit);
  return null;
exception when others then
  return null;  -- never block a settlement on reserve-sync failure
end; $$;

-- Public RPC: set a manual split. Validates, records audit (old/new/reason/at),
-- re-syncs restricted cash. Refuses invalid values. Perkasa units only.
create or replace function pm_set_reserve_override(p_unit bigint, p_reserve numeric, p_reason text default null)
returns json language plpgsql security definer as $$
declare v_realized numeric; v_model text; v_old numeric; v_new numeric;
begin
  select coalesce(funding_model,'legacy') into v_model from units where id=p_unit;
  if not found then return json_build_object('ok',false,'error','Unit tidak ditemukan.'); end if;
  if v_model<>'perkasa' then return json_build_object('ok',false,'error','Hanya unit Perkasa yang punya alokasi reserve otomatis.'); end if;
  v_realized := fn_perkasa_realized(p_unit);
  if v_realized <= 0 then return json_build_object('ok',false,'error','Realized profit tidak positif — reserve = 0, tidak dapat dialokasikan.'); end if;
  if p_reserve is null or p_reserve < 0 then return json_build_object('ok',false,'error','Reserve tidak boleh negatif.'); end if;
  if p_reserve > v_realized then return json_build_object('ok',false,'error','Reserve tidak boleh melebihi Realized Profit.'); end if;
  v_new := round(p_reserve);
  select nominal into v_old from reserve_ledger where unit_id=p_unit and tipe='perkasa_reserve' limit 1;
  insert into reserve_allocation_override(unit_id,reserve_amount,old_reserve,reason,updated_at)
    values (p_unit, v_new, v_old, nullif(trim(coalesce(p_reason,'')),''), now())
  on conflict (unit_id) do update
    set reserve_amount=excluded.reserve_amount, old_reserve=coalesce(reserve_allocation_override.reserve_amount, excluded.old_reserve),
        reason=excluded.reason, updated_at=now();
  perform fn_refresh_perkasa_reserve(p_unit);
  return json_build_object('ok',true,'unit_id',p_unit,'realized',v_realized,'reserve',v_new,'operating',v_realized - v_new,'old_reserve',v_old);
end; $$;
grant execute on function pm_set_reserve_override(bigint,numeric,text) to anon,authenticated;

-- Public RPC: clear override → revert to policy 10%.
create or replace function pm_clear_reserve_override(p_unit bigint)
returns json language plpgsql security definer as $$
declare v_reserve numeric;
begin
  delete from reserve_allocation_override where unit_id=p_unit;
  v_reserve := fn_refresh_perkasa_reserve(p_unit);
  return json_build_object('ok',true,'unit_id',p_unit,'reserve',v_reserve);
end; $$;
grant execute on function pm_clear_reserve_override(bigint) to anon,authenticated;

-- ══════════════════════════════════════════════════════════════════════════
-- QA (verified live): set 600k → reserve 600k/operating 3.85M; reject negative;
-- reject > realized; clear → back to policy 445k. Grand Avega baseline 445k
-- intact; total reserve 2.145M (445k perkasa + 1.7M legacy) unchanged.
-- ══════════════════════════════════════════════════════════════════════════
