-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — SISTEM KEUANGAN (GABUNGAN PHASE 3–8)
-- Satu file, jalankan sekali dari atas ke bawah di Supabase SQL Editor.
-- Semua additive & idempotent (aman dijalankan ulang). TIDAK menghapus/menimpa
-- data historis. Legacy tetap legacy (reserve 10% tidak diterapkan surut).
-- Urutan sudah benar: 3 → 3b → 4 → 5 → 6 → 7 → 8.
-- File test (phase4_validate, phase5_live_validation) TIDAK disertakan di sini.
-- ══════════════════════════════════════════════════════════════════════════


-- ##########################################################################
-- ###  SUMBER: phase3_capital_seed.sql
-- ##########################################################################

-- ══════════════════════════════════════════════════════════════
-- PERKASA MOTORS — CFO SYSTEM · PHASE 3
-- Seed capital_accounts + capital_allocations from HISTORICAL data.
-- Purpose: traceability & reporting ONLY. Does NOT change ownership,
-- distributions, or apply the 10% reserve to legacy units.
-- Additive & idempotent. `units` table is never modified except the
-- already-added model_class / reserve_rate classification columns.
-- ══════════════════════════════════════════════════════════════

-- 0) Confirm classification: every existing unit is LEGACY, no reserve applied.
update units set model_class = 'legacy', reserve_rate = null
where model_class is distinct from 'current';   -- keep any future 'current' units intact

-- 1) Idempotent reset of the derived capital model (new tables only)
truncate capital_allocations restart identity;
delete from capital_accounts;

-- 2) Capital accounts — founders
insert into capital_accounts(name, role, account_username) values
  ('Panji','founder','panji'),
  ('Pandu','founder','pandu');

-- 3) Capital accounts — every distinct partner exactly as recorded (no merging)
insert into capital_accounts(name, role, account_username)
select distinct (p->>'nama'),
       'partner',
       case when (p->>'nama') ilike '%reivan%' then 'reivan' else null end
from units u
cross join lateral jsonb_array_elements(u.partners) p
where coalesce(p->>'nama','') <> ''
  and (p->>'nama') not in ('Panji','Pandu')
on conflict (name) do nothing;

-- 4) Allocations — Panji per unit.
--    Created when Panji HAS capital OR received a distribution (preserves the legacy
--    payouts on zero-capital units). amount=0 + profit_share>0 marks a
--    "distribution without capital basis" (a legacy arrangement, preserved as fact).
insert into capital_allocations(account_id,unit_id,amount,kind,status,allocated_date,returned_date,profit_share)
select (select id from capital_accounts where name='Panji'), u.id,
  (select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(u.biaya_panji) e),
  'core_capital',
  case when u.status='terjual' then 'returned' else 'active' end,
  u.tgl::date, case when u.status='terjual' then u.tgl_jual::date end,
  coalesce(u.bagi_panji::numeric,0)
from units u
where (select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(u.biaya_panji) e) > 0
   or coalesce(u.bagi_panji::numeric,0) > 0;

-- 5) Allocations — Pandu per unit (same rule)
insert into capital_allocations(account_id,unit_id,amount,kind,status,allocated_date,returned_date,profit_share)
select (select id from capital_accounts where name='Pandu'), u.id,
  (select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(u.biaya_pandu) e),
  'core_capital',
  case when u.status='terjual' then 'returned' else 'active' end,
  u.tgl::date, case when u.status='terjual' then u.tgl_jual::date end,
  coalesce(u.bagi_pandu::numeric,0)
from units u
where (select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(u.biaya_pandu) e) > 0
   or coalesce(u.bagi_pandu::numeric,0) > 0;

-- 6) Allocations — partner funding (profit_share = ACTUAL recorded fee/return)
insert into capital_allocations(account_id,unit_id,amount,kind,status,allocated_date,returned_date,profit_share)
select ca.id, u.id, (p->>'funding')::numeric, 'partner_funding',
  case when u.status='terjual' then 'returned' else 'active' end,
  u.tgl::date, case when u.status='terjual' then u.tgl_jual::date end,
  case p->>'feeType'
    when 'fixed'          then coalesce((p->>'feeValue')::numeric,0)
    when 'percent'        then (p->>'funding')::numeric*coalesce((p->>'feeValue')::numeric,0)/100
    when 'percent_profit' then coalesce((p->>'feeAmount')::numeric,0)
    else 0 end
from units u
cross join lateral jsonb_array_elements(u.partners) p
join capital_accounts ca on ca.name = (p->>'nama')
where coalesce((p->>'funding')::numeric,0) > 0;

-- 7) Roll up funded/committed onto accounts (historical funded = actual capital placed)
update capital_accounts ca set
  funded    = coalesce((select sum(amount) from capital_allocations a where a.account_id=ca.id),0),
  committed = coalesce((select sum(amount) from capital_allocations a where a.account_id=ca.id),0),
  updated_at = now();

-- ══════════════════════════════════════════════════════════════
-- RECONCILIATION (read-only) — every source total must tie out
-- ══════════════════════════════════════════════════════════════
-- A) Capital: allocations vs raw unit cost lines
--   select
--     (select sum(amount) from capital_allocations) alloc_total,
--     (select sum((select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(biaya_panji) e)
--                +(select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(biaya_pandu) e)
--                +(select coalesce(sum((pp->>'funding')::numeric),0) from jsonb_array_elements(partners) pp)) from units) unit_cost_total;
-- B) Distribution: allocation profit_share vs recorded bagi/fee
--   select (select sum(profit_share) from capital_allocations) alloc_dist,
--          (select sum(coalesce(bagi_panji::numeric,0)+coalesce(bagi_pandu::numeric,0)) from units where status='terjual')
--          + (partner fees) as recorded_dist;
-- C) Legacy reserve must be ZERO:
--   select count(*) from reserve_ledger;  -- expect 0 (no legacy reserve)


-- ##########################################################################
-- ###  SUMBER: phase3b_decisions.sql
-- ##########################################################################

-- ══════════════════════════════════════════════════════════════
-- PERKASA MOTORS — CFO SYSTEM · PHASE 3b (approved decisions)
-- RUN ORDER:  phase3_capital_seed.sql  →  THEN this file.
-- Additive & non-destructive. Original recorded values are never rewritten.
-- ══════════════════════════════════════════════════════════════

-- Settlement status marks HOW a unit's reserve/distribution was determined, so the
-- future engine can never retroactively recompute an already-recorded amount.
--   legacy_recorded      = old model, settled historically (no reserve)      -> engine SKIPS
--   transition_recorded  = current model, amount MANUALLY recorded (immutable) -> engine SKIPS
--   engine_settled       = settled automatically by the 10% engine
--   pending              = not yet settled (future sale)                      -> engine SETTLES
alter table units add column if not exists settlement_status text;
update units set settlement_status = case
  when status='terjual' then 'legacy_recorded'   -- all sold history is recorded, never auto-touched
  else 'pending' end
where settlement_status is null;

-- DECISION 2 — Reclassify #35/#37/#38 legacy → current (first units under the
-- new Perkasa Reserve model). Recorded values on `units` stay exactly as-is.
-- They are CURRENT for reporting, but their kas is TRANSITION_RECORDED (immutable):
update units set model_class='current', reserve_rate=0.10, settlement_status='transition_recorded'
where id in (35,37,38);

