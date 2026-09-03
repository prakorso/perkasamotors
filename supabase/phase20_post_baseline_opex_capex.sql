-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 20 · D10 · POST-BASELINE OPEX + CAPEX IN LIQUIDITY
-- STATUS: PREPARED — NOT YET EXECUTED (awaiting explicit apply authorization).
--
-- Smallest additive change: make the DERIVED liquidity position also subtract
-- paid OPEX and CAPEX that occur STRICTLY AFTER the opening baseline date,
-- exactly mirroring how debt_paid / payroll_paid are already filtered
-- (`> baseline_date`). Pre-baseline OPEX/CAPEX are NOT subtracted — they belong
-- to the (unverified) opening balance / D11 reconciliation.
--
-- WHY: today post-baseline OPEX = Rp0 and post-baseline CAPEX = Rp0, so the
-- current numbers DO NOT change. This only ensures FUTURE post-baseline OPEX
-- (kas_keluar) and asset purchases (aset_inventori) correctly reduce Operating /
-- Total Liquidity going forward.
--
-- INVARIANTS PRESERVED:
--   • Cash Reserve is UNTOUCHED (reserve is a separate term; Operating =
--     actual_cash − reserve, so OPEX/CAPEX reduce Operating, never Reserve).
--   • Perkasa net-capital-cycle logic (− deployed + realized) unchanged.
--   • No legacy vehicle cash, founder/partner capital, or unsold-unit direct
--     costs are added here — those remain D11.
--   • No double counting: kas_keluar and aset_inventori do not overlap
--     debt_paid / payroll_paid / deployed / realized.
-- Additive only: two new exposed columns + two extra subtraction terms.
-- ══════════════════════════════════════════════════════════════════════════

create or replace view v_cash_pool as
with anchor as (
  select coalesce(nullif((select value from app_config where key='opening_cash_date'),'')::date, '1900-01-01'::date) as baseline_date
), base as (
  select (select baseline_date from anchor) as baseline_date,
    coalesce((select total_cash_baseline from v_balance_sheet),0::numeric) as opening_cash,
    coalesce((select reserve_balance from v_reserve_summary),0::numeric) as reserve,
    coalesce((select value from app_config where key='opening_cash_verified'),'false') as opening_verified,
    coalesce((select value::numeric from app_config where key='other_committed_cash'),0::numeric) as other_committed,
    coalesce((select sum(principal) from debts where drawdown_date is not null and drawdown_date > (select baseline_date from anchor)),0::numeric) as debt_drawdowns,
    coalesce((select sum(paid_amount) from debt_payments where status='paid' and paid_date > (select baseline_date from anchor)),0::numeric) as debt_paid,
    coalesce((select sum(paid_amount) from payroll_payments where paid_date > (select baseline_date from anchor)),0::numeric) as payroll_paid,
    -- D10 phase20: post-baseline paid OPEX (kas_keluar) and CAPEX (aset_inventori)
    coalesce((select sum(nominal) from kas_keluar where tgl > (select baseline_date from anchor)),0::numeric) as opex_paid,
    coalesce((select sum(nilai_beli) from aset_inventori where tgl > (select baseline_date from anchor)),0::numeric) as capex_paid,
    coalesce((select value::integer from app_config where key='obligation_horizon_days'),30) as horizon_days,
    coalesce((select sum(scheduled_amount) from debt_payments where status<>'paid' and due_date <= (current_date + coalesce((select value::integer from app_config where key='obligation_horizon_days'),30))),0::numeric) as debt_due,
    coalesce((select sum(computed_amount) from payroll_obligations where status<>'paid' and due_date <= (current_date + coalesce((select value::integer from app_config where key='obligation_horizon_days'),30))),0::numeric) as payroll_due
)
select baseline_date, opening_cash, reserve, opening_verified, other_committed,
  debt_drawdowns, debt_paid, payroll_paid, opex_paid, capex_paid,
  horizon_days, debt_due, payroll_due,
  opening_cash + debt_drawdowns - debt_paid - payroll_paid - opex_paid - capex_paid as actual_cash,
  opening_cash + debt_drawdowns - debt_paid - payroll_paid - opex_paid - capex_paid
    - reserve - debt_due - payroll_due - other_committed as safe_cash,
  opening_verified <> 'true' as is_provisional
from base;

create or replace view v_cash_position as
with base as (
  select baseline_date, opening_cash, reserve, opening_verified, other_committed,
    debt_drawdowns, debt_paid, payroll_paid, opex_paid, capex_paid,
    horizon_days, debt_due, payroll_due, actual_cash, safe_cash, is_provisional
  from v_cash_pool
), dep as (
  select coalesce(sum(f.amount),0::numeric) as deployed
  from unit_funding f join units u on u.id=f.unit_id
  where f.source='perkasa' and coalesce(u.funding_model,'legacy')='perkasa' and u.status<>'terjual'
), setl as (
  select coalesce(sum(perkasa_retained_profit),0::numeric) as realized
  from unit_settlement where status='settled'
)
select b.opening_cash, b.reserve, b.debt_due, b.payroll_due, b.other_committed, b.is_provisional,
  b.opex_paid, b.capex_paid,
  d.deployed as deployed_capital,
  b.opening_cash + b.debt_drawdowns - b.debt_paid - b.payroll_paid - b.opex_paid - b.capex_paid - d.deployed + s.realized as actual_cash,
  b.opening_cash + b.debt_drawdowns - b.debt_paid - b.payroll_paid - b.opex_paid - b.capex_paid - d.deployed + s.realized
    - b.reserve - b.debt_due - b.payroll_due - b.other_committed as available_cash
from base b, dep d, setl s;

grant select on v_cash_pool, v_cash_position to anon, authenticated;
