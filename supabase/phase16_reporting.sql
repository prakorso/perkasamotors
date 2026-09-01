-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 16 · D6 REPORTING ARCHITECTURE  (additive, DB-derived)
-- Five STRICTLY SEPARATED layers (never summed into one "available capital"):
--   Company Equity → v_company_capital        (founder capital + retained; NOT cash)
--   Financing/Debt → v_financing               (liability; NOT equity/cash)
--   Partner Funding→ v_external_unit_funding    (external; NOT Perkasa cash)  [D4]
--   Cash/Liquidity → v_cash_position            (the ONLY basis for available cash)
--   Unit Economics → v_unit_cost/funding/settlement                         [D3–D5]
-- Unified P&L (legacy+future, deduped) + Period vs As-of via parameterized fns.
-- Legacy accounting untouched. Future reserve = 0. No auto-distribution.
-- ══════════════════════════════════════════════════════════════════════════

-- ── Company Equity (structure, NOT cash) ──
create or replace view v_company_capital as
select
  coalesce((select sum(funded) from capital_accounts where role='founder'),0)   as founder_capital,
  coalesce((select total_retained from v_retained_profit),0)                     as retained_profit,
  coalesce((select sum(funded) from capital_accounts where role='founder'),0)
    + coalesce((select total_retained from v_retained_profit),0)                 as total_equity;

-- ── Financing / Debt (liability, company-level over v_debt_summary) ──
create or replace view v_financing as
select
  coalesce(sum(outstanding_principal),0)                                as debt_outstanding_principal,
  coalesce(sum(outstanding_total),0)                                    as debt_outstanding_total,
  coalesce(sum(interest_paid),0)                                        as interest_paid,
  coalesce(sum(principal),0)                                            as total_principal,
  (select min(next_due_date) from v_debt_summary where status<>'paid_off')            as next_due_date,
  coalesce((select sum(next_due_amount) from v_debt_summary where status<>'paid_off'),0) as next_due_amount,
  count(*) filter (where status<>'paid_off')                           as active_facilities
from v_debt_summary;

-- ── Cash / Liquidity — the single source for Actual & Available cash ──
-- Actual = existing cash-pool base (opening + debt draw − debt/payroll paid)
--          − Perkasa capital deployed on ACTIVE units (cash currently out)
--          + Perkasa realized (settled units net = perkasa_retained_profit).
-- Partner capital NEVER added. Equity/Debt-principal NEVER added as spendable.
-- Deployed & Available are DISTINCT from Actual.
create or replace view v_cash_position as
with base as (select * from v_cash_pool),
 dep as (
   select coalesce(sum(f.amount),0) as deployed
   from unit_funding f join units u on u.id=f.unit_id
   where f.source='perkasa' and coalesce(u.funding_model,'legacy')='perkasa' and u.status<>'terjual'
 ),
 setl as (select coalesce(sum(perkasa_retained_profit),0) as realized from unit_settlement where status='settled')
select
  b.opening_cash, b.reserve, b.debt_due, b.payroll_due, b.other_committed, b.is_provisional,
  d.deployed                                                                     as deployed_capital,
  (b.opening_cash + b.debt_drawdowns - b.debt_paid - b.payroll_paid - d.deployed + s.realized) as actual_cash,
  ((b.opening_cash + b.debt_drawdowns - b.debt_paid - b.payroll_paid - d.deployed + s.realized)
     - b.reserve - b.debt_due - b.payroll_due - b.other_committed)               as available_cash
from base b, dep d, setl s;

-- ── Unified P&L base (legacy + future, deduped by funding_model) ──
-- retained_profit = Perkasa's kept profit (legacy net / future perkasa_retained).
create or replace view v_unit_pnl_unified as
-- legacy retained uses the VALIDATED basis (revenue − unit_cost − fixed_fees) so
-- Σ legacy = v_pnl.realized_unit_profit exactly (ties to v_retained_profit).
select 'legacy'::text as source, e.id as unit_id, e.nama, e.sale_date as pnl_date,
       e.revenue, e.unit_cost as base_cost, 0::numeric as selling_cost,
       (e.revenue - e.unit_cost - e.fixed_fees) as true_profit,
       (e.revenue - e.unit_cost - e.fixed_fees) as retained_profit, false as is_loss
from v_unit_economics e where e.status='terjual'
union all
select 'future'::text, s.unit_id, u.nama, s.settle_date,
       s.selling_price, s.base_unit_cost_snap, s.selling_cost,
       s.true_unit_profit, s.perkasa_retained_profit, s.is_loss
from unit_settlement s join units u on u.id=s.unit_id where s.status='settled';