-- Represent their Kas/Reserve in the new architecture: post the ACTUAL recorded
-- kas_bisnis (NOT a recomputed 10%) as the first current retained-profit entries.
insert into reserve_ledger(tgl,tipe,arah,nominal,unit_id,keterangan)
select coalesce(u.tgl_jual::date,current_date),'retained_profit','in',u.kas_bisnis::numeric,u.id,
       'Retained reserve on first current unit (recorded value preserved)'
from units u
where u.id in (35,37,38) and coalesce(u.kas_bisnis::numeric,0) > 0
  and not exists (select 1 from reserve_ledger r where r.unit_id=u.id and r.tipe='retained_profit');

-- DECISION 3 — Unit #37 Rp50.000 unallocated variance: explicit, unassigned, visible.
create table if not exists settlement_variances (
  id         bigserial primary key,
  unit_id    bigint references units(id),
  amount     numeric not null,
  status     text not null default 'unresolved',   -- unresolved | resolved
  keterangan text default '',
  created_at timestamptz default now()
);
alter table settlement_variances enable row level security;
do $$ begin
  execute 'create policy allow_all_sv on settlement_variances for all to anon,authenticated using(true) with check(true)';
exception when duplicate_object then null; end $$;

insert into settlement_variances(unit_id,amount,status,keterangan)
select 37,50000,'unresolved',
  'Kas 800k + distribusi 7.650k = 8.450k vs profit 8.500k. Rp50.000 belum teralokasi (setara selisih kas 800k vs 10% = 850k). Tidak dibebankan ke pihak mana pun tanpa konfirmasi sumber.'
where not exists (select 1 from settlement_variances where unit_id=37);

-- DECISION 4 — Reivan identity: handled in seed via ILIKE '%reivan%'.
--   'Modal Reivan' -> reivan ; 'Reivan' -> reivan ; 'Modal' -> UNMAPPED (account_username stays null).
-- Enforce explicitly (idempotent), and guarantee 'Modal' remains unmapped:
update capital_accounts set account_username='reivan' where name ilike '%reivan%';
update capital_accounts set account_username=null    where name='Modal';


-- ##########################################################################
-- ###  SUMBER: phase4_settlement_engine.sql
-- ##########################################################################

-- ══════════════════════════════════════════════════════════════
-- PERKASA MOTORS — CFO SYSTEM · PHASE 4 · SETTLEMENT ENGINE  (v2, corrected)
-- Separates: Capital Funding  ≠  Unit Cost  ≠  Settlement cash flows.
-- A Reserve Advance is a FUNDING SOURCE. The expense it funds is UNIT COST
-- (counted once). The reimbursement is a CASH FLOW, never a 2nd deduction.
-- CURRENT units only. Legacy & transition_recorded units are excluded.
-- Additive; no recorded value is ever rewritten.
-- ══════════════════════════════════════════════════════════════

-- Create a Reserve Advance: reserve fronts cash for a unit expense.
-- Posts the expense OUT of reserve now; the expense becomes UNIT COST.
create or replace function pm_reserve_advance(p_unit_id bigint, p_kategori text, p_nominal numeric, p_ket text default '')
returns json language plpgsql security definer as $$
begin
  insert into reserve_advances(unit_id,tgl,kategori,nominal,keterangan,status)
    values (p_unit_id,current_date,p_kategori,p_nominal,p_ket,'outstanding');
  insert into reserve_ledger(tgl,tipe,arah,nominal,unit_id,keterangan)
    values (current_date,'advance','out',p_nominal,p_unit_id,'Reserve advance: '||p_kategori||' '||coalesce(p_ket,''));
  return json_build_object('ok',true,'unit',p_unit_id,'advance',p_nominal);
end; $$;

-- Eligibility: current model AND acquired on/after effective date AND pending.
create or replace function pm_settlement_eligible(p_unit_id bigint)
returns boolean language sql stable as $$
  select exists(
    select 1 from units u join financial_policy fp on fp.status='active'
    where u.id=p_unit_id and u.status='terjual' and u.model_class='current'
      and u.settlement_status='pending' and u.tgl >= fp.effective_date);
$$;

-- Core engine.
--   Unit Cost      = capital-funded costs (biaya_panji + biaya_pandu + partner funding)
--                    + advance-funded costs (Σ reserve_advances for the unit)
--   Realized Profit= Sale − Unit Cost                      (NO fee, NO advance re-deduction)
--   Reserve        = Profit × policy.rate                  → reserve_ledger retained_profit IN
--   Distributable  = Profit − Reserve
--   Fixed partner fee = paid FROM distributable (settlement to a capital provider)
--   Remainder      = split by participating capital (founders + profit-share partners)
--   Advances       = reimbursed to reserve (cash flow IN); expense already in Unit Cost
create or replace function pm_settle_unit(p_unit_id bigint)
returns json language plpgsql security definer as $$
declare
  u record; v_rate numeric; v_eff date;
  m_panji numeric; m_pandu numeric; m_partner numeric;
  adv_cost numeric; unit_cost numeric; profit numeric; reserve numeric;
  distributable numeric; fixed_fees numeric; dist_after_fixed numeric; part_cap numeric;
  a record; part jsonb; share numeric; sum_dist numeric := 0; residual numeric; proceeds_check numeric;
