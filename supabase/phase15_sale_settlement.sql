-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 15 · D5 SALE & SETTLEMENT  (future units; additive)
-- Applies ONLY to funding_model='perkasa'. Legacy path (pm_settle_unit,
-- reserve_ledger, financial_policy, legacy P&L) is NOT altered.
--
-- Net Proceeds  = Selling Price − Selling Cost
-- True Profit   = Net Proceeds − Base Unit Cost   (Base Cost from v_unit_cost)
-- Capital Return= Perkasa + Partner funding (NEVER revenue/P&L)
-- Profit case   : Partner Fee/Share per unit_partner_agreement; Perkasa Retained
--                 = True Profit − Partner Fee. Reserve = 0 (no reserve_ledger).
-- Loss case     : pro-rata by funding exposure (default); Partner shares downside,
--                 capital return reduced; Partner Fee/Share = 0.
-- Immutable snapshot in unit_settlement; corrections via Reverse→fix→Re-settle.
--
-- DOUBLE-COUNT GUARD: v_unit_economics is re-created with a funding_model='legacy'
-- filter so settled 'perkasa' units (status='terjual') never enter legacy
-- v_pnl / v_inventory / v_profitability. All 44 current units are legacy ⇒
-- PRE=POST identical (verified in phase15_verify.sql).
-- ══════════════════════════════════════════════════════════════════════════

-- ── 0) Legacy P&L guard (only change to a legacy view; body otherwise identical) ──
create or replace view v_unit_economics as
select u.id, u.nama, u.jenis, u.status, u.model_class, u.tgl::date acq_date, u.tgl_jual::date sale_date,
  u.harga_jual::numeric revenue,
  (select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(u.biaya_panji) e) cost_panji,
  (select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(u.biaya_pandu) e) cost_pandu,
  (select coalesce(sum((p->>'funding')::numeric),0) from jsonb_array_elements(u.partners) p) cost_partner,
  coalesce((select sum(nominal) from reserve_advances ra where ra.unit_id=u.id),0) cost_advance,
  (select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(u.biaya_panji) e)
   +(select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(u.biaya_pandu) e)
   +(select coalesce(sum((p->>'funding')::numeric),0) from jsonb_array_elements(u.partners) p)
   +coalesce((select sum(nominal) from reserve_advances ra where ra.unit_id=u.id),0) unit_cost,
  (select coalesce(sum(case when p->>'feeType'='fixed' then (p->>'feeValue')::numeric
                            when p->>'feeType'='percent' then (p->>'funding')::numeric*(p->>'feeValue')::numeric/100
                            else 0 end),0) from jsonb_array_elements(u.partners) p) fixed_fees,
  coalesce(u.keuntungan_bersih::numeric,0) realized_profit,
  coalesce(u.kas_bisnis::numeric,0) reserve_recorded,
  case when u.status='terjual' then (u.tgl_jual::date-u.tgl::date) end holding_days
from units u
where coalesce(u.funding_model,'legacy') = 'legacy';   -- ← the only added line (double-count guard)

-- ── 1) Immutable settlement snapshot ──
create table if not exists unit_settlement (
  id bigserial primary key,
  unit_id bigint not null references units(id) on delete cascade,
  settle_date date not null default current_date,
  selling_price numeric not null default 0,
  selling_cost  numeric not null default 0,
  net_proceeds  numeric not null default 0,
  base_unit_cost_snap  numeric not null default 0,
  perkasa_funding_snap numeric not null default 0,
  partner_funding_snap numeric not null default 0,
  total_funding_snap   numeric not null default 0,
  true_unit_profit numeric not null default 0,
  partner_fee numeric not null default 0,
  perkasa_retained_profit numeric not null default 0,
  is_loss boolean not null default false,
  total_loss numeric not null default 0,
  perkasa_loss numeric not null default 0,
  partner_loss numeric not null default 0,
  perkasa_exposure_pct numeric,
  partner_exposure_pct numeric,
  capital_return_perkasa numeric not null default 0,
  capital_return_partner numeric not null default 0,
  total_capital_return   numeric not null default 0,
  partner_breakdown jsonb default '[]',
  status text not null default 'settled',
  reversed_at timestamptz, reverse_reason text,
  created_at timestamptz default now()
);
do $$ begin alter table unit_settlement add constraint us_status_chk check (status in ('settled','reversed')); exception when duplicate_object then null; end $$;
create unique index if not exists uniq_unit_settlement_active on unit_settlement(unit_id) where status='settled';
create index if not exists idx_unit_settlement_unit on unit_settlement(unit_id);

