-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 9 · DEBT MANAGEMENT  (additive, non-destructive)
-- Debt is a Cash-Management feature, not a top-level page. Records are DB-backed.
-- ACCOUNTING:
--   • Full installment paid  → CASH OUT (feeds cash pool, phase 11)
--   • interest_component     → FINANCE EXPENSE (P&L)
--   • principal_component    → reduces DEBT LIABILITY, NEVER a P&L expense
-- INVARIANTS:
--   principal        = Σ principal_component (all rows)
--   total_obligation = Σ scheduled_amount    = paid_total + outstanding_total
--   outstanding_principal = principal − Σ principal_component(paid)
-- No hardcoded amounts — every field is entered per debt.
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists debts (
  id                bigserial primary key,
  name              text not null,
  lender            text default '',
  debt_type         text default '',              -- bank | koperasi | pribadi | leasing | lainnya
  principal         numeric not null default 0,   -- borrowed amount (cash IN when drawn)
  total_obligation  numeric not null default 0,   -- principal + total interest (0 ⇒ auto = installment×tenor)
  interest_total    numeric default 0,            -- = total_obligation − principal (auto-filled)
  interest_rate     numeric,                       -- optional, informational
  tenor_months      int not null default 1,
  installment_amount numeric not null default 0,
  start_date        date,
  first_due_date    date,
  due_day           int,
  drawdown_date     date,                          -- when cash was received (null ⇒ pre-existing, no new inflow)
  status            text not null default 'active',-- active | paid_off | cancelled
  notes             text default '',
  created_at        timestamptz default now(),
  updated_at        timestamptz default now()
);

create table if not exists debt_payments (
  id                  bigserial primary key,
  debt_id             bigint not null references debts(id) on delete cascade,
  payment_no          int not null,
  due_date            date,
  scheduled_amount    numeric not null default 0,
  principal_component numeric not null default 0,
  interest_component  numeric not null default 0,
  paid_amount         numeric not null default 0,
  paid_date           date,
  status              text not null default 'scheduled', -- scheduled | due | paid | overdue
  created_at          timestamptz default now(),
  unique(debt_id, payment_no)
);
create index if not exists idx_debt_payments_debt on debt_payments(debt_id);
create index if not exists idx_debt_payments_due  on debt_payments(due_date);

-- ── Build the amortization schedule from the debt profile ──
-- Splits each installment into principal + interest, stored per row (source of
-- truth in DB, not JS). Regenerates ONLY while no payment has been made yet.
create or replace function pm_debt_build_schedule(p_debt_id bigint)
returns json language plpgsql as $$
declare d record; n int; i int; tot numeric; inttot numeric;
  int_i numeric; prin_i numeric; sum_prin numeric := 0; sum_int numeric := 0;
  due date;
begin
  select * into d from debts where id = p_debt_id;
  if not found then return json_build_object('ok',false,'error','debt not found'); end if;
  if exists(select 1 from debt_payments where debt_id=p_debt_id and (status='paid' or paid_amount>0)) then
    return json_build_object('ok',false,'error','ada pembayaran tercatat — schedule tidak diregenerasi');
  end if;
  delete from debt_payments where debt_id = p_debt_id;

  n := greatest(d.tenor_months, 1);
  tot := case when coalesce(d.total_obligation,0) > 0 then d.total_obligation
              else d.installment_amount * n end;
  inttot := greatest(tot - coalesce(d.principal,0), 0);
  due := coalesce(d.first_due_date, d.start_date, current_date);

  for i in 1..n loop
    if i < n then
      int_i  := round(inttot / n);
      prin_i := round(d.installment_amount) - int_i;
      sum_int := sum_int + int_i; sum_prin := sum_prin + prin_i;
    else
      -- last row absorbs rounding so invariants tie out EXACTLY
      prin_i := coalesce(d.principal,0) - sum_prin;
      int_i  := tot - coalesce(d.principal,0) - sum_int;
    end if;
    insert into debt_payments(debt_id,payment_no,due_date,scheduled_amount,
                              principal_component,interest_component,status)
      values (p_debt_id, i,
              (due + ((i-1)||' month')::interval)::date,
              prin_i + int_i, prin_i, int_i, 'scheduled');
  end loop;

  update debts set total_obligation = tot, interest_total = inttot, updated_at = now()
    where id = p_debt_id;
  return json_build_object('ok',true,'debt',p_debt_id,'rows',n,
    'total_obligation',tot,'interest_total',inttot);