begin
  select * into u from units where id=p_unit_id;
  if not found                        then return json_build_object('ok',false,'error','unit not found'); end if;
  if u.status <> 'terjual'            then return json_build_object('ok',false,'error','unit belum terjual'); end if;
  if u.model_class <> 'current'       then return json_build_object('ok',false,'error','legacy unit — engine tidak menyentuh'); end if;
  if u.settlement_status <> 'pending' then return json_build_object('ok',false,'error','sudah final: '||coalesce(u.settlement_status,'-')); end if;
  select fp.rate, fp.effective_date into v_rate, v_eff
    from financial_policy as fp where fp.status='active' order by fp.effective_date desc limit 1;
  if v_rate is null  then return json_build_object('ok',false,'error','no active financial policy'); end if;
  if u.tgl < v_eff   then return json_build_object('ok',false,'error','acquired before effective date — legacy'); end if;

  -- Capital funding (also = capital-funded unit cost)
  select coalesce(sum((e->>'nominal')::numeric),0) into m_panji   from jsonb_array_elements(u.biaya_panji) e;
  select coalesce(sum((e->>'nominal')::numeric),0) into m_pandu   from jsonb_array_elements(u.biaya_pandu) e;
  select coalesce(sum((p->>'funding')::numeric),0) into m_partner from jsonb_array_elements(u.partners) p;
  -- Advance-funded expenses on this unit (part of UNIT COST, counted once)
  select coalesce(sum(nominal),0) into adv_cost from reserve_advances where unit_id=u.id;

  unit_cost     := m_panji + m_pandu + m_partner + adv_cost;
  profit        := (u.harga_jual::numeric) - unit_cost;          -- fee NOT deducted here
  reserve       := round(profit * v_rate);
  distributable := profit - reserve;

  -- Fixed partner fees are a SETTLEMENT distribution to capital providers, from distributable
  select coalesce(sum(case when p->>'feeType'='fixed'   then (p->>'feeValue')::numeric
                           when p->>'feeType'='percent' then (p->>'funding')::numeric*(p->>'feeValue')::numeric/100
                           else 0 end),0)
    into fixed_fees from jsonb_array_elements(u.partners) p;
  dist_after_fixed := distributable - fixed_fees;

  -- Participating capital = founders + profit-share partners
  part_cap := m_panji + m_pandu
            + coalesce((select sum((p->>'funding')::numeric) from jsonb_array_elements(u.partners) p
                        where p->>'feeType'='percent_profit'),0);

  -- 1) Reserve retention IN
  insert into reserve_ledger(tgl,tipe,arah,nominal,unit_id,keterangan)
    values (coalesce(u.tgl_jual::date,current_date),'retained_profit','in',reserve,u.id,
            'Auto reserve '||round(v_rate*100)||'% (engine)');

  -- 2) Reimburse outstanding advances (CASH FLOW back to reserve — not an expense)
  if adv_cost > 0 then
    insert into reserve_ledger(tgl,tipe,arah,nominal,unit_id,keterangan)
      select coalesce(u.tgl_jual::date,current_date),'reimbursement','in',
             coalesce(sum(nominal),0),u.id,'Advance reimbursed on sale (cash flow)'
      from reserve_advances where unit_id=u.id and status='outstanding';
    update reserve_advances set status='reimbursed',
           reimbursed_date=coalesce(u.tgl_jual::date,current_date), reimbursed_amount=nominal
      where unit_id=u.id and status='outstanding';
  end if;

  -- 3) Distribute
  for a in select * from capital_allocations where unit_id=u.id loop
    if a.kind='core_capital' then
      share := case when part_cap>0 then round(dist_after_fixed*a.amount/part_cap) else 0 end; sum_dist := sum_dist + share;
    elsif a.kind='partner_funding' then
      select p into part from jsonb_array_elements(u.partners) p
        where p->>'nama'=(select name from capital_accounts where id=a.account_id) limit 1;
      if (part->>'feeType')='percent_profit' then
        share := case when part_cap>0 then round(dist_after_fixed*a.amount/part_cap) else 0 end; sum_dist := sum_dist + share;
      elsif (part->>'feeType')='fixed'   then share := (part->>'feeValue')::numeric;                 -- paid from distributable
      elsif (part->>'feeType')='percent' then share := a.amount*(part->>'feeValue')::numeric/100;
      else share := 0; end if;
    else share := 0; end if;
    update capital_allocations set profit_share=share, status='settled' where id=a.id;
  end loop;

  -- 4) Rounding residual → explicit variance
  residual := dist_after_fixed - sum_dist;
  if residual <> 0 then
    insert into settlement_variances(unit_id,amount,status,keterangan)
      values (u.id,residual,'unresolved','Rounding residual on engine settlement');
  end if;

  -- 5) Authoritative computed values + mark settled (fresh unit — first write)
  update units set kas_bisnis=reserve, keuntungan_bersih=profit,
                   settlement_status='engine_settled', updated_at=now() where id=u.id;

  -- Proceeds invariant: capital returned + advance reimbursed + reserve + fixed + distributed = Sale
  proceeds_check := (m_panji+m_pandu+m_partner) + adv_cost + reserve + fixed_fees + sum_dist + residual;
  return json_build_object('ok',true,'unit',u.id,'unit_cost',unit_cost,'profit',profit,'reserve',reserve,
    'distributable',distributable,'fixed_fees',fixed_fees,'distributed',sum_dist,'residual',residual,
    'sale',u.harga_jual::numeric,'proceeds_reconcile',proceeds_check,
    'proceeds_ok',(proceeds_check = u.harga_jual::numeric));
end; $$;

grant execute on function pm_reserve_advance(bigint,text,numeric,text) to anon,authenticated;
grant execute on function pm_settlement_eligible(bigint)               to anon,authenticated;
grant execute on function pm_settle_unit(bigint)                       to anon,authenticated;

create or replace view v_reserve_summary as
select
  coalesce(sum(case when arah='in' then nominal else -nominal end),0)                    as reserve_balance,
  coalesce((select sum(nominal) from reserve_advances where status='outstanding'),0)      as deployed_reserve,
  coalesce(sum(case when arah='in' then nominal else -nominal end),0)
    - coalesce((select sum(nominal) from reserve_advances where status='outstanding'),0)  as available_reserve
from reserve_ledger;


-- ##########################################################################
-- ###  SUMBER: phase5_financial_statements.sql
-- ##########################################################################

-- ══════════════════════════════════════════════════════════════
-- PERKASA MOTORS — CFO SYSTEM · PHASE 5 · FINANCIAL STATEMENTS (views)
-- Management-accounting views. Additive, read-only. Encodes:
--  • Inventory = ECONOMIC UNIT COST (not funding source)
--  • Reserve = ring-fenced slice of cash (never added on top of cash)
--  • Reserve retention is a profit APPROPRIATION, never OpEx
--  • Capital return / advance reimbursement never touch P&L
-- ══════════════════════════════════════════════════════════════

-- Opening cash — explicit, unverified baseline; CFO edits later, no history rewrite.
insert into app_config(key,value) values
  ('opening_cash','0'),
  ('opening_cash_verified','false'),
  ('opening_cash_note','Opening cash balance — unverified system baseline'),
  ('opening_cash_date', current_date::text)
on conflict(key) do nothing;

-- ── Base: per-unit economics (single source the statements build on) ──
create or replace view v_unit_economics as
select u.id, u.nama, u.jenis, u.status, u.model_class, u.tgl::date acq_date, u.tgl_jual::date sale_date,
  u.harga_jual::numeric revenue,
  (select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(u.biaya_panji) e) cost_panji,
  (select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(u.biaya_pandu) e) cost_pandu,
  (select coalesce(sum((p->>'funding')::numeric),0) from jsonb_array_elements(u.partners) p) cost_partner,
  coalesce((select sum(nominal) from reserve_advances ra where ra.unit_id=u.id),0) cost_advance,
  -- ECONOMIC UNIT COST = what the money paid for (capital-funded + advance-funded)
  (select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(u.biaya_panji) e)
   +(select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(u.biaya_pandu) e)
   +(select coalesce(sum((p->>'funding')::numeric),0) from jsonb_array_elements(u.partners) p)
   +coalesce((select sum(nominal) from reserve_advances ra where ra.unit_id=u.id),0) unit_cost,
  (select coalesce(sum(case when p->>'feeType'='fixed' then (p->>'feeValue')::numeric
                            when p->>'feeType'='percent' then (p->>'funding')::numeric*(p->>'feeValue')::numeric/100
                            else 0 end),0) from jsonb_array_elements(u.partners) p) fixed_fees,
  coalesce(u.keuntungan_bersih::numeric,0) realized_profit,
  coalesce(u.kas_bisnis::numeric,0) reserve_recorded,
  case when u.status='terjual' then (u.tgl_jual::date-u.tgl::date) end holding_days
from units u;

-- ── 1) P&L — explicit two-tier hierarchy. Reserve retention is BELOW net profit. ──
create or replace view v_pnl as
with s as (select * from v_unit_economics where status='terjual'),
o as (select coalesce(sum(nominal),0) opex from kas_keluar where coalesce(tipe,'opex') in ('opex','sourcing_failed'))
select
  -- ── UNIT ECONOMICS ──
  (select sum(revenue) from s)                                as revenue,
  (select sum(unit_cost) from s)                              as economic_unit_cost_cogs,
  (select sum(revenue-unit_cost) from s)                      as gross_profit,
  (select sum(fixed_fees) from s)                             as unit_financing_partner_fees,
  (select sum(revenue-unit_cost-fixed_fees) from s)           as realized_unit_profit,     -- = Σ units.keuntungan_bersih (Rp131,80jt)
  -- ── COMPANY P&L ──
  (select opex from o)                                        as company_operating_expenses,
  (select sum(revenue-unit_cost-fixed_fees) from s)-(select opex from o) as net_operating_profit,  -- (Rp131,10jt)
  -- ── BELOW THE LINE (profit appropriation, NOT an expense) ──
  coalesce((select sum(nominal) from reserve_ledger where tipe='retained_profit'),0) as reserve_retention_appropriation,
  (select round(sum(revenue-unit_cost)/nullif(sum(revenue),0)*100,1) from s)         as gross_margin_pct;

