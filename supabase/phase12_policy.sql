-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 12 (POLICY-ONLY) · partner_profit_policy dependency for D6
-- FOCUSED remediation: applies ONLY the policy-matrix objects that Phase 17 needs.
-- Every statement below is copied VERBATIM from phase12_partner_collab.sql — the
-- values are NOT reinterpreted. Idempotent (create-if-not-exists / on-conflict-do-
-- nothing / drop-if-exists), so safe to run once on the live DB.
--
-- EXCLUDED on purpose: partner_deals + its RPCs (Deal Simulator, retired in D6),
-- pm_partner_auth (already LIVE from phase 14 / D4 — untouched), set_updated_at
-- (already LIVE from phase 14 / D4 — reused, not redefined). NO D3/D4/D5 objects.
--
-- Labels are stored as display strings ('<10%','10-20%',…,'>50%'). D6's numeric
-- engine (fn_partner_policy_rate) is authoritative for exposure matching and maps
-- exactly-50% to the highest tier — that logic lives in phase17, not here.
--
-- Dependency chain restored:
--   partner_profit_policy → fn_partner_policy_rate → pm_unit_settle_policy
--     → locked pm_unit_settle_v2 → unit_settlement
-- ══════════════════════════════════════════════════════════════════════════

-- ── 1) POLICY MATRIX TABLE (verbatim) ──
create table if not exists partner_profit_policy (
  id            bigserial primary key,
  vehicle_type  text not null,
  bracket_label text not null,
  holding_label text not null,
  share_pct     numeric,                       -- NULL = Custom
  updated_at    timestamptz default now(),
  unique(vehicle_type, bracket_label, holding_label)
);

-- ── 2) VEHICLE-TYPE CHECK (verbatim, idempotent) ──
do $$ begin
  alter table partner_profit_policy add constraint ppp_vehicle_chk check (vehicle_type in ('Mobil','Motor'));
exception when duplicate_object then null; end $$;

-- ── 3) SEED — exact 60 rows, on-conflict-do-nothing (verbatim) ──
insert into partner_profit_policy(vehicle_type,bracket_label,holding_label,share_pct) values
 ('Mobil','<10%','<30',6),('Mobil','<10%','31-60',7),('Mobil','<10%','61-90',8),('Mobil','<10%','91-120',9),('Mobil','<10%','121-180',10),
 ('Mobil','10-20%','<30',9),('Mobil','10-20%','31-60',10),('Mobil','10-20%','61-90',11),('Mobil','10-20%','91-120',12),('Mobil','10-20%','121-180',13),
 ('Mobil','20-30%','<30',11),('Mobil','20-30%','31-60',12),('Mobil','20-30%','61-90',14),('Mobil','20-30%','91-120',15),('Mobil','20-30%','121-180',17),
 ('Mobil','30-40%','<30',14),('Mobil','30-40%','31-60',15),('Mobil','30-40%','61-90',17),('Mobil','30-40%','91-120',18),('Mobil','30-40%','121-180',20),
 ('Mobil','40-50%','<30',17),('Mobil','40-50%','31-60',18),('Mobil','40-50%','61-90',20),('Mobil','40-50%','91-120',22),('Mobil','40-50%','121-180',24),
 ('Mobil','>50%','<30',20),('Mobil','>50%','31-60',20),('Mobil','>50%','61-90',null),('Mobil','>50%','91-120',null),('Mobil','>50%','121-180',null),
 ('Motor','<10%','<30',5),('Motor','<10%','31-60',5),('Motor','<10%','61-90',6),('Motor','<10%','91-120',7),('Motor','<10%','121-180',8),
 ('Motor','10-20%','<30',8),('Motor','10-20%','31-60',9),('Motor','10-20%','61-90',10),('Motor','10-20%','91-120',11),('Motor','10-20%','121-180',12),
 ('Motor','20-30%','<30',9),('Motor','20-30%','31-60',10),('Motor','20-30%','61-90',11),('Motor','20-30%','91-120',12),('Motor','20-30%','121-180',14),
 ('Motor','30-40%','<30',11),('Motor','30-40%','31-60',12),('Motor','30-40%','61-90',14),('Motor','30-40%','91-120',15),('Motor','30-40%','121-180',17),
 ('Motor','40-50%','<30',14),('Motor','40-50%','31-60',15),('Motor','40-50%','61-90',17),('Motor','40-50%','91-120',18),('Motor','40-50%','121-180',20),
 ('Motor','>50%','<30',20),('Motor','>50%','31-60',null),('Motor','>50%','61-90',null),('Motor','>50%','91-120',null),('Motor','>50%','121-180',null)
on conflict (vehicle_type,bracket_label,holding_label) do nothing;

-- ── 4) updated_at TRIGGER (verbatim; reuses existing set_updated_at) ──
drop trigger if exists partner_policy_updated_at on partner_profit_policy;
create trigger partner_policy_updated_at before update on partner_profit_policy
  for each row execute function set_updated_at();

-- ── 5) RLS: anon SELECT only (verbatim) ──
alter table partner_profit_policy enable row level security;
drop policy if exists allow_all_ppp on partner_profit_policy;   -- remove v1 permissive
do $$ begin execute 'create policy partner_policy_read on partner_profit_policy for select to anon,authenticated using(true)'; exception when duplicate_object then null; end $$;

-- ── 6) GRANTS: readable, not writable (verbatim) ──
revoke all on partner_profit_policy from anon, authenticated;
grant  select on partner_profit_policy to anon, authenticated;

-- ── 7) GATED admin RPC pm_partner_policy_save (verbatim; uses existing pm_partner_auth) ──
create or replace function pm_partner_policy_save(p_pass text, p_rows jsonb)
returns json language plpgsql security definer as $$
declare r jsonb;
begin
  if not pm_partner_auth(p_pass) then return json_build_object('ok',false,'error','Tidak berwenang.'); end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    update partner_profit_policy
       set share_pct = case when r->>'share_pct' is null or r->>'share_pct'='' then null else (r->>'share_pct')::numeric end
     where vehicle_type=r->>'vehicle_type' and bracket_label=r->>'bracket_label' and holding_label=r->>'holding_label';
  end loop;
  return json_build_object('ok',true);
end; $$;
grant execute on function pm_partner_policy_save(text,jsonb)            to anon,authenticated;

-- ── 8) PRE-PHASE-17 SANITY (read-only) ──
select vehicle_type, count(*) as rows from partner_profit_policy group by vehicle_type order by vehicle_type; -- Mobil 30, Motor 30
select count(*) as total_rows from partner_profit_policy;                                                    -- 60
select count(*) as custom_null_cells from partner_profit_policy where share_pct is null;                     -- 7 (Mobil>50%:3 + Motor>50%:4; phase12's "(8)" comment is a mis-annotation)
select to_regprocedure('pm_partner_policy_save(text,jsonb)') is not null as save_rpc_exists;                 -- true
select vehicle_type,bracket_label,holding_label,share_pct from partner_profit_policy
  where vehicle_type='Mobil' and bracket_label='30-40%' and holding_label='61-90';                           -- 17 (matches engine example)
