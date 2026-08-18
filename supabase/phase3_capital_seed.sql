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