-- ── 2) Cash Flow — actual cash movements; reserve movements shown separately ──
create or replace view v_cashflow as
select
  (select value::numeric from app_config where key='opening_cash')                                        as opening_cash,
  (select value from app_config where key='opening_cash_verified')                                        as opening_verified,
  -- inflows
  coalesce((select sum(revenue) from v_unit_economics where status='terjual'),0)                          as inflow_vehicle_sales,
  coalesce((select sum(amount) from capital_allocations),0)                                               as inflow_capital_received,
  -- outflows
  coalesce((select sum(unit_cost) from v_unit_economics),0)                                               as outflow_vehicle_and_unit_costs,
  coalesce((select sum(nominal) from kas_keluar),0)                                                       as outflow_operating_expenses,
  coalesce((select sum(nilai_beli) from aset_inventori),0)                                                as outflow_capex,
  coalesce((select sum(amount) from capital_allocations where status in ('returned','settled')),0)        as outflow_capital_returns,
  coalesce((select sum(profit_share) from capital_allocations),0)                                         as outflow_distributions,
  -- reserve movements (separate; retention is NOT an expense)
  coalesce((select sum(case when arah='in' then nominal else -nominal end) from reserve_ledger where tipe='retained_profit'),0) as reserve_retention,
  coalesce((select sum(nominal) from reserve_ledger where tipe='advance'),0)                              as reserve_advances,
  coalesce((select sum(nominal) from reserve_ledger where tipe='reimbursement'),0)                        as reserve_reimbursements;

-- ── 3) Balance Sheet (management accounting; reserve = ring-fenced slice of cash) ──
create or replace view v_balance_sheet as
select
  'management_accounting' as basis,
  (select value::numeric from app_config where key='opening_cash')                                          as total_cash_baseline,
  (select reserve_balance from v_reserve_summary)                                                           as ring_fenced_reserve,
  (select value::numeric from app_config where key='opening_cash') - (select reserve_balance from v_reserve_summary) as available_operating_cash,
  coalesce((select sum(unit_cost) from v_unit_economics where status<>'terjual'),0)                         as inventory_economic_cost,
  coalesce((select sum(nilai_skrg) from aset_inventori),0)                                                  as equipment_capex,
  -- capital / equity blocks (management labels; not statutory)
  coalesce((select sum(amount) from capital_allocations a join capital_accounts c on c.id=a.account_id where c.role='founder' and a.status='active'),0)  as founder_capital_active,
  coalesce((select sum(amount) from capital_allocations a join capital_accounts c on c.id=a.account_id where c.role<>'founder' and a.status='active'),0) as investor_capital_active,
  (select reserve_balance from v_reserve_summary)                                                           as perkasa_reserve_equity,
  coalesce((select sum(amount) from capital_allocations where status='active'),0)                           as outstanding_capital_obligations;

-- ── 4) Capital reconciliation: Funded = Deployed + Returned + Available ──
create or replace view v_capital_reconcile as
select c.name, c.role, c.funded, c.committed,
  coalesce(sum(a.amount) filter (where a.status='active'),0)                        as deployed,
  coalesce(sum(a.amount) filter (where a.status in ('returned','settled')),0)       as returned,
  c.funded - coalesce(sum(a.amount) filter (where a.status='active'),0)
           - coalesce(sum(a.amount) filter (where a.status in ('returned','settled')),0) as available,
  coalesce(sum(a.profit_share),0)                                                   as profit_received,
  c.committed - c.funded                                                           as unfunded_commitment
from capital_accounts c left join capital_allocations a on a.account_id=c.id
group by c.id,c.name,c.role,c.funded,c.committed;

-- ── 5) Reserve reconciliation: Opening + Retentions + Reimbursements − Advances − Spend = Closing ──
create or replace view v_reserve_reconcile as
select
  0::numeric as opening_reserve,
  coalesce(sum(nominal) filter (where tipe='retained_profit' and arah='in'),0)      as retentions,
  coalesce(sum(nominal) filter (where tipe='reimbursement' and arah='in'),0)        as reimbursements,
  coalesce(sum(nominal) filter (where tipe='advance' and arah='out'),0)             as advances_out,
  coalesce(sum(nominal) filter (where tipe in ('opex','capex','business_dev') and arah='out'),0) as reserve_spend,
  coalesce(sum(case when arah='in' then nominal else -nominal end),0)               as closing_reserve,
  coalesce((select sum(nominal) from reserve_advances where status='outstanding'),0) as outstanding_advances,
  coalesce(sum(case when arah='in' then nominal else -nominal end),0)
    - coalesce((select sum(nominal) from reserve_advances where status='outstanding'),0) as available_reserve
from reserve_ledger;

-- ── 6) Inventory valuation (economic cost of ACTIVE units only) ──
create or replace view v_inventory as
select id, nama, jenis, model_class, acq_date,
  unit_cost as economic_cost,
  (current_date - acq_date) as aging_days,
  cost_panji+cost_pandu+cost_partner as capital_deployed,
  cost_advance as reserve_advanced
from v_unit_economics where status<>'terjual';

-- ── 7) Profitability metrics (validated) ──
create or replace view v_profitability as
with s as (select * from v_unit_economics where status='terjual')
select
  count(*)                                                             as units_sold,
  round(avg(realized_profit))                                          as avg_profit_per_unit,
  round(avg(realized_profit/nullif(unit_cost,0)*100),1)               as avg_roi_pct,
  round(avg(revenue-unit_cost)/nullif(avg(revenue),0)*100,1)          as avg_margin_pct,
  percentile_cont(0.5) within group (order by holding_days)           as median_holding,
  round(avg(holding_days),1)                                          as mean_holding
from s;

grant select on v_unit_economics,v_pnl,v_cashflow,v_balance_sheet,v_capital_reconcile,
                v_reserve_reconcile,v_inventory,v_profitability to anon,authenticated;

-- ══════════════════════════════════════════════════════════════
-- RECONCILIATION ASSERTIONS (run after deploy; each must hold)
-- P&L:        (select sum(realized_profit) from v_unit_economics where status='terjual')  -- ties to units
-- Capital:    per row  funded = deployed + returned + available   (v_capital_reconcile)
-- Reserve:    closing_reserve = retentions + reimbursements - advances_out - reserve_spend
-- Inventory:  (select sum(economic_cost) from v_inventory) = Σ active unit economic cost
-- Distribution: distributable = Σ stakeholder profit_share  (enforced by engine + settlement_variances)
-- Cash:       opening_cash + net_movements = ending_cash    (once opening cash verified)
-- ══════════════════════════════════════════════════════════════


-- ##########################################################################
-- ###  SUMBER: phase6_investor_portfolio.sql
-- ##########################################################################

