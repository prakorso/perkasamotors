-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 23 · Debt net/fee + D10 baseline fix + unit archive
-- STATUS: applied to production per explicit implementation approval.
-- Additive & backward-compatible. Preserves all legacy/settlement/reserve data.
--
-- (2) DEBT: add nullable net_disbursed + fee so liability (principal) stays gross
--     while cash views use NET cash received. Debt #3 (BLU BCA) recorded:
--     principal 74,700,000 · net_disbursed 73,200,000 · fee 1,500,000.
-- (12) D10 BASELINE FIX: cash formula now uses NET debt and a BASELINE-FILTERED
--     deployed term, so unit #75 (funded 2026-08-17, pre-baseline) is no longer
--     treated as a post-baseline cash outflow. deployed_capital (position, all
--     unsold) is kept for display; a separate deployed_post_baseline (flow) drives
--     the cash formula. No double counting (purchase=funding once; sale/return once).
-- (11) UNIT ARCHIVE: units.archived_at (nullable) enables soft-delete/archive for
--     units with accounting dependencies WITHOUT dropping FKs or deleting history.
-- Nothing here rewrites legacy economics, settlements, reserve, or founder capital.
-- ══════════════════════════════════════════════════════════════════════════

-- ── (2) DEBT fields ──
alter table debts add column if not exists net_disbursed numeric;   -- actual bank cash received (null → principal-fee)
alter table debts add column if not exists fee           numeric;   -- bank/admin/financing fee
update debts set net_disbursed = 73200000, fee = 1500000 where id = 3 and net_disbursed is null;

-- ── (11) UNIT archive flag ──
alter table units add column if not exists archived_at timestamptz;

-- ── v_debt_summary: expose net_disbursed/fee (append) ──
create or replace view v_debt_summary as
 SELECT d.id, d.name, d.lender, d.debt_type, d.status, d.principal, d.total_obligation,
    d.interest_total, d.installment_amount, d.tenor_months, d.start_date, d.first_due_date, d.drawdown_date,
    COALESCE(sum(p.paid_amount), 0::numeric) AS paid_total,
    d.total_obligation - COALESCE(sum(p.paid_amount), 0::numeric) AS outstanding_total,
    COALESCE(sum(p.principal_component) FILTER (WHERE p.status = 'paid'), 0::numeric) AS principal_paid,
    d.principal - COALESCE(sum(p.principal_component) FILTER (WHERE p.status = 'paid'), 0::numeric) AS outstanding_principal,
    COALESCE(sum(p.interest_component) FILTER (WHERE p.status = 'paid'), 0::numeric) AS interest_paid,
    count(p.*) FILTER (WHERE p.status = 'paid') AS payments_paid,
    count(p.*) AS payments_total,
    ( SELECT min(x.due_date) FROM debt_payments x WHERE x.debt_id = d.id AND x.status <> 'paid') AS next_due_date,
    ( SELECT x.scheduled_amount FROM debt_payments x WHERE x.debt_id = d.id AND x.status <> 'paid' ORDER BY x.due_date LIMIT 1) AS next_due_amount,
    COALESCE(d.net_disbursed, d.principal - COALESCE(d.fee,0)) AS net_disbursed,
    COALESCE(d.fee,0) AS fee
   FROM debts d LEFT JOIN debt_payments p ON p.debt_id = d.id
  GROUP BY d.id;
grant select on v_debt_summary to anon, authenticated;

-- ── v_financing: expose totals for net cash + fee (append) ──
create or replace view v_financing as
 SELECT COALESCE(sum(outstanding_principal), 0::numeric) AS debt_outstanding_principal,
    COALESCE(sum(outstanding_total), 0::numeric) AS debt_outstanding_total,
    COALESCE(sum(interest_paid), 0::numeric) AS interest_paid,
    COALESCE(sum(principal), 0::numeric) AS total_principal,
    ( SELECT min(v.next_due_date) FROM v_debt_summary v WHERE v.status <> 'paid_off') AS next_due_date,
    COALESCE(( SELECT sum(v.next_due_amount) FROM v_debt_summary v WHERE v.status <> 'paid_off'), 0::numeric) AS next_due_amount,
    count(*) FILTER (WHERE status <> 'paid_off') AS active_facilities,
    COALESCE(sum(net_disbursed), 0::numeric) AS total_net_disbursed,
    COALESCE(sum(fee), 0::numeric) AS total_fee
   FROM v_debt_summary;
grant select on v_financing to anon, authenticated;

