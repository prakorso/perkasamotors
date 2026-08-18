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
