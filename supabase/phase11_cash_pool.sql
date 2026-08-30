-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 11 · CASH POOL / SAFE CASH / CONSOLIDATED LIABILITIES
-- Additive, non-destructive. Reuses validated views — nothing recomputed here.
--   • Reserve       = v_reserve_summary (SINGLE source, ring-fenced)
--   • Cash base      = v_balance_sheet.total_cash_baseline (opening cash, config)
--   • Inventory is NOT subtracted from cash (cash already left at purchase).
--   • Principal repayment already excluded from P&L (phase 9).
--   • Safe Cash is PROVISIONAL until opening cash is verified.
-- ══════════════════════════════════════════════════════════════════════════

-- Config: other committed cash (editable; default 0). Opening cash keys already exist.
insert into app_config(key,value)
  select 'other_committed_cash','0'
  where not exists(select 1 from app_config where key='other_committed_cash');

-- Configurable near-term horizon (days) for "Debt Due / Payroll Due" set-aside.
-- Default 30; change the value to re-tune without editing this view.
insert into app_config(key,value)
  select 'obligation_horizon_days','30'
  where not exists(select 1 from app_config where key='obligation_horizon_days');

-- BASELINE ANCHOR for Safe Cash. Cash movements (debt drawdowns / debt payments /
-- payroll payments) dated ON OR BEFORE this date are assumed already reflected in
-- opening_cash and are NOT re-counted — the guard against data-entry double-count.
-- Empty = unset ⇒ anchor at 1900-01-01 (count all movements, conservative).
-- Set this to the date the opening_cash balance was measured, then verify.
insert into app_config(key,value)
  select 'opening_cash_date',''
  where not exists(select 1 from app_config where key='opening_cash_date');

-- ── fee_payments: moves the partner-fee "paid" flag OUT of localStorage into DB ──
create table if not exists fee_payments (
  id           bigserial primary key,
  unit_id      bigint references units(id) on delete cascade,
  partner_name text not null,
  amount       numeric not null default 0,
  paid_date    date default current_date,
  created_at   timestamptz default now()
);
create index if not exists idx_fee_payments_unit on fee_payments(unit_id);

-- Partner-fee PAYABLE = fixed/percent partner fees on SOLD units − recorded payments.
-- Mirrors the app's feeOf() exactly (percent_profit partners are NOT fees — excluded).
create or replace view v_partner_fee_payable as
with owed as (
  select u.id as unit_id, (p->>'nama') as partner_name,
    case p->>'feeType'
      when 'fixed'   then coalesce((p->>'feeValue')::numeric,0)
      when 'percent' then coalesce((p->>'funding')::numeric,0)*coalesce((p->>'feeValue')::numeric,0)/100
      else 0 end as owed
  from units u, jsonb_array_elements(u.partners) p
  where u.status='terjual'
),
paid as (select unit_id, partner_name, sum(amount) as paid from fee_payments group by unit_id,partner_name)
select o.unit_id, o.partner_name, o.owed,
  coalesce(pd.paid,0) as paid,
  o.owed - coalesce(pd.paid,0) as payable
from owed o left join paid pd on pd.unit_id=o.unit_id and pd.partner_name=o.partner_name
where o.owed > 0;

-- ── CONSOLIDATED LIABILITIES (single row, DB-backed) ──
create or replace view v_liabilities as
select
  coalesce((select sum(outstanding_total) from v_debt_summary where status<>'cancelled'),0)  as debt_outstanding,
  coalesce((select sum(outstanding_total) from v_payroll_summary),0)                          as payroll_outstanding,
  coalesce((select sum(payable) from v_partner_fee_payable where payable>0),0)                as partner_fee_payable,
  coalesce((select sum(outstanding_total) from v_debt_summary where status<>'cancelled'),0)
  + coalesce((select sum(outstanding_total) from v_payroll_summary),0)
  + coalesce((select sum(payable) from v_partner_fee_payable where payable>0),0)              as total_liabilities;