end; $$;

-- ── Record a payment (principal/interest already split on the row) ──
create or replace function pm_debt_pay(p_payment_id bigint, p_amount numeric default null, p_date date default null)
returns json language plpgsql as $$
declare r record; amt numeric;
begin
  select * into r from debt_payments where id = p_payment_id;
  if not found then return json_build_object('ok',false,'error','payment not found'); end if;
  amt := coalesce(p_amount, r.scheduled_amount);
  update debt_payments
     set paid_amount = amt, paid_date = coalesce(p_date, current_date),
         status = 'paid'
   where id = p_payment_id;
  -- flip debt to paid_off when nothing remains scheduled
  update debts set status='paid_off', updated_at=now()
   where id = r.debt_id
     and not exists(select 1 from debt_payments where debt_id=r.debt_id and status<>'paid');
  return json_build_object('ok',true,'payment',p_payment_id,'paid',amt);
end; $$;

-- ── Summary per debt (+ next due) — the source for the UI ──
create or replace view v_debt_summary as
select d.id, d.name, d.lender, d.debt_type, d.status,
  d.principal, d.total_obligation, d.interest_total, d.installment_amount,
  d.tenor_months, d.start_date, d.first_due_date, d.drawdown_date,
  coalesce(sum(p.paid_amount),0)                                             as paid_total,
  d.total_obligation - coalesce(sum(p.paid_amount),0)                        as outstanding_total,
  coalesce(sum(p.principal_component) filter (where p.status='paid'),0)      as principal_paid,
  d.principal - coalesce(sum(p.principal_component) filter (where p.status='paid'),0) as outstanding_principal,
  coalesce(sum(p.interest_component) filter (where p.status='paid'),0)       as interest_paid,
  count(p.*) filter (where p.status='paid')                                  as payments_paid,
  count(p.*)                                                                 as payments_total,
  (select min(due_date) from debt_payments x where x.debt_id=d.id and x.status<>'paid') as next_due_date,
  (select scheduled_amount from debt_payments x where x.debt_id=d.id and x.status<>'paid'
     order by due_date limit 1)                                             as next_due_amount
from debts d
left join debt_payments p on p.debt_id = d.id
group by d.id;

create or replace view v_debt_schedule as
select p.*, d.name as debt_name, d.lender
from debt_payments p join debts d on d.id = p.debt_id
order by p.debt_id, p.payment_no;

-- ── RLS: match existing app-layer model (allow-all to anon/authenticated) ──
alter table debts          enable row level security;
alter table debt_payments  enable row level security;
do $$ begin execute 'create policy allow_all_debts on debts for all to anon,authenticated using(true) with check(true)'; exception when duplicate_object then null; end $$;
do $$ begin execute 'create policy allow_all_debt_payments on debt_payments for all to anon,authenticated using(true) with check(true)'; exception when duplicate_object then null; end $$;

grant select,insert,update,delete on debts, debt_payments to anon,authenticated;
grant usage,select on sequence debts_id_seq, debt_payments_id_seq to anon,authenticated;
grant execute on function pm_debt_build_schedule(bigint)              to anon,authenticated;
grant execute on function pm_debt_pay(bigint,numeric,date)            to anon,authenticated;
grant select on v_debt_summary, v_debt_schedule to anon,authenticated;

-- ── VALIDATION (run after deploy; every debt must satisfy) ──
--   select id, principal,
--          principal_paid + outstanding_principal as prin_check,        -- = principal
--          paid_total + outstanding_total          as oblig_check        -- = total_obligation
--   from v_debt_summary;