-- ── 2) Settlement RPC (gated; no reserve; DB-derived) ──
create or replace function pm_unit_settle_v2(p_pass text, p_unit_id bigint,
  p_selling_price numeric, p_selling_cost numeric, p_settle_date date default current_date)
returns json language plpgsql security definer as $$
declare u record; base numeric; pf numeric; ptf numeric; tot numeric;
  net numeric; truep numeric; is_loss boolean; total_loss numeric := 0;
  partner_fee_total numeric := 0; partner_loss_total numeric := 0; partner_exp_total numeric := 0;
  cr_partner_total numeric := 0; perkasa_loss numeric := 0; perkasa_exp numeric := null;
  perkasa_retained numeric; cr_perkasa numeric; brk jsonb := '[]'::jsonb; r record; fee numeric; exp numeric; ploss numeric; cr numeric;
begin
  if not pm_partner_auth(p_pass) then return json_build_object('ok',false,'error','Tidak berwenang.'); end if;
  select id, coalesce(funding_model,'legacy') fm into u from units where id=p_unit_id;
  if not found then return json_build_object('ok',false,'error','unit tidak ditemukan'); end if;
  if u.fm <> 'perkasa' then return json_build_object('ok',false,'error','bukan unit model perkasa'); end if;
  if exists(select 1 from unit_settlement where unit_id=p_unit_id and status='settled') then
    return json_build_object('ok',false,'error','unit sudah settled (reverse dulu untuk koreksi)'); end if;

  select coalesce(base_unit_cost,0), coalesce(perkasa_funding,0), coalesce(partner_funding,0), coalesce(total_funding,0)
    into base, pf, ptf, tot from v_unit_funding where unit_id=p_unit_id;

  net   := p_selling_price - coalesce(p_selling_cost,0);
  truep := net - base;

  if truep >= 0 then
    is_loss := false;
    for r in select f.partner_name, sum(f.amount) funding from unit_funding f
             where f.unit_id=p_unit_id and f.source='partner' group by f.partner_name loop
      declare a record; begin
        select * into a from unit_partner_agreement where unit_id=p_unit_id and partner_name=r.partner_name;
        if found then
          fee := case a.agreement_type
                   when 'fixed_fee'       then coalesce(a.fixed_fee,0)
                   when 'fee_pct_capital' then r.funding*coalesce(a.fee_pct,0)/100
                   when 'profit_share_pct'then truep*coalesce(a.profit_share_pct,0)/100
                   else 0 end;
        else fee := 0; end if;
      end;
      fee := round(coalesce(fee,0));
      partner_fee_total := partner_fee_total + fee;
      cr := r.funding; cr_partner_total := cr_partner_total + cr;
      brk := brk || jsonb_build_object('partner_name',r.partner_name,'funding',r.funding,'fee',fee,'loss',0,'capital_return',cr,'exposure_pct',null);
    end loop;
    perkasa_retained := truep - partner_fee_total;
    cr_perkasa := pf;
  else
    is_loss := true;
    total_loss := base - net;                       -- > 0
    for r in select f.partner_name, sum(f.amount) funding from unit_funding f
             where f.unit_id=p_unit_id and f.source='partner' group by f.partner_name loop
      exp := coalesce( (select loss_exposure_pct from unit_partner_agreement where unit_id=p_unit_id and partner_name=r.partner_name),
                       case when tot>0 then r.funding/tot*100 else 0 end );
      ploss := round(total_loss*exp/100);
      cr := r.funding - ploss;
      partner_loss_total := partner_loss_total + ploss;
      partner_exp_total  := partner_exp_total + exp;
      cr_partner_total   := cr_partner_total + cr;
      brk := brk || jsonb_build_object('partner_name',r.partner_name,'funding',r.funding,'fee',0,'loss',ploss,'capital_return',cr,'exposure_pct',exp);
    end loop;
    perkasa_exp     := 100 - partner_exp_total;
    perkasa_loss    := total_loss - partner_loss_total;   -- ties out exactly
    cr_perkasa      := pf - perkasa_loss;
    perkasa_retained:= -perkasa_loss;
    partner_fee_total := 0;
  end if;

  insert into unit_settlement(unit_id,settle_date,selling_price,selling_cost,net_proceeds,
    base_unit_cost_snap,perkasa_funding_snap,partner_funding_snap,total_funding_snap,
    true_unit_profit,partner_fee,perkasa_retained_profit,is_loss,total_loss,perkasa_loss,partner_loss,
    perkasa_exposure_pct,partner_exposure_pct,capital_return_perkasa,capital_return_partner,total_capital_return,
    partner_breakdown,status)
  values(p_unit_id,coalesce(p_settle_date,current_date),p_selling_price,coalesce(p_selling_cost,0),net,
    base,pf,ptf,tot, truep, partner_fee_total, perkasa_retained, is_loss, coalesce(total_loss,0), perkasa_loss, partner_loss_total,
    perkasa_exp, case when is_loss then partner_exp_total else null end, cr_perkasa, cr_partner_total, cr_perkasa+cr_partner_total,
    brk, 'settled');

  update units set status='terjual', tgl_jual=coalesce(p_settle_date,current_date), harga_jual=p_selling_price, updated_at=now()
    where id=p_unit_id;

  return json_build_object('ok',true,'unit',p_unit_id,'net_proceeds',net,'true_unit_profit',truep,'is_loss',is_loss,
    'total_capital_return',cr_perkasa+cr_partner_total,'perkasa_retained_profit',perkasa_retained,
    'partner_fee',partner_fee_total,'total_loss',coalesce(total_loss,0),
    'capital_return_perkasa',cr_perkasa,'capital_return_partner',cr_partner_total);
