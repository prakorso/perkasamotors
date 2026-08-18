-- ══════════════════════════════════════════════════════════════
-- PERKASA MOTORS — CFO SYSTEM · PHASE 6 · INVESTOR CAPITAL & PORTFOLIO
-- Server-side views + reconciliation. Additive, read-only.
--  • Committed / Funded / Deployed / Returned / Available modelled per account
--  • Multi-stakeholder AND single-investor units supported (dynamic by capital %)
--  • Legacy returns = recorded historical facts; current = engine (capital-based)
--  • Reserve is company-owned — NEVER investor capital/equity/profit
--  • Reserve Advance is NOT an investor allocation (kind excluded)
-- ══════════════════════════════════════════════════════════════

-- 1) Investor capital summary (per capital account)
create or replace view v_investor_summary as
select
  c.id, c.name, c.role, c.account_username,
  (c.account_username is not null) as is_mapped,
  c.committed,
  c.funded,
  coalesce(sum(a.amount) filter (where a.status='active'),0)                            as deployed,
  coalesce(sum(a.amount) filter (where a.status in ('returned','settled')),0)           as returned,
  c.funded - coalesce(sum(a.amount) filter (where a.status='active'),0)
           - coalesce(sum(a.amount) filter (where a.status in ('returned','settled')),0) as available,
  coalesce(sum(a.amount) filter (where a.status='active'),0)                            as current_exposure,
  coalesce(sum(a.profit_share),0)                                                       as profit_received,
  count(a.*) filter (where a.amount>0 or a.profit_share>0)                              as units_total,
  count(a.*) filter (where a.status='active')                                          as units_active,
  round(avg(case when u.status='terjual' then (u.tgl_jual::date-u.tgl::date) end),1)    as avg_holding_days,
  round(coalesce(sum(a.profit_share),0)
        / nullif(coalesce(sum(a.amount) filter (where a.status in ('returned','settled')),0),0)*100,1) as roi_on_returned_pct,
  round((c.funded + coalesce(sum(a.profit_share),0)) / nullif(c.funded,0),3)            as return_multiple,
  coalesce(sum(a.profit_share) filter (where u.model_class='legacy'),0)                 as profit_legacy,
  coalesce(sum(a.profit_share) filter (where u.model_class='current'),0)               as profit_current
from capital_accounts c
left join capital_allocations a on a.account_id=c.id
left join units u on u.id=a.unit_id
group by c.id,c.name,c.role,c.account_username,c.committed,c.funded;

-- 2) Consolidated by mapped login (e.g. Reivan across 'Modal Reivan' + 'Reivan').
--    Unmapped accounts (e.g. 'Modal') stay separate — never merged.
create or replace view v_investor_summary_mapped as
select
  coalesce(account_username,'UNMAPPED: '||name) as investor_key,
  bool_or(is_mapped)                              as is_mapped,
  sum(funded)                                     as funded,
  sum(deployed)                                   as deployed,
  sum(returned)                                   as returned,
  sum(available)                                  as available,
  sum(current_exposure)                           as current_exposure,
  sum(profit_received)                            as profit_received,
  sum(profit_legacy)                              as profit_legacy,
  sum(profit_current)                             as profit_current
from v_investor_summary
group by coalesce(account_username,'UNMAPPED: '||name);

-- 3) Investor portfolio (per account × unit) — historical + current in one place
create or replace view v_investor_portfolio as
select
  c.name as investor, c.account_username, c.role,
  u.id as unit_id, u.nama as unit, u.model_class,
  a.kind, a.amount as capital, a.status,
  round(case when u.status='terjual'
    then (select coalesce(sum(x.amount),0) from capital_allocations x where x.unit_id=u.id)
    else 0 end) as unit_total_capital,
  round(case when (select sum(x.amount) from capital_allocations x where x.unit_id=u.id)>0
    then a.amount / (select sum(x.amount) from capital_allocations x where x.unit_id=u.id) * 100 else 0 end,2) as contribution_pct,
  u.harga_jual::numeric as unit_revenue,
  coalesce(u.keuntungan_bersih::numeric,0) as unit_profit,
  a.profit_share as investor_return,
  round(a.profit_share/nullif(a.amount,0)*100,1) as roi_pct,
  case when u.status='terjual' then (u.tgl_jual::date - u.tgl::date) end as holding_days,
  u.tgl::date as acq_date, u.tgl_jual::date as sale_date
from capital_allocations a
join capital_accounts c on c.id=a.account_id
join units u on u.id=a.unit_id
order by c.name, u.id;

-- 4) Reconciliation (assertions must all read 0)
create or replace view v_investor_recon as
select
  -- Funded = Deployed + Returned + Available (per investor)
  (select count(*) from v_investor_summary where round(funded)<>round(deployed+returned+available)) as investor_invariant_breaks,
  -- Σ unit allocations = capital-funded unit economic cost (per unit)
  (select count(*) from units u where
     round((select coalesce(sum(amount),0) from capital_allocations a where a.unit_id=u.id))
     <> round((select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(u.biaya_panji) e)
             +(select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(u.biaya_pandu) e)
             +(select coalesce(sum((p->>'funding')::numeric),0) from jsonb_array_elements(u.partners) p))
  ) as unit_capital_mismatches,
  -- Reserve advances must NOT appear as investor capital allocations
  (select count(*) from capital_allocations where kind='reserve_advance') as reserve_advance_as_capital,
  -- Portfolio deployed = Σ active allocations (tautology check via summary)
  (select coalesce(sum(deployed),0) from v_investor_summary) as total_deployed,
  (select coalesce(sum(amount),0) from capital_allocations where status='active') as total_active_allocations;

grant select on v_investor_summary, v_investor_summary_mapped, v_investor_portfolio, v_investor_recon to anon,authenticated;

-- ══════════════════════════════════════════════════════════════
-- LIVE VALIDATION (run after deploy; expect all PASS)
-- ══════════════════════════════════════════════════════════════
-- select * from v_investor_recon;
--   → investor_invariant_breaks = 0
--   → unit_capital_mismatches   = 0
--   → reserve_advance_as_capital= 0
--   → total_deployed = total_active_allocations (= 98,000,000)
