-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 14 · D4 UNIT FUNDING  (additive, non-destructive)
-- Scope: ONLY unit_funding + unit_partner_agreement + v_unit_funding +
-- v_external_unit_funding. NO settlement, retained profit, unified P&L, company
-- capital, cash position, or reporting (those are D5/D6).
--
-- Funding ≠ Profit Share ≠ Loss Exposure (three independent concepts):
--   • unit_funding.amount          = capital contributed (Funding %)
--   • unit_partner_agreement       = profit terms (Profit Share % / fee) — SEPARATE table
--   • loss_exposure_pct (optional) = NULL ⇒ defaults to funding exposure (D5 rule)
--
-- Security (LOCKED):
--   • unit_funding          → allow-all-anon (operational, like unit_cost_entries)
--   • unit_partner_agreement→ SELECT allowed; writes ONLY via gated SECURITY
--     DEFINER RPCs (admin-pass / '__internal__' convention). Commercial/sensitive.
-- Base Unit Cost reused from v_unit_cost (D3). funding_model reused from units.
-- ══════════════════════════════════════════════════════════════════════════

-- ── unit_funding (operational) ──
create table if not exists unit_funding (
  id           bigserial primary key,
  unit_id      bigint not null references units(id) on delete cascade,
  source       text not null,                       -- 'perkasa' | 'partner'
  partner_name text,                                 -- required iff source='partner'
  amount       numeric not null default 0,
  funded_date  date not null default current_date,
  created_at   timestamptz default now(),
  updated_at   timestamptz default now()
);
do $$ begin alter table unit_funding add constraint uf_source_chk check (source in ('perkasa','partner')); exception when duplicate_object then null; end $$;
do $$ begin alter table unit_funding add constraint uf_amount_chk check (amount >= 0); exception when duplicate_object then null; end $$;
do $$ begin alter table unit_funding add constraint uf_partner_name_chk
  check (source <> 'partner' or (partner_name is not null and length(btrim(partner_name)) > 0)); exception when duplicate_object then null; end $$;
create index if not exists idx_unit_funding_unit on unit_funding(unit_id);

-- ── unit_partner_agreement (commercial/sensitive) ──
create table if not exists unit_partner_agreement (
  id               bigserial primary key,
  unit_id          bigint not null references units(id) on delete cascade,
  partner_name     text not null,
  agreement_type   text not null,                    -- fixed_fee | fee_pct_capital | profit_share_pct
  fixed_fee        numeric,
  fee_pct          numeric,
  profit_share_pct numeric,
  loss_exposure_pct numeric,                          -- NULL ⇒ default = funding exposure
  notes            text default '',
  created_at       timestamptz default now(),
  updated_at       timestamptz default now(),
  unique(unit_id, partner_name)
);
do $$ begin alter table unit_partner_agreement add constraint upa_type_chk
  check (agreement_type in ('fixed_fee','fee_pct_capital','profit_share_pct')); exception when duplicate_object then null; end $$;
create index if not exists idx_upa_unit on unit_partner_agreement(unit_id);

-- ── updated_at triggers (reuse set_updated_at) ──
create or replace function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;
drop trigger if exists unit_funding_updated_at on unit_funding;
create trigger unit_funding_updated_at before update on unit_funding for each row execute function set_updated_at();
drop trigger if exists unit_partner_agreement_updated_at on unit_partner_agreement;
create trigger unit_partner_agreement_updated_at before update on unit_partner_agreement for each row execute function set_updated_at();

-- ── v_unit_funding: DB-derived funding + gap + status (SINGLE source of truth) ──
create or replace view v_unit_funding as
with cost as (select unit_id, base_unit_cost from v_unit_cost)
select u.id as unit_id, u.nama, u.funding_model,
  coalesce(c.base_unit_cost,0)                                          as base_unit_cost,
  coalesce(sum(f.amount) filter (where f.source='perkasa'),0)          as perkasa_funding,
  coalesce(sum(f.amount) filter (where f.source='partner'),0)          as partner_funding,
  coalesce(sum(f.amount),0)                                            as total_funding,
  coalesce(c.base_unit_cost,0) - coalesce(sum(f.amount),0)            as funding_gap,
  case
    when coalesce(sum(f.amount),0) = 0 then 'unfunded'
    when coalesce(sum(f.amount),0) <  coalesce(c.base_unit_cost,0) then 'under'
    when coalesce(sum(f.amount),0) =  coalesce(c.base_unit_cost,0) then 'funded'
    else 'over'
  end                                                                  as funding_status
