-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 17 · PARTNER COLLABORATION POLICY ENGINE  (ADDITIVE)
-- Wires the existing partner_profit_policy rate card (phase 12) to real unit
-- settlement WITHOUT touching D3–D5 logic. Everything here is additive:
--   • fn_partner_policy_rate  — numeric-threshold tier engine (read-only)
--   • unit_settlement.applied_partner_profit_pct — frozen rate in the snapshot
--   • pm_unit_settle_policy    — orchestration: resolve+stamp rate, then call the
--     UNCHANGED locked pm_unit_settle_v2, then freeze applied % in the snapshot.
--
-- BOUNDARY RULE (business-authoritative): funding-exposure is TIER/THRESHOLD, not
-- literal string ranges. The upper edge of a tier moves into the next tier, and
-- EXACTLY 50% enters the highest tier:
--   exposure<10 | 10..<20 | 20..<30 | 30..<40 | 40..<50 | >=50
-- Holding-day tiers: <=30 | <=60 | <=90 | <=120 | else (121+). Holding anchor =
-- unit.tgl (acquisition), identical to D5's existing holding_days definition.
--
-- CONFIGURABILITY: percentages live in partner_profit_policy and stay editable via
-- the gated pm_partner_policy_save RPC. FUTURE settlements read the LATEST policy;
-- a SETTLED unit freezes its applied % (agreement stamp + snapshot column) and is
-- never re-computed if the policy is edited later. NULL policy cell = Custom → the
-- orchestration refuses to settle a PROFIT case until a bespoke rate is set.
-- ══════════════════════════════════════════════════════════════════════════

-- ── 1) TIER ENGINE (read-only; numeric thresholds, labels map to phase-12 rows) ──
create or replace function fn_partner_policy_rate(p_vehicle text, p_exposure numeric, p_holding int)
returns json language sql stable as $$
  with t as (
    select
      case
        when coalesce(p_exposure,0) <  10 then '<10%'
        when p_exposure <  20 then '10-20%'
        when p_exposure <  30 then '20-30%'
        when p_exposure <  40 then '30-40%'
        when p_exposure <  50 then '40-50%'   -- 40 <= exposure < 50
        else '>50%'                            -- exposure >= 50 → highest tier
      end as bracket_label,
      case
        when coalesce(p_holding,0) <=  30 then '<30'
        when p_holding <=  60 then '31-60'
        when p_holding <=  90 then '61-90'
        when p_holding <= 120 then '91-120'
        else '121-180'                          -- 121+ (incl. >180) → highest holding tier
      end as holding_label
  )
  select json_build_object(
    'vehicle_type', p_vehicle,
    'exposure_pct', coalesce(p_exposure,0),
    'holding_days', coalesce(p_holding,0),
    'bracket_label', t.bracket_label,
    'holding_label', t.holding_label,
    'share_pct', (select share_pct from partner_profit_policy p
                   where p.vehicle_type=p_vehicle and p.bracket_label=t.bracket_label and p.holding_label=t.holding_label),
    'is_custom', coalesce((select share_pct is null from partner_profit_policy p
                   where p.vehicle_type=p_vehicle and p.bracket_label=t.bracket_label and p.holding_label=t.holding_label), true)
  ) from t;
$$;
grant execute on function fn_partner_policy_rate(text,numeric,int) to anon,authenticated;

-- ── 2) FROZEN APPLIED RATE on the settlement snapshot (additive column) ──
alter table unit_settlement add column if not exists applied_partner_profit_pct numeric;

-- ── 3) ORCHESTRATION RPC — resolve policy, stamp, call locked D5, freeze % ──
-- D5's pm_unit_settle_v2 is invoked UNCHANGED. This wrapper only (a) resolves the
-- policy rate for a PROFIT case with partner funding, (b) stamps it into the
-- profit_share agreement so D5 reads it, (c) records the applied % in the snapshot.
-- LOSS cases: policy is irrelevant (D5 allocates loss by funding/loss exposure) —
-- we do not require or stamp a policy rate.
create or replace function pm_unit_settle_policy(p_pass text, p_unit_id bigint,
  p_selling_price numeric, p_selling_cost numeric, p_settle_date date default current_date)
