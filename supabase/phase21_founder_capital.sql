-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 21 · D-Fx1 · FOUNDER / PARTICIPANT CAPITAL LEDGER
-- STATUS: PREPARED — NOT YET EXECUTED (awaiting explicit apply authorization).
--
-- New, additive company-level source of truth for founder/participant equity as
-- discrete transaction EVENTS (contribution / return / adjustment). This is
-- SEPARATE from and does NOT touch:
--   • capital_accounts.funded / .committed (cumulative seeded — legacy)
--   • capital_allocations (per-unit deployment history — legacy)
--   • revenue, profit, debt, partner funding, operating liquidity, per-unit funding
-- Running balance is DERIVED (v_founder_capital); no balance is stored.
-- Legacy untouched. Fully reversible (drop view + table).
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists founder_capital_ledger (
  id          bigserial primary key,
  account_id  bigint references capital_accounts(id),  -- optional link to the person's master row
  participant text not null,                            -- display name (e.g. 'Panji','Pandu')
  amount      numeric not null,
  tipe        text not null check (tipe in ('contribution','return','adjustment')),
  tgl         date not null default current_date,
  notes       text default '',
  created_at  timestamptz default now(),
  -- contribution/return are magnitudes (>=0); adjustment may be signed
  constraint fcl_amount_chk check (
    (tipe in ('contribution','return') and amount >= 0) or tipe = 'adjustment'
  )
);

alter table founder_capital_ledger enable row level security;
do $$ begin execute 'create policy fcl_all on founder_capital_ledger for all to anon,authenticated using(true) with check(true)'; exception when duplicate_object then null; end $$;
grant select, insert, update, delete on founder_capital_ledger to anon, authenticated;
grant usage, select on sequence founder_capital_ledger_id_seq to anon, authenticated;

-- Running balance per participant (signed): contribution +, return −, adjustment ±.
create or replace view v_founder_capital as
select
  account_id,
  participant,
  sum(case tipe when 'contribution' then amount when 'return' then -amount else amount end) as balance,
  sum(case when tipe='contribution' then amount else 0 end) as total_contributed,
  sum(case when tipe='return'       then amount else 0 end) as total_returned,
  sum(case when tipe='adjustment'   then amount else 0 end) as total_adjustment,
  count(*)  as tx_count,
  max(tgl)  as last_tgl
from founder_capital_ledger
group by account_id, participant;

grant select on v_founder_capital to anon, authenticated;
