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
  u record; rate numeric; eff date;
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
  select rate, effective_date into rate, eff from financial_policy where status='active' order by effective_date desc limit 1;
  if rate is null    then return json_build_object('ok',false,'error','no active financial policy'); end if;
  if u.tgl < eff     then return json_build_object('ok',false,'error','acquired before effective date — legacy'); end if;

  -- Capital funding (also = capital-funded unit cost)
  select coalesce(sum((e->>'nominal')::numeric),0) into m_panji   from jsonb_array_elements(u.biaya_panji) e;
  select coalesce(sum((e->>'nominal')::numeric),0) into m_pandu   from jsonb_array_elements(u.biaya_pandu) e;
  select coalesce(sum((p->>'funding')::numeric),0) into m_partner from jsonb_array_elements(u.partners) p;
  -- Advance-funded expenses on this unit (part of UNIT COST, counted once)
  select coalesce(sum(nominal),0) into adv_cost from reserve_advances where unit_id=u.id;

  unit_cost     := m_panji + m_pandu + m_partner + adv_cost;
  profit        := (u.harga_jual::numeric) - unit_cost;          -- fee NOT deducted here
  reserve       := round(profit * rate);
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
            'Auto reserve '||round(rate*100)||'% (engine)');

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