-- ── UPCOMING OBLIGATIONS (debt installments + payroll due), nearest first ──
create or replace view v_upcoming_obligations as
  select 'debt'::text as type, p.id as ref_id, d.name as name,
         p.due_date, p.scheduled_amount as amount, p.status
  from debt_payments p join debts d on d.id=p.debt_id
  where p.status <> 'paid'
union all
  select 'payroll'::text, o.id, pe.name || ' — ' || o.period_ym,
         o.due_date, o.computed_amount, o.status
  from payroll_obligations o join payroll_people pe on pe.id=o.person_id
  where o.status <> 'paid';

-- ── CASH POOL / WATERFALL (single row) ──
-- Horizon for "Due" = overdue OR due within 30 days (near-term set-aside).
create or replace view v_cash_pool as
with anchor as (
  -- baseline date; empty/unset ⇒ 1900-01-01 (count all movements)
  select coalesce(nullif((select value from app_config where key='opening_cash_date'),'')::date,
                  '1900-01-01'::date) as baseline_date
),
base as (
  select
    (select baseline_date from anchor)                                               as baseline_date,
    coalesce((select total_cash_baseline from v_balance_sheet),0)                    as opening_cash,
    coalesce((select reserve_balance from v_reserve_summary),0)                       as reserve,
    coalesce((select value from app_config where key='opening_cash_verified'),'false') as opening_verified,
    coalesce((select value::numeric from app_config where key='other_committed_cash'),0) as other_committed,
    -- movements are counted ONLY if dated AFTER the baseline (anti double-count)
    coalesce((select sum(principal) from debts
       where drawdown_date is not null and drawdown_date > (select baseline_date from anchor)),0) as debt_drawdowns,
    coalesce((select sum(paid_amount) from debt_payments
       where status='paid' and paid_date > (select baseline_date from anchor)),0)    as debt_paid,
    coalesce((select sum(paid_amount) from payroll_payments
       where paid_date > (select baseline_date from anchor)),0)                       as payroll_paid,
    coalesce((select value::int from app_config where key='obligation_horizon_days'),30) as horizon_days,
    coalesce((select sum(scheduled_amount) from debt_payments
       where status<>'paid' and due_date <= current_date
         + coalesce((select value::int from app_config where key='obligation_horizon_days'),30)),0) as debt_due,
    coalesce((select sum(computed_amount) from payroll_obligations
       where status<>'paid' and due_date <= current_date
         + coalesce((select value::int from app_config where key='obligation_horizon_days'),30)),0) as payroll_due
)
select *,
  (opening_cash + debt_drawdowns - debt_paid - payroll_paid)                          as actual_cash,
  (opening_cash + debt_drawdowns - debt_paid - payroll_paid)
    - reserve - debt_due - payroll_due - other_committed                              as safe_cash,
  (opening_verified <> 'true')                                                        as is_provisional
from base;

create or replace view v_safe_cash as select * from v_cash_pool;

grant select on v_partner_fee_payable, v_liabilities, v_upcoming_obligations,
                v_cash_pool, v_safe_cash to anon,authenticated;

alter table fee_payments enable row level security;
do $$ begin execute 'create policy allow_all_fee_payments on fee_payments for all to anon,authenticated using(true) with check(true)'; exception when duplicate_object then null; end $$;
grant select,insert,update,delete on fee_payments to anon,authenticated;
grant usage,select on sequence fee_payments_id_seq to anon,authenticated;

-- ── VALIDATION ──
--   select * from v_cash_pool;   -- inspect each waterfall step; is_provisional=true until opening cash verified
--   select * from v_liabilities; -- debt + payroll + partner_fee = total_liabilities
--   -- Invariant: safe_cash = actual_cash − reserve − debt_due − payroll_due − other_committed
--   -- Inventory is intentionally ABSENT from this formula (no double subtraction).