-- ══════════════════════════════════════════════════════════════
-- PERKASA MOTORS — CFO SYSTEM · PHASE 6 · INVESTOR CAPITAL & PORTFOLIO
-- Server-side views + reconciliation. Additive, read-only.
--
-- CAPITAL LIFECYCLE:  Committed → Funded → Available → Deployed
--                     → Returned → Available AGAIN
--   • Available  = Funded − Deployed   (returned capital re-enters Available)
--   • Returned   = lifetime cumulative capital that has cycled back (a counter,
--                  NOT part of the Funded identity)
--   • Invariant  : Funded = Deployed + Available   (per investor)
--   • Commitment is fixed; it is NEVER revenue, expense, inventory, or deployed.
--
--   NOTE on historical accounts: founders' `funded` was seeded as CUMULATIVE
--   allocations (no stated pool existed), so their Available/Returned reflect
--   lifetime revolving flows. For a NEW investor, set capital_accounts.committed
--   & .funded to the real pool and the lifecycle is exact.
--
-- ROI DEFINITIONS (documented, explicit):
--   realized_roi_pct   = realized_profit ÷ capital_returned × 100
--                        (profit per rupiah of capital that COMPLETED a cycle)
--   realized_multiple  = (capital_returned + realized_profit) ÷ capital_returned
--                        (realized MOIC on returned capital = 1 + realized ROI)
--   REALIZED and UNREALIZED are kept in separate columns — never mixed.
--
--   • Reserve is company-owned — NEVER investor capital/equity/profit.
--   • Reserve Advance is NOT an investor allocation.
--   • Legacy returns = recorded historical facts (never recomputed);
--     current returns = settlement engine (capital-based).
-- ══════════════════════════════════════════════════════════════

-- 1) Investor capital summary — lifecycle + realized/unrealized (per account)
create or replace view v_investor_summary as
with base as (
  select c.id, c.name, c.role, c.account_username, c.committed, c.funded,
    coalesce(sum(a.amount) filter (where a.status='active'),0)                  as deployed,
    coalesce(sum(a.amount) filter (where a.status in ('returned','settled')),0) as returned_cumulative,
    -- REALIZED (only on capital that has completed a cycle)
    coalesce(sum(a.profit_share) filter (where a.status in ('returned','settled')),0) as realized_profit,
    -- UNREALIZED expected profit on ACTIVE units (only where a target is set)
    coalesce(sum( (case when u.status<>'terjual' and (u.target_jual::numeric) > 0
                    then (u.target_jual::numeric - u.harga_beli::numeric) end)
                  * (a.amount / nullif((select sum(x.amount) from capital_allocations x where x.unit_id=u.id),0)) ),0) as expected_profit_active,
    count(a.*) filter (where a.amount>0 or a.profit_share>0)                    as units_total,
    count(a.*) filter (where a.status='active')                                as units_active,
    round(avg(case when u.status='terjual' then (u.tgl_jual::date-u.tgl::date) end),1) as avg_holding_days,
    coalesce(sum(a.profit_share) filter (where u.model_class='legacy'),0)       as profit_legacy,
    coalesce(sum(a.profit_share) filter (where u.model_class='current'),0)      as profit_current
  from capital_accounts c
  left join capital_allocations a on a.account_id=c.id
  left join units u on u.id=a.unit_id
  group by c.id,c.name,c.role,c.account_username,c.committed,c.funded
)
select *,
  -- LIFECYCLE
  (funded - deployed)                                        as available,          -- returned capital re-enters here
  deployed                                                   as current_exposure,
  -- REALIZED metrics
  returned_cumulative                                        as capital_returned,
  round(realized_profit / nullif(returned_cumulative,0)*100,1) as realized_roi_pct,
  round((returned_cumulative + realized_profit) / nullif(returned_cumulative,0),3) as realized_multiple
from base;

-- 2) Consolidated by mapped login (Reivan across 'Modal Reivan' + 'Reivan').
--    Unmapped accounts (e.g. 'Modal') stay separate — never merged.
create or replace view v_investor_summary_mapped as
select
  coalesce(account_username,'UNMAPPED: '||name) as investor_key,
  bool_or(account_username is not null)          as is_mapped,
  sum(committed) as committed, sum(funded) as funded,
  sum(deployed) as deployed, sum(available) as available,
  sum(capital_returned) as capital_returned, sum(current_exposure) as current_exposure,
  sum(realized_profit) as realized_profit,
  sum(expected_profit_active) as expected_profit_active,
  sum(profit_legacy) as profit_legacy, sum(profit_current) as profit_current,
  round(sum(realized_profit)/nullif(sum(capital_returned),0)*100,1) as realized_roi_pct
from v_investor_summary
group by coalesce(account_username,'UNMAPPED: '||name);

-- 3) Investor portfolio (per account × unit) — historical + current together
create or replace view v_investor_portfolio as
select
  c.name as investor, c.account_username, c.role,
  u.id as unit_id, u.nama as unit, u.model_class, u.status as unit_status,
  a.kind, a.amount as capital, a.status as allocation_status,
  round(case when (select sum(x.amount) from capital_allocations x where x.unit_id=u.id)>0
    then a.amount / (select sum(x.amount) from capital_allocations x where x.unit_id=u.id) * 100 else 0 end,2) as contribution_pct,
  u.harga_jual::numeric as unit_revenue,
  coalesce(u.keuntungan_bersih::numeric,0) as unit_profit,
  a.profit_share as investor_return,
  case when a.status in ('returned','settled') then 'realized' else 'unrealized' end as return_state,
  round(a.profit_share/nullif(a.amount,0)*100,1) as roi_pct,
  case when u.status='terjual' then (u.tgl_jual::date - u.tgl::date) end as holding_days,
  u.tgl::date as acq_date, u.tgl_jual::date as sale_date
from capital_allocations a
join capital_accounts c on c.id=a.account_id
join units u on u.id=a.unit_id
order by c.name, u.id;

-- 4) Reconciliation (all must read 0 / match)
create or replace view v_investor_recon as
select
  -- Lifecycle invariant: Funded = Deployed + Available (per investor)
  (select count(*) from v_investor_summary where round(funded)<>round(deployed+available)) as lifecycle_invariant_breaks,
  -- Σ unit allocations = capital-funded unit economic cost (per unit)
  (select count(*) from units u where
     round((select coalesce(sum(amount),0) from capital_allocations a where a.unit_id=u.id))
     <> round((select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(u.biaya_panji) e)
             +(select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(u.biaya_pandu) e)
             +(select coalesce(sum((p->>'funding')::numeric),0) from jsonb_array_elements(u.partners) p))
  ) as unit_capital_mismatches,
  -- Reserve advances must NOT appear as investor capital
  (select count(*) from capital_allocations where kind='reserve_advance') as reserve_advance_as_capital,
  -- Deployed total == active allocations total
  (select coalesce(sum(deployed),0) from v_investor_summary)                 as total_deployed,
  (select coalesce(sum(amount),0) from capital_allocations where status='active') as total_active_allocations,
  -- Realized profit total == recorded distribution total (preserved)
  (select round(coalesce(sum(realized_profit),0)) from v_investor_summary)   as total_realized_profit,
  (select round(coalesce(sum(profit_share),0)) from capital_allocations)     as total_distribution_recorded;

grant select on v_investor_summary, v_investor_summary_mapped, v_investor_portfolio, v_investor_recon to anon,authenticated;

-- ══════════════════════════════════════════════════════════════
-- LIVE VALIDATION (run after deploy; expect):
--   select * from v_investor_recon;
--     lifecycle_invariant_breaks = 0
--     unit_capital_mismatches    = 0
--     reserve_advance_as_capital = 0
--     total_deployed = total_active_allocations         (= 98,000,000)
--     total_realized_profit = total_distribution_recorded (= 171,909,600)
-- ══════════════════════════════════════════════════════════════


