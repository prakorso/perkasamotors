-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 12 · PARTNER COLLABORATION  (additive, non-destructive)
-- v2 — SECURITY & DATA-INTEGRITY HARDENED. Safe to run fresh OR over a dev v1.
--
-- TERMINOLOGY (authoritative):
--   Net Profit     = Selling Price − Base Acquisition Price − Direct Costs
--                    (capital return is NOT deducted from Net Profit)
--   Partner Profit = Net Profit × Partner Profit Share %
--   Perkasa Profit = Net Profit − Partner Profit
--   Capital is returned SEPARATELY before profit distribution.
--   Partner Profit Share % is a share of NET PROFIT — NOT interest / ROI on
--   partner capital. share_pct NULL = "Custom" (bespoke agreement required).
--
-- SECURITY MODEL (follows existing app convention — accounts / app_config):
--   • partner_deals holds SENSITIVE financials → NO direct anon access
--     (RLS USING(false), table DML revoked). All access via SECURITY DEFINER
--     RPCs gated by the admin password (or the app '__internal__' sentinel used
--     by logged-in internal users), exactly like pm_save_admin_config.
--   • partner_profit_policy is a rate card → anon may SELECT (the simulator
--     needs it) but CANNOT write; writes go through a gated RPC.
--   • Partner View is frontend-only presentation; partners get NO DB access.
--   NOTE: this app has no Supabase-Auth 'authenticated' role — every app user is
--   'anon' at the DB layer and proves "internal" via the admin-password RPC
--   convention. True per-user auth would require migrating to Supabase Auth
--   (recommended future step; out of scope here).
-- ══════════════════════════════════════════════════════════════════════════

-- ── 1) POLICY MATRIX (configurable rate card) ──
create table if not exists partner_profit_policy (
  id            bigserial primary key,
  vehicle_type  text not null,
  bracket_label text not null,
  holding_label text not null,
  share_pct     numeric,                       -- NULL = Custom
  updated_at    timestamptz default now(),
  unique(vehicle_type, bracket_label, holding_label)
);
-- vehicle_type CHECK (idempotent)
do $$ begin
  alter table partner_profit_policy add constraint ppp_vehicle_chk check (vehicle_type in ('Mobil','Motor'));
exception when duplicate_object then null; end $$;

-- V1 seed — UNCHANGED values. on-conflict-do-nothing preserves any edits.
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

-- ── 2) DEALS (sensitive) ──
create table if not exists partner_deals (
  id             bigserial primary key,
  unit_name      text not null default '',
  vehicle_type   text not null default 'Motor',
  base_price     numeric not null default 0,
  selling_price  numeric not null default 0,
  partner_capital numeric not null default 0,
  perkasa_capital numeric not null default 0,
  repair_cost    numeric not null default 0,
  transport_cost numeric not null default 0,
  doc_cost       numeric not null default 0,
  marketing_cost numeric not null default 0,
  holding_days   int not null default 0,
  status         text not null default 'Simulation',
  notes          text default '',
  created_at     timestamptz default now(),
  updated_at     timestamptz default now()
);
-- Policy-versioning: preserve the share % that applied when the deal was funded,
-- so later edits to the rate card never change historical deal economics.
alter table partner_deals add column if not exists applied_partner_share_pct numeric;
alter table partner_deals add column if not exists applied_at timestamptz;

-- CHECK constraints (idempotent). Balance is intentionally NOT enforced here so
-- Simulation rows may be incomplete; the funded-balance rule lives in the save RPC.
do $$ begin alter table partner_deals add constraint pd_vehicle_chk  check (vehicle_type in ('Mobil','Motor')); exception when duplicate_object then null; end $$;
do $$ begin alter table partner_deals add constraint pd_nonneg_chk   check (base_price>=0 and selling_price>=0 and partner_capital>=0 and perkasa_capital>=0 and repair_cost>=0 and transport_cost>=0 and doc_cost>=0 and marketing_cost>=0 and holding_days>=0); exception when duplicate_object then null; end $$;
do $$ begin alter table partner_deals add constraint pd_status_chk   check (status in ('Simulation','Funded','In Inventory','Sold','Settlement Pending','Settled','Loss')); exception when duplicate_object then null; end $$;