from units u
left join cost c on c.unit_id = u.id
left join unit_funding f on f.unit_id = u.id
group by u.id, u.nama, u.funding_model, c.base_unit_cost;

-- ── v_external_unit_funding: partner (external) capital outstanding on ACTIVE units ──
create or replace view v_external_unit_funding as
select f.partner_name,
  count(distinct f.unit_id)         as active_units,
  coalesce(sum(f.amount),0)         as outstanding_external_capital
from unit_funding f
join units u on u.id = f.unit_id
where f.source = 'partner' and u.status <> 'terjual'
group by f.partner_name;

-- ── RLS: unit_funding = allow-all-anon (operational) ──
alter table unit_funding enable row level security;
do $$ begin execute 'create policy allow_all_unit_funding on unit_funding for all to anon,authenticated using(true) with check(true)'; exception when duplicate_object then null; end $$;
grant select,insert,update,delete on unit_funding to anon,authenticated;
grant usage,select on sequence unit_funding_id_seq to anon,authenticated;

-- ── RLS: unit_partner_agreement = SELECT only for anon; writes via gated RPC ──
alter table unit_partner_agreement enable row level security;
do $$ begin execute 'create policy upa_read on unit_partner_agreement for select to anon,authenticated using(true)'; exception when duplicate_object then null; end $$;
revoke all on unit_partner_agreement from anon, authenticated;
grant  select on unit_partner_agreement to anon, authenticated;   -- no insert/update/delete for anon

-- ── Gated write RPCs (admin-pass / '__internal__' convention; reuse pm_partner_auth) ──
create or replace function pm_partner_auth(p_pass text) returns boolean language plpgsql stable security definer as $$
declare stored text; begin
  select value into stored from app_config where key='admin_pass';
  if stored is null then stored := 'admin123'; end if;
  return (p_pass = stored or p_pass = '__internal__');
end; $$;

create or replace function pm_partner_agreement_save(p_pass text, p_unit_id bigint, p_payload jsonb)
returns json language plpgsql security definer as $$
begin
  if not pm_partner_auth(p_pass) then return json_build_object('ok',false,'error','Tidak berwenang.'); end if;
  if coalesce(p_payload->>'partner_name','') = '' then return json_build_object('ok',false,'error','partner_name wajib.'); end if;
  insert into unit_partner_agreement(unit_id,partner_name,agreement_type,fixed_fee,fee_pct,profit_share_pct,loss_exposure_pct,notes)
  values (p_unit_id, p_payload->>'partner_name', p_payload->>'agreement_type',
          nullif(p_payload->>'fixed_fee','')::numeric, nullif(p_payload->>'fee_pct','')::numeric,
          nullif(p_payload->>'profit_share_pct','')::numeric, nullif(p_payload->>'loss_exposure_pct','')::numeric,
          coalesce(p_payload->>'notes',''))
  on conflict (unit_id,partner_name) do update
    set agreement_type=excluded.agreement_type, fixed_fee=excluded.fixed_fee, fee_pct=excluded.fee_pct,
        profit_share_pct=excluded.profit_share_pct, loss_exposure_pct=excluded.loss_exposure_pct,
        notes=excluded.notes, updated_at=now();
  return json_build_object('ok',true);
end; $$;

create or replace function pm_partner_agreement_delete(p_pass text, p_id bigint)
returns json language plpgsql security definer as $$
begin
  if not pm_partner_auth(p_pass) then return json_build_object('ok',false,'error','Tidak berwenang.'); end if;
  delete from unit_partner_agreement where id = p_id;
  return json_build_object('ok',true);
end; $$;

grant execute on function pm_partner_auth(text)                            to anon,authenticated;
grant execute on function pm_partner_agreement_save(text,bigint,jsonb)     to anon,authenticated;
grant execute on function pm_partner_agreement_delete(text,bigint)         to anon,authenticated;
grant select on v_unit_funding, v_external_unit_funding to anon,authenticated;
