-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 10 · PAYROLL  (financial-obligation mgmt, not HR)
-- Additive, non-destructive. Records are DB-backed.
-- ACCOUNTING:
--   • Salary PAID → CASH OUT + OpEx (P&L).  Recorded ONLY here — NEVER also in
--     kas_keluar (prevents double-count).
--   • Salary UNPAID → LIABILITY (payable).
-- INVARIANT:  obligation = paid + outstanding.
-- PERCENT BASIS IS NOT INVENTED. Until a business rule is provided, percentage/
-- hybrid rules resolve to needs_basis=true and the % part shows "Belum dikonfigurasi".
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists payroll_people (
  id             bigserial primary key,
  name           text not null,
  role           text default '',
  active         boolean not null default true,
  effective_date date default current_date,
  notes          text default '',
  created_at     timestamptz default now(),
  updated_at     timestamptz default now()
);

create table if not exists payroll_rules (
  id             bigserial primary key,
  person_id      bigint not null references payroll_people(id) on delete cascade,
  method         text not null default 'fixed',   -- fixed | percentage | hybrid
  base_amount    numeric default 0,               -- fixed / hybrid base (Rp)
  percent_value  numeric default 0,               -- percentage / hybrid (%)
  percent_basis  text,                             -- CONFIGURABLE; NULL ⇒ belum dikonfigurasi
  effective_date date default current_date,
  active         boolean not null default true,
  created_at     timestamptz default now()
);
create index if not exists idx_payroll_rules_person on payroll_rules(person_id);

create table if not exists payroll_obligations (
  id             bigserial primary key,
  person_id      bigint not null references payroll_people(id) on delete cascade,
  period_ym      text not null,                    -- 'YYYY-MM'
  method_snapshot text,
  base_component numeric default 0,
  percent_component numeric,                        -- NULL while basis unconfigured
  computed_amount numeric default 0,               -- what is currently payable (base while % pending)
  basis_label    text,
  needs_basis    boolean not null default false,
  due_date       date,
  status         text not null default 'scheduled',-- scheduled | due | paid | overdue
  created_at     timestamptz default now(),
  unique(person_id, period_ym)
);
create index if not exists idx_payroll_oblig_person on payroll_obligations(person_id);

create table if not exists payroll_payments (
  id             bigserial primary key,
  obligation_id  bigint not null references payroll_obligations(id) on delete cascade,
  paid_amount    numeric not null default 0,
  paid_date      date default current_date,
  status         text default 'paid',
  created_at     timestamptz default now()
);
create index if not exists idx_payroll_pay_oblig on payroll_payments(obligation_id);

-- ── Basis resolver — DELIBERATELY returns NULL until a business rule is set. ──
-- Do NOT invent a basis. When the founder decides (e.g. Revenue / Net Profit /
-- Distributable / Operating Cash on a defined period), implement it HERE.
create or replace function pm_payroll_basis_value(p_basis text, p_period_ym text)
returns numeric language plpgsql stable as $$
begin
  return null;  -- unconfigured on purpose
end; $$;

-- ── Generate/refresh obligations for a period from active rules ──
create or replace function pm_payroll_run(p_period_ym text)
returns json language plpgsql as $$
declare pe record; rl record; base numeric; pct numeric; basisval numeric; comp numeric;
  needs boolean; due date; made int := 0;
begin
  due := (to_date(p_period_ym||'-01','YYYY-MM-DD') + interval '1 month - 1 day')::date;
  for pe in select id, name from payroll_people where active loop
    select * into rl from payroll_rules pr
      where pr.person_id = pe.id and pr.active and pr.effective_date <= due
      order by pr.effective_date desc limit 1;
    if not found then continue; end if;

    base := case when rl.method in ('fixed','hybrid') then coalesce(rl.base_amount,0) else 0 end;
    needs := false; pct := null;
    if rl.method in ('percentage','hybrid') then
      if rl.percent_basis is null or rl.percent_basis = '' then
        needs := true;                                 -- basis not configured
      else
        basisval := pm_payroll_basis_value(rl.percent_basis, p_period_ym);
        if basisval is null then needs := true;        -- resolver not implemented yet
        else pct := round(basisval * coalesce(rl.percent_value,0) / 100); end if;
      end if;
    end if;
    comp := base + coalesce(pct,0);                    -- payable now (base while % pending)

    insert into payroll_obligations(person_id,period_ym,method_snapshot,base_component,
           percent_component,computed_amount,basis_label,needs_basis,due_date,status)
      values (pe.id,p_period_ym,rl.method,base,pct,comp,rl.percent_basis,needs,due,'due')
    on conflict (person_id,period_ym) do update
      set method_snapshot=excluded.method_snapshot, base_component=excluded.base_component,
          percent_component=excluded.percent_component, computed_amount=excluded.computed_amount,
          basis_label=excluded.basis_label, needs_basis=excluded.needs_basis, due_date=excluded.due_date
      where payroll_obligations.status <> 'paid';      -- never overwrite a paid period
    made := made + 1;
  end loop;
  return json_build_object('ok',true,'period',p_period_ym,'people',made);