-- ── v_cash_pool: use NET debt (post-baseline) in the cash formula; expose gross + net + fee ──
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
    coalesce((select sum(coalesce(net_disbursed, principal - coalesce(fee,0))) from debts where drawdown_date is not null and drawdown_date > (select baseline_date from anchor)),0::numeric) as debt_net_drawdowns,
    coalesce((select sum(coalesce(fee,0)) from debts where drawdown_date is not null and drawdown_date > (select baseline_date from anchor)),0::numeric) as debt_fee,
    coalesce((select sum(paid_amount) from debt_payments where status='paid' and paid_date > (select baseline_date from anchor)),0::numeric) as debt_paid,
    coalesce((select sum(paid_amount) from payroll_payments where paid_date > (select baseline_date from anchor)),0::numeric) as payroll_paid,
    coalesce((select sum(nominal) from kas_keluar where tgl > (select baseline_date from anchor)),0::numeric) as opex_paid,
    coalesce((select sum(nilai_beli) from aset_inventori where tgl > (select baseline_date from anchor)),0::numeric) as capex_paid,
    coalesce((select value::integer from app_config where key='obligation_horizon_days'),30) as horizon_days,
    coalesce((select sum(scheduled_amount) from debt_payments where status<>'paid' and due_date <= (current_date + coalesce((select value::integer from app_config where key='obligation_horizon_days'),30))),0::numeric) as debt_due,
    coalesce((select sum(computed_amount) from payroll_obligations where status<>'paid' and due_date <= (current_date + coalesce((select value::integer from app_config where key='obligation_horizon_days'),30))),0::numeric) as payroll_due
)
select baseline_date, opening_cash, reserve, opening_verified, other_committed,
  debt_drawdowns, debt_paid, payroll_paid,
  horizon_days, debt_due, payroll_due,
  opening_cash + debt_net_drawdowns - debt_paid - payroll_paid - opex_paid - capex_paid as actual_cash,
  opening_cash + debt_net_drawdowns - debt_paid - payroll_paid - opex_paid - capex_paid
    - reserve - debt_due - payroll_due - other_committed as safe_cash,
  opening_verified <> 'true' as is_provisional,
  opex_paid, capex_paid, debt_net_drawdowns, debt_fee
from base;

-- ── v_cash_position: net debt + baseline-filtered deployed/realized; keep deployed_capital (position) ──
create or replace view v_cash_position as
with base as (
  select baseline_date, opening_cash, reserve, opening_verified, other_committed,
    debt_drawdowns, debt_net_drawdowns, debt_fee, debt_paid, payroll_paid, opex_paid, capex_paid,
    horizon_days, debt_due, payroll_due, actual_cash, safe_cash, is_provisional
  from v_cash_pool
), dep as (   -- POSITION: all unsold perkasa funding
  select coalesce(sum(f.amount),0::numeric) as deployed
  from unit_funding f join units u on u.id=f.unit_id
  where f.source='perkasa' and coalesce(u.funding_model,'legacy')='perkasa' and u.status<>'terjual'
), dep_post as (   -- FLOW: only perkasa funding deployed AFTER baseline (excludes pre-baseline #75)
  select coalesce(sum(f.amount),0::numeric) as deployed_post
  from unit_funding f join units u on u.id=f.unit_id
  where f.source='perkasa' and coalesce(u.funding_model,'legacy')='perkasa' and u.status<>'terjual'
    and f.funded_date > (select baseline_date from v_cash_pool)
), setl as (   -- realized perkasa profit from settlements AFTER baseline
  select coalesce(sum(perkasa_retained_profit),0::numeric) as realized
  from unit_settlement where status='settled'
    and settle_date > (select baseline_date from v_cash_pool)
)
select b.opening_cash, b.reserve, b.debt_due, b.payroll_due, b.other_committed, b.is_provisional,
  d.deployed as deployed_capital,
  b.opening_cash + b.debt_net_drawdowns - b.debt_paid - b.payroll_paid - b.opex_paid - b.capex_paid - dp.deployed_post + s.realized as actual_cash,
  b.opening_cash + b.debt_net_drawdowns - b.debt_paid - b.payroll_paid - b.opex_paid - b.capex_paid - dp.deployed_post + s.realized
    - b.reserve - b.debt_due - b.payroll_due - b.other_committed as available_cash,
  b.opex_paid, b.capex_paid, dp.deployed_post as deployed_post_baseline, b.debt_net_drawdowns, b.debt_fee
from base b, dep d, dep_post dp, setl s;

grant select on v_cash_pool, v_cash_position to anon, authenticated;