-- ── 3) updated_at triggers (reuse existing set_updated_at) ──
create or replace function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;
drop trigger if exists partner_policy_updated_at on partner_profit_policy;
create trigger partner_policy_updated_at before update on partner_profit_policy
  for each row execute function set_updated_at();
drop trigger if exists partner_deals_updated_at on partner_deals;
create trigger partner_deals_updated_at before update on partner_deals
  for each row execute function set_updated_at();

-- ── 4) RLS — replace the permissive v1 policies ──
alter table partner_profit_policy enable row level security;
alter table partner_deals         enable row level security;
drop policy if exists allow_all_ppp on partner_profit_policy;   -- remove v1 permissive
drop policy if exists allow_all_pd  on partner_deals;           -- remove v1 permissive
-- Policy rate card: anon may READ only (simulator needs it); no anon writes.
do $$ begin execute 'create policy partner_policy_read on partner_profit_policy for select to anon,authenticated using(true)'; exception when duplicate_object then null; end $$;
-- Deals: NO direct access for anon (mirrors accounts / app_config).
do $$ begin execute 'create policy partner_deals_no_direct on partner_deals for all to anon,authenticated using(false) with check(false)'; exception when duplicate_object then null; end $$;

-- Table privileges: policy readable, not writable; deals fully locked (RPC-only).
revoke all on partner_profit_policy from anon, authenticated;
grant  select on partner_profit_policy to anon, authenticated;
revoke all on partner_deals from anon, authenticated;
-- sequences: needed by the SECURITY DEFINER function owner (already owner); no anon grant.

-- ── 5) GATED RPCs (SECURITY DEFINER; admin-password or '__internal__' sentinel) ──
create or replace function pm_partner_auth(p_pass text) returns boolean language plpgsql stable security definer as $$
declare stored text;
begin
  select value into stored from app_config where key='admin_pass';
  if stored is null then stored:='admin123'; end if;
  return (p_pass = stored or p_pass = '__internal__');
end; $$;

-- Save/replace policy rates (admin). p_rows = jsonb array of
--   {vehicle_type,bracket_label,holding_label,share_pct(null=Custom)}
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

-- List deals (gated).
create or replace function pm_partner_deals_list(p_pass text)
returns json language plpgsql security definer as $$
begin
  if not pm_partner_auth(p_pass) then return json_build_object('ok',false,'error','Tidak berwenang.'); end if;
  return json_build_object('ok',true,'deals',
    coalesce((select json_agg(d order by d.id desc) from partner_deals d),'[]'::json));
end; $$;

-- Insert/update a deal (gated). Enforces the FUNDED-BALANCE rule server-side:
-- any status other than 'Simulation' must satisfy partner+perkasa = base_price.
-- Stamps applied_partner_share_pct for non-Simulation deals (historical integrity).
create or replace function pm_partner_deal_save(p_pass text, p_id bigint, p_payload jsonb)
returns json language plpgsql security definer as $$
declare v_status text; v_base numeric; v_partner numeric; v_perkasa numeric;
  v_applied numeric; new_id bigint;