-- ── Period P&L (parameterized). Homepage Period Profit = unit_retained (Legacy+Future). ──
create or replace function fn_pnl(p_from date, p_to date)
returns json language sql stable as $$
  with u as (select * from v_unit_pnl_unified where pnl_date between p_from and p_to)
  select json_build_object(
    'from',p_from,'to',p_to,
    'revenue',        coalesce((select sum(revenue) from u),0),
    'base_cost',      coalesce((select sum(base_cost) from u),0),
    'selling_cost',   coalesce((select sum(selling_cost) from u),0),
    'true_profit',    coalesce((select sum(true_profit) from u),0),
    'partner_fee',    coalesce((select sum(true_profit-retained_profit) from u where source='future'),0),
    'unit_retained',  coalesce((select sum(retained_profit) from u),0),           -- Legacy+Future (homepage Period Profit)
    'legacy_retained',coalesce((select sum(retained_profit) from u where source='legacy'),0),
    'future_retained',coalesce((select sum(retained_profit) from u where source='future'),0),
    'opex',           coalesce((select sum(nominal) from kas_keluar where tgl between p_from and p_to),0),
    'interest',       coalesce((select sum(interest_component) from debt_payments where status='paid' and paid_date between p_from and p_to),0),
    'payroll',        coalesce((select sum(paid_amount) from payroll_payments where paid_date between p_from and p_to),0),
    'period_net',
      coalesce((select sum(retained_profit) from u),0)
      - coalesce((select sum(nominal) from kas_keluar where tgl between p_from and p_to),0)
      - coalesce((select sum(interest_component) from debt_payments where status='paid' and paid_date between p_from and p_to),0)
      - coalesce((select sum(paid_amount) from payroll_payments where paid_date between p_from and p_to),0)
  );
$$;

-- ── As-of Position (point-in-time balances; never sums a period) ──
create or replace function fn_position(p_asof date)
returns json language sql stable as $$
  select json_build_object(
    'as_of',p_asof,
    'actual_cash',      (select actual_cash from v_cash_position),
    'available_cash',   (select available_cash from v_cash_position),
    'deployed_capital', (select deployed_capital from v_cash_position),
    'is_provisional',   (select is_provisional from v_cash_position),
    'liabilities',      (select total_liabilities from v_liabilities),
    'debt_outstanding', (select debt_outstanding_principal from v_financing),
    'debt_next_due_date',(select next_due_date from v_financing),
    'debt_next_due_amount',(select next_due_amount from v_financing),
    'partner_exposure', coalesce((select sum(outstanding_external_capital) from v_external_unit_funding),0),
    'equity',           (select total_equity from v_company_capital),
    'retained_profit',  (select total_retained from v_retained_profit),
    'active_units',     (select count(*) from units where status<>'terjual')
  );
$$;

-- ── Cashflow over period ──
create or replace function fn_cashflow(p_from date, p_to date)
returns json language sql stable as $$
  select json_build_object(
    'from',p_from,'to',p_to,
    'inflow_sales',
        coalesce((select sum(harga_jual::numeric) from units where status='terjual' and coalesce(funding_model,'legacy')='legacy' and tgl_jual between p_from and p_to),0)
      + coalesce((select sum(selling_price) from unit_settlement where status='settled' and settle_date between p_from and p_to),0),
    'inflow_debt_draw', coalesce((select sum(principal) from debts where drawdown_date between p_from and p_to),0),
    'outflow_opex',     coalesce((select sum(nominal) from kas_keluar where tgl between p_from and p_to),0),
    'outflow_debt',     coalesce((select sum(paid_amount) from debt_payments where status='paid' and paid_date between p_from and p_to),0),
    'outflow_payroll',  coalesce((select sum(paid_amount) from payroll_payments where paid_date between p_from and p_to),0),
    'outflow_deploy',   coalesce((select sum(f.amount) from unit_funding f where f.source='perkasa' and f.funded_date between p_from and p_to),0),
    'outflow_partner_settle', coalesce((select sum(capital_return_partner+partner_fee) from unit_settlement where status='settled' and settle_date between p_from and p_to),0)
  );
$$;

-- ── Unit performance over period (unified) ──
create or replace function fn_unit_performance(p_from date, p_to date)
returns json language sql stable as $$
  select coalesce(json_agg(t order by t.pnl_date desc),'[]'::json) from (
    select p.source, p.unit_id, p.nama, p.pnl_date, p.revenue, p.base_cost, p.selling_cost,
           p.true_profit, p.retained_profit, p.is_loss,
           coalesce(f.perkasa_funding,0) as perkasa_funding, coalesce(f.partner_funding,0) as partner_funding
    from v_unit_pnl_unified p left join v_unit_funding f on f.unit_id=p.unit_id
    where p.pnl_date between p_from and p_to
  ) t;
$$;

-- ── Capital rotation over period ──
create or replace function fn_capital_rotation(p_from date, p_to date)
returns json language sql stable as $$
  select json_build_object(
    'from',p_from,'to',p_to,
    'deployed',  coalesce((select sum(amount) from unit_funding where source='perkasa' and funded_date between p_from and p_to),0),
    'returned',  coalesce((select sum(capital_return_perkasa) from unit_settlement where status='settled' and settle_date between p_from and p_to),0),
    'available', (select available_cash from v_cash_position)
  );
$$;

-- ── grants ──
grant select on v_company_capital, v_financing, v_cash_position, v_unit_pnl_unified to anon,authenticated;
grant execute on function fn_pnl(date,date)              to anon,authenticated;
grant execute on function fn_position(date)              to anon,authenticated;
grant execute on function fn_cashflow(date,date)         to anon,authenticated;
grant execute on function fn_unit_performance(date,date) to anon,authenticated;
grant execute on function fn_capital_rotation(date,date) to anon,authenticated;
