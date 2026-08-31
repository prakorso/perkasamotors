-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 13 · UNIT COST LEDGER  (D3; additive, non-destructive)
-- Scope: ONLY Unit → Cost Entries → Base Unit Cost. No funding, no settlement,
-- no capital pool, no partner profit, no debt/payroll/UI redesign.
--
-- Base Unit Cost = Σ all DIRECT unit costs (Purchase, Service, Repair, Sparepart,
-- Transport, Document/Tax, Direct Marketing, Other). Company-wide payroll, office,
-- software, and general overhead are NOT unit costs — they stay in business P&L.
--
-- Base Unit Cost is DB-DERIVED (v_unit_cost). The frontend never recomputes it.
-- LEGACY units keep their existing cost model (biaya_* + v_unit_economics) —
-- unchanged. Future units (units.funding_model='perkasa') use this ledger.
-- ══════════════════════════════════════════════════════════════════════════

-- Route flag: 'legacy' (existing biaya_* model) | 'perkasa' (new cost ledger).
alter table units add column if not exists funding_model text not null default 'legacy';
do $$ begin
  alter table units add constraint units_funding_model_chk check (funding_model in ('legacy','perkasa'));
exception when duplicate_object then null; end $$;

create table if not exists unit_cost_entries (
  id          bigserial primary key,
  unit_id     bigint not null references units(id) on delete cascade,
  category    text not null,
  description text default '',
  amount      numeric not null default 0,
  entry_date  date not null default current_date,
  note        text default '',
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);
do $$ begin
  alter table unit_cost_entries add constraint uce_category_chk
    check (category in ('Purchase','Service','Repair','Sparepart','Transport','Document/Tax','Direct Marketing','Other'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table unit_cost_entries add constraint uce_amount_chk check (amount >= 0);
exception when duplicate_object then null; end $$;
create index if not exists idx_unit_cost_entries_unit on unit_cost_entries(unit_id);

-- updated_at trigger (reuse existing set_updated_at)
create or replace function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;
drop trigger if exists unit_cost_entries_updated_at on unit_cost_entries;
create trigger unit_cost_entries_updated_at before update on unit_cost_entries
  for each row execute function set_updated_at();

-- DB-derived Base Unit Cost (ledger). SINGLE SOURCE OF TRUTH for future-unit cost.
create or replace view v_unit_cost as
select u.id as unit_id, u.nama, u.funding_model,
  coalesce(sum(e.amount),0) as base_unit_cost,
  count(e.*)                as cost_entries
from units u
left join unit_cost_entries e on e.unit_id = u.id
group by u.id, u.nama, u.funding_model;

-- RLS: operational table (cost lines), same allow-all-anon model as units/kas_keluar.
alter table unit_cost_entries enable row level security;
do $$ begin execute 'create policy allow_all_uce on unit_cost_entries for all to anon,authenticated using(true) with check(true)'; exception when duplicate_object then null; end $$;
grant select,insert,update,delete on unit_cost_entries to anon,authenticated;
grant usage,select on sequence unit_cost_entries_id_seq to anon,authenticated;
grant select on v_unit_cost to anon,authenticated;

-- ══════════════════════════════════════════════════════════════════════════
-- LIVE VERIFICATION (run after deploy):
--   • select column_name from information_schema.columns
--       where table_name='units' and column_name='funding_model';        -- exists
--   • select count(*) from units where funding_model<>'legacy';           -- 0 (no legacy touched)
--   • base cost derives: insert 6 entries for a test unit, then
--       select base_unit_cost from v_unit_cost where unit_id=<id>;        -- = Σ amounts
--   • historical integrity: legacy v_pnl / v_unit_economics unchanged (no dependency added).
-- ══════════════════════════════════════════════════════════════════════════