-- ##########################################################################
-- ###  SUMBER: phase7_funding_model.sql
-- ##########################################################################

-- ══════════════════════════════════════════════════════════════
-- PERKASA MOTORS — CFO SYSTEM · PHASE 7 · FUNDING MODEL & CAPACITY
-- Server-side views only. Additive, read-only. No historical data altered.
-- Distinguishes FUNDING NEED vs CAPACITY vs UTILIZATION.
-- Throughput- and holding-constrained — NOT profit × funding.
--
-- KEY REALITY (from data): median holding ≈ 4 days, mean ≈ 7.7 days ⇒ working
-- capital recycles ~28×/yr ⇒ the business needs LITTLE concurrent capital.
-- Therefore large funding is easily IDLE unless monthly throughput scales far
-- beyond the historical ~2.8 units/month. This model surfaces idle capital.
--
-- OPERATIONAL ASSUMPTIONS (explicit, documented, editable):
--   K  avg economic cost / unit          = 19,200,000  (= COGS ÷ sold, blended)
--      (motor-weighted ≈ 10,100,000 → ~1.9× more units per rupiah; see note)
--   H  mean holding days                 = 7.7   (median 4)
--   PU realized profit / unit            = 3,380,000
--   M  realized margin                   = 0.197
--   T0 historical throughput / month     = 2.75  (39 sold ÷ 14.2 months)
--   RR reserve rate                      = 0.10
--   Peak concurrent capital (observed)   = 98,900,000   (validated Phase-1)
--   Avg deployed capital (active-days)   = 22,690,000
-- WIP (Little's law): concurrent_units = throughput_per_month × (H ÷ 30)
-- ══════════════════════════════════════════════════════════════

-- 1) CURRENT OPERATING CAPACITY (traceable to unit-level data)
create or replace view v_funding_capacity as
with s as (select * from v_unit_economics where status='terjual'),
p as (select (max(sale_date)-min(acq_date))::numeric/30.44 as months from s)
select
  (select count(*) from s)                                          as sold_units,
  round((select count(*) from s)/nullif((select months from p),0),2) as throughput_per_month,
  round((select count(*) from s)/nullif((select months from p),0)*12) as throughput_per_year,
  round((select avg(unit_cost) from s))                             as avg_cost_per_unit,
  round((select avg(unit_cost) from s where jenis='Motor'))         as avg_cost_motor,
  round((select avg(unit_cost) from s where jenis='Mobil'))         as avg_cost_mobil,
  (select round(percentile_cont(0.5) within group(order by holding_days)) from s) as median_holding,
  round((select avg(holding_days) from s),1)                        as mean_holding,
  round((select avg(realized_profit) from s))                       as realized_profit_per_unit,
  round((select avg(realized_profit/nullif(revenue,0)) from s)*100,1) as realized_margin_pct,
  98900000::numeric                                                 as peak_concurrent_capital,   -- validated Phase-1
  22690000::numeric                                                 as avg_deployed_capital,       -- validated Phase-1
  coalesce((select sum(unit_cost) from v_unit_economics where status<>'terjual'),0) as current_inventory_value,
  -- legacy vs current split
  count(*) filter (where model_class='legacy') over ()             as legacy_sold,
  count(*) filter (where model_class='current') over ()            as current_sold
from s limit 1;

-- 2) FUNDING SCENARIOS — funding × operational-throughput ceiling.
--    actual_throughput = LEAST(capital-enabled, ops ceiling)  ⇒ idle capital exposed.
create or replace view v_funding_scenarios as
with param as (select 19200000::numeric K, 7.7::numeric H, 3380000::numeric PU, 0.10::numeric RR),
funding as (select unnest(array[100000000,150000000,250000000,500000000]::numeric[]) F),
ops as (select * from (values ('current (2.75/mo)',2.75),('scaled 2x (5.5/mo)',5.5),('scaled 4x (11/mo)',11.0)) as t(ops_label,T)),
x as (
  select f.F, o.ops_label, o.T, pr.K, pr.H, pr.PU, pr.RR,
    (f.F/pr.K)                                          as capital_enabled_concurrent,
    (f.F/pr.K)*30/pr.H                                  as capital_enabled_throughput_mo,
    least((f.F/pr.K)*30/pr.H, o.T)                      as actual_throughput_mo
  from funding f cross join ops o cross join param pr
)
select F as funding, ops_label, round(T,2) as ops_ceiling_mo,
  round(capital_enabled_concurrent,1)                  as capital_enabled_concurrent,
  round(capital_enabled_throughput_mo,1)               as capital_enabled_throughput_mo,
  round(actual_throughput_mo,2)                         as actual_throughput_mo,
  round(actual_throughput_mo*H/30,1)                    as actual_concurrent_units,
  round(actual_throughput_mo*H/30*K)                    as deployed_capital,
  round(F - actual_throughput_mo*H/30*K)                as idle_capital,
  round(actual_throughput_mo*H/30*K / nullif(F,0)*100) as utilization_pct,
  round(actual_throughput_mo*12)                        as annual_throughput,
  round(actual_throughput_mo*12*PU)                     as annual_realized_profit,
  round(actual_throughput_mo*12*PU*RR)                  as annual_reserve_retention,
  round(actual_throughput_mo*12*PU*(1-RR))              as annual_investor_distributable,
  -- OPERATING metrics (company-level; denominators labelled). NOT investor ROI.
  round(actual_throughput_mo*12*PU / nullif(actual_throughput_mo*H/30*K,0)*100) as operating_roi_on_deployed_pct,  -- business profit ÷ DEPLOYED operating capital
  round(actual_throughput_mo*12*PU / nullif(F,0)*100)   as business_profit_to_funding_pct                          -- business profit ÷ FUNDING (context only, not a return to any single party)
from x order by F, T;

-- 3) CAPITAL UTILIZATION at 50 / 75 / 100% (how much funding is actually deployed)
create or replace view v_funding_utilization as
with funding as (select unnest(array[100000000,150000000,250000000,500000000]::numeric[]) F),
u as (select unnest(array[0.50,0.75,1.00]::numeric[]) util)
select f.F as funding, (u.util*100)::int as utilization_target_pct,
  round(f.F*u.util)             as deployed_capital,
  round(f.F*(1-u.util))         as idle_capital,
  round(f.F*u.util/19200000,1)  as implied_concurrent_units,
  round(f.F*u.util/19200000*30/7.7,1) as implied_throughput_mo,
  case when f.F*u.util/19200000*30/7.7 > 2.75*2 then 'requires major ops scaling'
       when f.F*u.util/19200000*30/7.7 > 2.75   then 'requires ops scaling'
       else 'within ~historical ops' end as feasibility
from funding f cross join u order by f.F, u.util;

-- 4) STRESS TEST — sensitivities on a BASE case (Rp150M, ops scaled 2x = 5.5/mo)
create or replace view v_funding_stress_test as
with b as (select 150000000::numeric F, 5.5::numeric T, 19200000::numeric K,
                  7.7::numeric H, 3380000::numeric PU, 0.197::numeric M),