begin
  if not pm_partner_auth(p_pass) then return json_build_object('ok',false,'error','Tidak berwenang.'); end if;
  v_status  := coalesce(p_payload->>'status','Simulation');
  v_base    := coalesce((p_payload->>'base_price')::numeric,0);
  v_partner := coalesce((p_payload->>'partner_capital')::numeric,0);
  v_perkasa := coalesce((p_payload->>'perkasa_capital')::numeric,0);
  v_applied := case when p_payload->>'applied_partner_share_pct' is null or p_payload->>'applied_partner_share_pct'=''
                    then null else (p_payload->>'applied_partner_share_pct')::numeric end;
  if v_base <= 0 then return json_build_object('ok',false,'error','Base price harus > 0.'); end if;
  -- FUNDED-BALANCE RULE (not for Simulation)
  if v_status <> 'Simulation' and round(v_partner+v_perkasa) <> round(v_base) then
    return json_build_object('ok',false,'error','Deal '||v_status||' tidak seimbang: Partner + Perkasa harus sama dengan Base Price.');
  end if;

  if p_id is null then
    insert into partner_deals(unit_name,vehicle_type,base_price,selling_price,partner_capital,perkasa_capital,
       repair_cost,transport_cost,doc_cost,marketing_cost,holding_days,status,notes,
       applied_partner_share_pct,applied_at)
    values (coalesce(p_payload->>'unit_name',''), coalesce(p_payload->>'vehicle_type','Motor'),
       v_base, coalesce((p_payload->>'selling_price')::numeric,0), v_partner, v_perkasa,
       coalesce((p_payload->>'repair_cost')::numeric,0), coalesce((p_payload->>'transport_cost')::numeric,0),
       coalesce((p_payload->>'doc_cost')::numeric,0), coalesce((p_payload->>'marketing_cost')::numeric,0),
       coalesce((p_payload->>'holding_days')::int,0), v_status, coalesce(p_payload->>'notes',''),
       case when v_status='Simulation' then null else v_applied end,
       case when v_status='Simulation' then null else now() end)
    returning id into new_id;
  else
    update partner_deals set
       unit_name=coalesce(p_payload->>'unit_name',unit_name), vehicle_type=coalesce(p_payload->>'vehicle_type',vehicle_type),
       base_price=v_base, selling_price=coalesce((p_payload->>'selling_price')::numeric,selling_price),
       partner_capital=v_partner, perkasa_capital=v_perkasa,
       repair_cost=coalesce((p_payload->>'repair_cost')::numeric,repair_cost),
       transport_cost=coalesce((p_payload->>'transport_cost')::numeric,transport_cost),
       doc_cost=coalesce((p_payload->>'doc_cost')::numeric,doc_cost),
       marketing_cost=coalesce((p_payload->>'marketing_cost')::numeric,marketing_cost),
       holding_days=coalesce((p_payload->>'holding_days')::int,holding_days), status=v_status,
       notes=coalesce(p_payload->>'notes',notes),
       -- stamp applied share once, when leaving Simulation; never overwrite an existing stamp
       applied_partner_share_pct = case when v_status='Simulation' then applied_partner_share_pct
                                        else coalesce(applied_partner_share_pct, v_applied) end,
       applied_at = case when v_status='Simulation' then applied_at
                         else coalesce(applied_at, now()) end
     where id=p_id returning id into new_id;
  end if;
  return json_build_object('ok',true,'id',new_id);
end; $$;

create or replace function pm_partner_deal_delete(p_pass text, p_id bigint)
returns json language plpgsql security definer as $$
begin
  if not pm_partner_auth(p_pass) then return json_build_object('ok',false,'error','Tidak berwenang.'); end if;
  delete from partner_deals where id=p_id;
  return json_build_object('ok',true);
end; $$;

grant execute on function pm_partner_auth(text)                         to anon,authenticated;
grant execute on function pm_partner_policy_save(text,jsonb)            to anon,authenticated;
grant execute on function pm_partner_deals_list(text)                  to anon,authenticated;
grant execute on function pm_partner_deal_save(text,bigint,jsonb)      to anon,authenticated;
grant execute on function pm_partner_deal_delete(text,bigint)         to anon,authenticated;

-- ── QA ──
--   select vehicle_type,count(*) from partner_profit_policy group by 1;   -- 30 each
--   select count(*) from partner_profit_policy where share_pct is null;   -- Custom cells stay NULL (8)
--   -- anon direct access must FAIL: select * from partner_deals;  (blocked by RLS)
--   -- funded-balance: pm_partner_deal_save('__internal__',null,'{"status":"Funded","base_price":10,"partner_capital":4,"perkasa_capital":5}') → error