returns json language plpgsql security definer as $$
declare
  v_jenis text; v_tgl date; v_base numeric; v_partner numeric; v_total numeric;
  v_exposure numeric; v_holding int; v_truep numeric; v_rate json; v_share numeric;
  v_custom boolean; v_has_partner boolean; r record; res json;
begin
  if not pm_partner_auth(p_pass) then return json_build_object('ok',false,'error','Tidak berwenang.'); end if;
  select jenis, tgl::date into v_jenis, v_tgl from units where id=p_unit_id;
  if not found then return json_build_object('ok',false,'error','Unit tidak ditemukan.'); end if;

  select coalesce(base_unit_cost,0), coalesce(partner_funding,0), coalesce(total_funding,0)
    into v_base, v_partner, v_total from v_unit_funding where unit_id=p_unit_id;

  v_exposure    := case when coalesce(v_total,0) > 0 then round(v_partner / v_total * 100, 4) else 0 end;
  v_holding     := greatest(coalesce(p_settle_date,current_date) - v_tgl, 0);   -- same anchor as D5
  v_truep       := p_selling_price - coalesce(p_selling_cost,0) - coalesce(v_base,0);
  v_has_partner := exists(select 1 from unit_funding where unit_id=p_unit_id and source='partner' and amount>0);
  v_rate        := fn_partner_policy_rate(v_jenis, v_exposure, v_holding);
  v_custom      := (v_rate->>'is_custom')::boolean;
  v_share       := nullif(v_rate->>'share_pct','')::numeric;

  -- PROFIT + partner funding → require a resolved (non-Custom) policy rate, then stamp it.
  if v_has_partner and v_truep > 0 then
    if v_custom or v_share is null then
      return json_build_object('ok',false,'error','Sel policy Custom — tetapkan Partner Profit % bespoke sebelum settle.','policy',v_rate);
    end if;
    for r in select distinct partner_name from unit_funding
             where unit_id=p_unit_id and source='partner' and amount>0 and partner_name is not null loop
      insert into unit_partner_agreement(unit_id,partner_name,agreement_type,profit_share_pct)
      values (p_unit_id, r.partner_name, 'profit_share_pct', v_share)
      on conflict (unit_id,partner_name) do update
        set agreement_type='profit_share_pct', profit_share_pct=v_share, updated_at=now();
    end loop;
  end if;

  -- Call the LOCKED D5 settlement engine, unchanged.
  res := pm_unit_settle_v2('__internal__', p_unit_id, p_selling_price, coalesce(p_selling_cost,0), coalesce(p_settle_date,current_date));
  if res is null or (res->>'ok')::boolean is not true then return res; end if;

  -- Freeze the applied % in the immutable snapshot (record-keeping only; no formula).
  update unit_settlement set applied_partner_profit_pct = case when v_has_partner and v_truep>0 then v_share else null end
   where unit_id=p_unit_id and status='settled';

  return json_build_object('ok',true,'policy',v_rate,'applied_partner_profit_pct',
    case when v_has_partner and v_truep>0 then v_share else null end,'settle',res);
end; $$;
grant execute on function pm_unit_settle_policy(text,bigint,numeric,numeric,date) to anon,authenticated;

-- ══════════════════════════════════════════════════════════════════════════
-- QA (run after apply):
--   select fn_partner_policy_rate('Mobil',30,75);   -- {bracket 30-40%, holding 61-90, share 17, is_custom false}
--   select fn_partner_policy_rate('Mobil',40,75);   -- 40-50% tier (40 → next tier)
--   select fn_partner_policy_rate('Mobil',50,75);   -- >50% tier (exactly 50 → highest)
--   select fn_partner_policy_rate('Mobil',49.99,75);-- 40-50% tier
--   select column_name from information_schema.columns
--     where table_name='unit_settlement' and column_name='applied_partner_profit_pct';  -- exists
-- ══════════════════════════════════════════════════════════════════════════