end; $$;

-- ── 3) Reversal RPC (audited; returns unit to Active) ──
create or replace function pm_unit_settle_reverse(p_pass text, p_unit_id bigint, p_reason text)
returns json language plpgsql security definer as $$
declare n int;
begin
  if not pm_partner_auth(p_pass) then return json_build_object('ok',false,'error','Tidak berwenang.'); end if;
  update unit_settlement set status='reversed', reversed_at=now(), reverse_reason=coalesce(p_reason,'')
    where unit_id=p_unit_id and status='settled';
  get diagnostics n = row_count;
  if n=0 then return json_build_object('ok',false,'error','tidak ada settlement aktif'); end if;
  update units set status='aktif', tgl_jual=null, harga_jual=0, updated_at=now() where id=p_unit_id;
  return json_build_object('ok',true,'reversed',n);
end; $$;

-- ── 4) Derived views ──
create or replace view v_unit_settlement as
select s.*, u.nama, u.jenis from unit_settlement s join units u on u.id=s.unit_id where s.status='settled';

-- Retained profit: legacy (guarded v_pnl) + future (settlements). Kept separate + total.
create or replace view v_retained_profit as
select
  coalesce((select realized_unit_profit from v_pnl),0)                                        as legacy_retained,
  coalesce((select sum(perkasa_retained_profit) from unit_settlement where status='settled'),0) as future_retained,
  coalesce((select realized_unit_profit from v_pnl),0)
    + coalesce((select sum(perkasa_retained_profit) from unit_settlement where status='settled'),0) as total_retained;

-- ── 5) RLS / grants ── unit_settlement: SELECT for anon; writes only via gated RPC.
alter table unit_settlement enable row level security;
do $$ begin execute 'create policy us_read on unit_settlement for select to anon,authenticated using(true)'; exception when duplicate_object then null; end $$;
revoke all on unit_settlement from anon, authenticated;
grant  select on unit_settlement to anon, authenticated;
grant execute on function pm_unit_settle_v2(text,bigint,numeric,numeric,date) to anon,authenticated;
grant execute on function pm_unit_settle_reverse(text,bigint,text)            to anon,authenticated;
grant select on v_unit_settlement, v_retained_profit to anon,authenticated;

-- NOTE: v_cash_position extension and v_unit_pnl_unified wiring are D6 (they READ
-- unit_settlement). The snapshot stores all cash/profit fields D6 needs; no cash
-- ledger is created here (no duplicate source of truth).
