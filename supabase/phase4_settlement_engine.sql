-- ══════════════════════════════════════════════════════════════
-- PERKASA MOTORS — CFO SYSTEM · PHASE 4 · SETTLEMENT ENGINE
-- Authoritative server-side settlement for CURRENT units only.
-- Legacy & transition_recorded units are structurally excluded.
-- Additive: creates functions only; never rewrites recorded amounts.
-- ══════════════════════════════════════════════════════════════

-- Helper: gate — is a unit eligible for automatic engine settlement?
-- Eligible ⇔ current model AND acquired on/after effective date AND still pending.
create or replace function pm_settlement_eligible(p_unit_id bigint)
returns boolean language sql stable as $$
  select exists(
    select 1 from units u
    join financial_policy fp on fp.status='active'
    where u.id=p_unit_id
      and u.status='terjual'
      and u.model_class='current'
      and u.settlement_status='pending'
      and u.tgl >= fp.effective_date
  );
$$;

-- Core engine: settle ONE current unit.
--   Realized Profit = Sale − Total Modal − Fixed Partner Fees
--   Reserve         = Profit × policy.rate  (default 10%)  → reserve_ledger IN
--   Distributable   = Profit − Reserve                     → split by CAPITAL contribution
--   Fixed-fee partners keep their fee (already removed from profit); NOT in the split.
--   Outstanding reserve advances are reimbursed back to reserve on sale.
--   Any rounding residual is logged to settlement_variances (never silently absorbed).
create or replace function pm_settle_unit(p_unit_id bigint)
returns json language plpgsql security definer as $$
declare
  u record; rate numeric; eff date;
  m_panji numeric; m_pandu numeric; m_partner numeric; fee_tetap numeric;
  total_modal numeric; profit numeric; reserve numeric; distributable numeric;
  part_cap numeric; adv numeric; a record; part record;
  share numeric; sum_dist numeric := 0; residual numeric;
begin
  select * into u from units where id=p_unit_id;
  if not found                       then return json_build_object('ok',false,'error','unit not found'); end if;
  if u.status <> 'terjual'           then return json_build_object('ok',false,'error','unit belum terjual'); end if;
  if u.model_class <> 'current'      then return json_build_object('ok',false,'error','legacy unit — engine tidak menyentuh'); end if;
  if u.settlement_status <> 'pending' then return json_build_object('ok',false,'error','sudah final: '||coalesce(u.settlement_status,'-')); end if;

  select rate, effective_date into rate, eff from financial_policy where status='active' order by effective_date desc limit 1;
  if rate is null then return json_build_object('ok',false,'error','no active financial policy'); end if;
  if u.tgl < eff then return json_build_object('ok',false,'error','acquired before effective date — legacy'); end if;

  -- Capital & fixed fees
  select coalesce(sum((e->>'nominal')::numeric),0) into m_panji  from jsonb_array_elements(u.biaya_panji) e;
  select coalesce(sum((e->>'nominal')::numeric),0) into m_pandu  from jsonb_array_elements(u.biaya_pandu) e;
  select coalesce(sum((p->>'funding')::numeric),0) into m_partner from jsonb_array_elements(u.partners) p;
  select coalesce(sum(case when p->>'feeType'='fixed'   then (p->>'feeValue')::numeric
                           when p->>'feeType'='percent' then (p->>'funding')::numeric*(p->>'feeValue')::numeric/100
                           else 0 end),0)
    into fee_tetap from jsonb_array_elements(u.partners) p;

  total_modal   := m_panji + m_pandu + m_partner;
  profit        := (u.harga_jual::numeric) - total_modal - fee_tetap;
  reserve       := round(profit * rate);
  distributable := profit - reserve;
  -- Participating capital = founders + profit-share partners (fixed-fee partners excluded)
  part_cap := m_panji + m_pandu
            + coalesce((select sum((p->>'funding')::numeric) from jsonb_array_elements(u.partners) p
                        where p->>'feeType'='percent_profit'),0);

  -- 1) Reserve retention IN
  insert into reserve_ledger(tgl,tipe,arah,nominal,unit_id,keterangan)
    values (coalesce(u.tgl_jual::date,current_date),'retained_profit','in',reserve,u.id,
            'Auto reserve '||round(rate*100)||'% (settlement engine)');

  -- 2) Reimburse outstanding reserve advances (money back INTO reserve)
  select coalesce(sum(nominal),0) into adv from reserve_advances where unit_id=u.id and status='outstanding';
  if adv > 0 then
    insert into reserve_ledger(tgl,tipe,arah,nominal,unit_id,keterangan)
      values (coalesce(u.tgl_jual::date,current_date),'reimbursement','in',adv,u.id,'Advance reimbursed on sale');
    update reserve_advances set status='reimbursed',
           reimbursed_date=coalesce(u.tgl_jual::date,current_date), reimbursed_amount=nominal
      where unit_id=u.id and status='outstanding';
  end if;

  -- 3) Distribute: capital-based for founders + profit-share partners; fixed fee kept by fixed partners
  for a in select * from capital_allocations where unit_id=u.id loop
    if a.kind='core_capital' then
      share := case when part_cap>0 then round(distributable*a.amount/part_cap) else 0 end;
      sum_dist := sum_dist + share;
    elsif a.kind='partner_funding' then
      select p.* into part from jsonb_array_elements(u.partners) p
        where p->>'nama'=(select name from capital_accounts where id=a.account_id) limit 1;
      if (part.value->>'feeType')='percent_profit' then
        share := case when part_cap>0 then round(distributable*a.amount/part_cap) else 0 end;
        sum_dist := sum_dist + share;
      elsif (part.value->>'feeType')='fixed' then
        share := (part.value->>'feeValue')::numeric;           -- fee already removed from profit
      elsif (part.value->>'feeType')='percent' then
        share := a.amount*(part.value->>'feeValue')::numeric/100;
      else share := 0; end if;
    else share := 0; end if;
    update capital_allocations set profit_share=share, status='settled' where id=a.id;
  end loop;

  -- 4) Rounding residual → explicit variance (never silently absorbed)
  residual := distributable - sum_dist;
  if residual <> 0 then
    insert into settlement_variances(unit_id,amount,status,keterangan)
      values (u.id,residual,'unresolved','Rounding residual on engine settlement');
  end if;

  -- 5) Write authoritative computed values (fresh unit — first write, not a rewrite) & mark settled
  update units set kas_bisnis=reserve, keuntungan_bersih=profit,
                   settlement_status='engine_settled', updated_at=now()
    where id=u.id;

  return json_build_object('ok',true,'unit',u.id,'profit',profit,'reserve',reserve,
    'distributable',distributable,'distributed',sum_dist,'residual',residual,
    'invariant_ok',(reserve + sum_dist + residual = distributable + reserve));
end; $$;

grant execute on function pm_settlement_eligible(bigint) to anon,authenticated;
grant execute on function pm_settle_unit(bigint)        to anon,authenticated;

-- Auditable view: reserve balance = Σin − Σout ; available = balance − outstanding advances
create or replace view v_reserve_summary as
select
  coalesce(sum(case when arah='in' then nominal else -nominal end),0)                    as reserve_balance,
  coalesce((select sum(nominal) from reserve_advances where status='outstanding'),0)      as deployed_reserve,
  coalesce(sum(case when arah='in' then nominal else -nominal end),0)
    - coalesce((select sum(nominal) from reserve_advances where status='outstanding'),0)  as available_reserve
from reserve_ledger;