scen as (select * from (values
  ('Base',                       1.00, 1.00, 1.00, 1.00),
  ('A holding +25%',             1.25, 1.00, 1.00, 1.00),
  ('B holding +50%',             1.50, 1.00, 1.00, 1.00),
  ('C margin -20%',              1.00, 0.80, 1.00, 1.00),
  ('D margin -30%',              1.00, 0.70, 1.00, 1.00),
  ('E throughput -25%',          1.00, 1.00, 0.75, 1.00),
  ('F maint cost +25%',          1.00, 0.90, 1.00, 1.06),  -- higher cost: -margin ~10%, +unit cost ~6%
  ('G combined downside',        1.50, 0.70, 0.75, 1.06)
) as t(scenario, hold_mult, margin_mult, tput_mult, cost_mult))
select s.scenario,
  round(b.T*s.tput_mult,2)                                  as throughput_mo,
  round(b.H*s.hold_mult,1)                                  as holding_days,
  round(b.PU*s.margin_mult)                                 as profit_per_unit,
  round(b.T*s.tput_mult*12)                                 as annual_units,
  round(b.T*s.tput_mult*12*b.PU*s.margin_mult)              as annual_profit,
  round(b.T*s.tput_mult*(b.H*s.hold_mult)/30*b.K*s.cost_mult) as deployed_capital,
  round(b.T*s.tput_mult*(b.H*s.hold_mult)/30*b.K*s.cost_mult / b.F*100) as utilization_pct,
  round(b.T*s.tput_mult*12*b.PU*s.margin_mult
        / nullif(b.T*s.tput_mult*(b.H*s.hold_mult)/30*b.K*s.cost_mult,0)*100) as roi_on_deployed_pct
from b cross join scen s;

-- ── Configurable funding/commercial assumptions (editable; NOT final terms) ──
-- These EXPOSE the parameters instead of hardcoding them. Reserve rate is NOT
-- duplicated here — it is read from financial_policy (single source, unchanged 10%).
create table if not exists funding_assumptions (
  key text primary key, value numeric not null, label text default '', updated_at timestamptz default now()
);
insert into funding_assumptions(key,value,label) values
  ('founder_mgmt_share', 0.00,     'Founder management/sourcing share of DISTRIBUTABLE profit — NOT finalized (placeholder 0%)'),
  ('ops_ceiling_mo',     5.50,     'Modeled sustainable throughput ceiling, units/month (≈2× historical)'),
  ('avg_cost_per_unit',  19200000, 'Blended economic cost/unit (= COGS ÷ sold)'),
  ('mean_holding_days',  7.70,     'Mean holding period, days'),
  ('profit_per_unit',    3380000,  'Realized profit per unit')
on conflict (key) do nothing;
alter table funding_assumptions enable row level security;
do $$ begin
  execute 'create policy allow_all_fa on funding_assumptions for all to anon,authenticated using(true) with check(true)';
exception when duplicate_object then null; end $$;

-- 5) INVESTOR FUNDING ECONOMICS — EXPLICIT denominators, CONFIGURABLE sharing.
--    investor_dist_share = 1 − founder_mgmt_share  (they split the 90% distributable).
--    Defaults: founder_mgmt_share = 0 ⇒ investor 100% (ILLUSTRATIVE capital-only).
--    Reserve rate read from financial_policy (company-owned; never investor profit).
--    Investor earns ONLY on DEPLOYED capital; idle capital earns nothing.
create or replace view v_investor_funding_economics as
with cfg as (
  select
    (select value from funding_assumptions where key='avg_cost_per_unit')  as K,
    (select value from funding_assumptions where key='mean_holding_days')  as H,
    (select value from funding_assumptions where key='profit_per_unit')    as PU,
    (select rate from financial_policy where status='active' order by effective_date desc limit 1) as RR,
    (select value from funding_assumptions where key='ops_ceiling_mo')     as T,
    (select value from funding_assumptions where key='founder_mgmt_share') as founder_share,
    1 - (select value from funding_assumptions where key='founder_mgmt_share') as investor_dist_share
),
funding as (select unnest(array[100000000,150000000,250000000,500000000]::numeric[]) F),
y as (
  select f.F, c.K,c.H,c.PU,c.RR,c.T,c.founder_share,c.investor_dist_share,
         least((f.F/c.K)*30/c.H, c.T)                                as tput,
         least(f.F, round(least((f.F/c.K)*30/c.H, c.T)*c.H/30*c.K))  as inv_deployed
  from funding f cross join cfg c
)
select F as funding,
  inv_deployed                                                        as deployed,
  round(F - inv_deployed)                                             as idle_capital,
  round(inv_deployed/nullif(F,0)*100)                                as utilization_pct,
  round(tput*12*PU)                                                   as annual_business_profit,
  round(tput*12*PU*RR)                                                as reserve_retention,
  round(tput*12*PU*(1-RR))                                            as distributable_profit,
  founder_share                                                       as founder_mgmt_share,
  investor_dist_share                                                 as investor_share_of_distributable,
  round(tput*12*PU*(1-RR)*investor_dist_share)                        as investor_realized_profit,
  round(tput*12*PU*(1-RR)*founder_share)                             as founder_mgmt_profit,
  -- ── ROI metrics with EXPLICIT denominators ──
  round(tput*12*PU / nullif(inv_deployed,0)*100)                     as operating_roi_on_deployed_pct,     -- BUSINESS profit ÷ deployed (company)
  round(tput*12*PU*(1-RR)*investor_dist_share / nullif(F,0)*100)     as investor_roi_on_funded_pct,        -- investor profit ÷ FUNDED
  round(tput*12*PU*(1-RR)*investor_dist_share / nullif(inv_deployed,0)*100) as investor_roi_on_deployed_pct, -- investor profit ÷ DEPLOYED
  round(1 + tput*12*PU*(1-RR)*investor_dist_share / nullif(F,0),2)   as investor_return_multiple_on_funded,
  round(H,1)                                                          as holding_days,
  case when founder_share=0
    then 'Illustrative capital-only scenario — commercial profit-sharing terms not finalized'
    else 'Configured: investor '||round(investor_dist_share*100)||'% / founder mgmt '||round(founder_share*100)||'% of distributable'
  end                                                                 as scenario_label
from y order by F;

-- 6) FUNDING RECOMMENDATION (data-driven range; assumptions explicit)
create or replace view v_funding_recommendation as
select * from (values
  ('Minimum viable', 50000000::numeric, 75000000::numeric,
   'Smooths current ops incl. the occasional peak (observed peak deployed Rp98.9jt when a mobil overlapped motors). Motor-weighted; ~3-4 concurrent.'),
  ('Optimal / base', 100000000, 150000000,
   'Supports ~2-3x throughput growth (5.5-8 units/mo), motor-weighted, with reserve Rp30jt + opcash buffer. Requires modest sourcing/sales scaling.'),
  ('Maximum prudent', 200000000, 250000000,
   'Supports ~4x throughput (≈11 units/mo) — requires MAJOR ops scaling (sourcing team + channels). Above this, capital is likely idle.'),
  ('Not recommended', 500000000, 500000000,
   'Would need ~15-25 concurrent units / ~15-20 sales per month (5-7x historical). No near-term operational basis; large idle-capital risk.')
) as t(tier, low, high, rationale);

-- 7) CASH SAFETY (operating cash ≠ reserve ≠ inventory capital; no double count)
create or replace view v_funding_cash_safety as
select
  10000000::numeric  as operating_cash_buffer,   -- ~6 months opex at recent run-rate
  120000000::numeric as inventory_funding_base,   -- base-scenario working capital
  30000000::numeric  as reserve_target,           -- separate, ring-fenced
  10000000 + 120000000 + 30000000 as total_business_funding_requirement_base;

grant select on v_funding_capacity, v_funding_scenarios, v_funding_utilization,
                v_funding_stress_test, v_investor_funding_economics,
                v_funding_recommendation, v_funding_cash_safety to anon,authenticated;