end; $$;

create or replace function pm_payroll_pay(p_obligation_id bigint, p_amount numeric default null, p_date date default null)
returns json language plpgsql as $$
declare o record; amt numeric; paidsum numeric;
begin
  select * into o from payroll_obligations where id=p_obligation_id;
  if not found then return json_build_object('ok',false,'error','obligation not found'); end if;
  amt := coalesce(p_amount, o.computed_amount);
  insert into payroll_payments(obligation_id,paid_amount,paid_date) values (p_obligation_id,amt,coalesce(p_date,current_date));
  select coalesce(sum(paid_amount),0) into paidsum from payroll_payments where obligation_id=p_obligation_id;
  update payroll_obligations set status = case when paidsum >= computed_amount then 'paid' else 'due' end
    where id=p_obligation_id;
  return json_build_object('ok',true,'obligation',p_obligation_id,'paid',amt);
end; $$;

create or replace view v_payroll_obligations as
select o.*, pe.name as person_name, pe.role,
  coalesce((select sum(paid_amount) from payroll_payments pp where pp.obligation_id=o.id),0) as paid_amount,
  o.computed_amount - coalesce((select sum(paid_amount) from payroll_payments pp where pp.obligation_id=o.id),0) as outstanding
from payroll_obligations o join payroll_people pe on pe.id=o.person_id
order by o.period_ym desc, pe.name;

create or replace view v_payroll_summary as
select pe.id, pe.name, pe.role, pe.active,
  coalesce(sum(o.computed_amount),0)                                        as obligation_total,
  coalesce(sum(pp.paid),0)                                                  as paid_total,
  coalesce(sum(o.computed_amount),0) - coalesce(sum(pp.paid),0)             as outstanding_total,
  bool_or(o.needs_basis)                                                    as needs_basis,
  (select min(due_date) from payroll_obligations x where x.person_id=pe.id and x.status<>'paid') as next_due_date
from payroll_people pe
left join payroll_obligations o on o.person_id=pe.id
left join (select obligation_id, sum(paid_amount) paid from payroll_payments group by obligation_id) pp
       on pp.obligation_id=o.id
group by pe.id;

-- ── RLS: match existing app-layer model ──
alter table payroll_people       enable row level security;
alter table payroll_rules        enable row level security;
alter table payroll_obligations  enable row level security;
alter table payroll_payments     enable row level security;
do $$ begin execute 'create policy allow_all_pp on payroll_people for all to anon,authenticated using(true) with check(true)'; exception when duplicate_object then null; end $$;
do $$ begin execute 'create policy allow_all_pr on payroll_rules for all to anon,authenticated using(true) with check(true)'; exception when duplicate_object then null; end $$;
do $$ begin execute 'create policy allow_all_po on payroll_obligations for all to anon,authenticated using(true) with check(true)'; exception when duplicate_object then null; end $$;
do $$ begin execute 'create policy allow_all_ppay on payroll_payments for all to anon,authenticated using(true) with check(true)'; exception when duplicate_object then null; end $$;

grant select,insert,update,delete on payroll_people,payroll_rules,payroll_obligations,payroll_payments to anon,authenticated;
grant usage,select on sequence payroll_people_id_seq,payroll_rules_id_seq,payroll_obligations_id_seq,payroll_payments_id_seq to anon,authenticated;
grant execute on function pm_payroll_basis_value(text,text)        to anon,authenticated;
grant execute on function pm_payroll_run(text)                     to anon,authenticated;
grant execute on function pm_payroll_pay(bigint,numeric,date)      to anon,authenticated;
grant select on v_payroll_obligations, v_payroll_summary to anon,authenticated;

-- ── VALIDATION ──
--   select id, obligation_total, paid_total + outstanding_total as check_oblig from v_payroll_summary;
--   -- needs_basis=true rows are EXPECTED until a payroll % basis is decided.