grant select, insert, update on funding_assumptions to anon,authenticated;

-- ── Reconfigure commercial terms WITHOUT touching the view or historical data ──
--   Give founders a 40% management share (investor auto-becomes 60%):
--     update funding_assumptions set value=0.40 where key='founder_mgmt_share';
--   Change modeled throughput ceiling:
--     update funding_assumptions set value=8.0 where key='ops_ceiling_mo';
--   Reserve rate is NOT here — it stays in financial_policy (unchanged 10%).

-- ══════════════════════════════════════════════════════════════
-- RECONCILIATION ASSERTIONS (traceable to unit-level data)
--  • v_funding_capacity.throughput_per_month  ≈ 2.75  (39 ÷ 14.2 months)
--  • v_funding_capacity.avg_cost_per_unit      = 19,200,000 (= COGS ÷ 39)
--  • Scenario deployed_capital ≤ funding  AND  idle_capital = funding − deployed
--  • Investor economics use 90% (after 10% reserve); reserve never in investor capital
--  • Every metric derives from v_unit_economics (unit-level) + documented params
-- ══════════════════════════════════════════════════════════════


-- ##########################################################################
-- ###  SUMBER: phase8_ui_support.sql
-- ##########################################################################

-- ══════════════════════════════════════════════════════════════
-- PERKASA MOTORS — CFO SYSTEM · PHASE 8 · UI SUPPORT (views + RPC)
-- Additive, read-only. Keeps ALL calculation in the DB (single source of
-- truth) so the new UI never re-derives financials in the frontend.
-- ══════════════════════════════════════════════════════════════

-- Dynamic funding simulator for ANY amount (frontend passes p_funding).
-- Reads configurable assumptions + financial_policy. No hardcoded terms.
create or replace function pm_funding_sim(p_funding numeric)
returns json language plpgsql stable as $$
declare K numeric; H numeric; PU numeric; RR numeric; T numeric; fs numeric; ids numeric;
  cap_conc numeric; cap_tput numeric; tput numeric; deployed numeric;
  biz numeric; reserve numeric; dist numeric; inv_profit numeric; founder_profit numeric;
begin
  select value into K  from funding_assumptions where key='avg_cost_per_unit';
  select value into H  from funding_assumptions where key='mean_holding_days';
  select value into PU from funding_assumptions where key='profit_per_unit';
  select value into T  from funding_assumptions where key='ops_ceiling_mo';
  select value into fs from funding_assumptions where key='founder_mgmt_share';
  select rate into RR  from financial_policy where status='active' order by effective_date desc limit 1;
  if K is null then return json_build_object('ok',false,'error','funding_assumptions not deployed'); end if;
  ids := 1 - coalesce(fs,0);
  cap_conc := p_funding / K;
  cap_tput := cap_conc*30/H;
  tput := least(cap_tput, T);
  deployed := round(tput*H/30*K);
  biz := round(tput*12*PU);
  reserve := round(biz*RR);
  dist := round(biz*(1-RR));
  inv_profit := round(dist*ids);
  founder_profit := round(dist*coalesce(fs,0));
  return json_build_object('ok',true,
    'funding',p_funding,'deployed',deployed,'idle',round(p_funding-deployed),
    'utilization_pct',round(deployed/nullif(p_funding,0)*100),
    'capital_enabled_concurrent',round(cap_conc,1),
    'capital_enabled_throughput_mo',round(cap_tput,1),
    'actual_throughput_mo',round(tput,2),'ops_ceiling_mo',T,
    'required_throughput_mo',round(cap_tput,1),
    'capacity_gap_mo',round(greatest(cap_tput - T,0),1),
    'annual_business_profit',biz,'reserve_retention',reserve,'distributable_profit',dist,
    'founder_mgmt_share',coalesce(fs,0),'investor_share_of_distributable',ids,
    'investor_realized_profit',inv_profit,'founder_mgmt_profit',founder_profit,
    'operating_roi_on_deployed_pct',round(biz/nullif(deployed,0)*100),
    'investor_roi_on_funded_pct',round(inv_profit/nullif(p_funding,0)*100),
    'investor_roi_on_deployed_pct',round(inv_profit/nullif(deployed,0)*100),
    'investor_return_multiple_on_funded',round(1+inv_profit/nullif(p_funding,0),2),
    'scenario_label',case when coalesce(fs,0)=0
      then 'Illustrative capital-only scenario — commercial profit-sharing terms not finalized'
      else 'Investor '||round(ids*100)||'% / founder mgmt '||round(coalesce(fs,0)*100)||'% of distributable' end);
end; $$;
grant execute on function pm_funding_sim(numeric) to anon,authenticated;

-- Single-row Command Center KPI aggregate (pulls from validated views)
create or replace view v_command_center as
select
  (select reserve_balance from v_reserve_summary)                       as reserve_balance,
  (select available_reserve from v_reserve_summary)                     as available_reserve,
  (select deployed_reserve from v_reserve_summary)                      as deployed_reserve,
  (select coalesce(sum(economic_cost),0) from v_inventory)              as inventory_at_cost,
  (select coalesce(sum(funded),0) from v_investor_summary)              as capital_funded,
  (select coalesce(sum(deployed),0) from v_investor_summary)            as capital_deployed,
  (select coalesce(sum(available),0) from v_investor_summary)           as capital_available,
  (select coalesce(sum(capital_returned),0) from v_investor_summary)    as capital_returned,
  (select realized_unit_profit from v_pnl)                             as realized_profit,
  (select net_operating_profit from v_pnl)                             as net_operating_profit,
  (select revenue from v_pnl)                                          as revenue,
  (select gross_margin_pct from v_pnl)                                 as gross_margin_pct,
  (select units_sold from v_profitability)                            as units_sold,
  (select mean_holding from v_profitability)                          as mean_holding,
  (select median_holding from v_profitability)                        as median_holding,
  (select round(throughput_per_month,2) from v_funding_capacity)      as throughput_mo,
  (select value::numeric from app_config where key='opening_cash')     as opening_cash,
  (select value from app_config where key='opening_cash_verified')     as opening_cash_verified,
  (select count(*) from units where status<>'terjual')                 as active_units,
  (select count(*) from v_investor_summary where role<>'founder' and current_exposure>0) as active_investors,
  (select coalesce(sum(current_exposure),0) from v_investor_summary where role<>'founder') as investor_exposure,
  (select coalesce(sum(realized_profit),0) from v_investor_summary where role<>'founder')  as investor_realized_profit,
  30000000::numeric                                                    as reserve_target,
  (select rate from financial_policy where status='active' order by effective_date desc limit 1) as reserve_rate,
  -- open items surfaced (never hidden)
  (select coalesce(sum(amount),0) from settlement_variances where status='unresolved') as unresolved_variance,
  (select count(*) from capital_accounts where account_username is null and role<>'founder') as unmapped_accounts;

-- P&L split by legacy vs current (for the P&L filter — one source, filtered)
create or replace view v_pnl_by_class as
with s as (select * from v_unit_economics where status='terjual')
select model_class,
  sum(revenue) as revenue, sum(unit_cost) as cogs, sum(revenue-unit_cost) as gross_profit,
  sum(fixed_fees) as unit_financing_fees, sum(revenue-unit_cost-fixed_fees) as realized_unit_profit,
  count(*) as units
from s group by model_class;

grant select on v_command_center, v_pnl_by_class to anon,authenticated;

