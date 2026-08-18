-- ══════════════════════════════════════════════════════════════
-- PERKASA MOTORS — CFO SYSTEM · PHASE 8 · UI SUPPORT (views + RPC)
-- Additive, read-only. Keeps ALL calculation in the DB (single source of
-- truth) so the new UI never re-derives financials in the frontend.
-- ══════════════════════════════════════════════════════════════

-- Dynamic funding simulator for ANY amount (frontend passes p_funding).
-- Reads configurable assumptions + financial_policy. No hardcoded terms.
create or replace function pm_funding_sim(p_funding numeric)
returns json language plpgsql stable as $$
declare K numeric; H numeric; PU numeric; RR numeric; T numeric; fs numeric; ids numeric;
  cap_conc numeric; cap_tput numeric; tput numeric; deployed numeric;
  biz numeric; reserve numeric; dist numeric; inv_profit numeric; founder_profit numeric;
begin
  select value into K  from funding_assumptions where key='avg_cost_per_unit';
  select value into H  from funding_assumptions where key='mean_holding_days';
  select value into PU from funding_assumptions where key='profit_per_unit';
  select value into T  from funding_assumptions where key='ops_ceiling_mo';
  select value into fs from funding_assumptions where key='founder_mgmt_share';
  select rate into RR  from financial_policy where status='active' order by effective_date desc limit 1;
  if K is null then return json_build_object('ok',false,'error','funding_assumptions not deployed'); end if;
  ids := 1 - coalesce(fs,0);
  cap_conc := p_funding / K;
  cap_tput := cap_conc*30/H;
  tput := least(cap_tput, T);
  deployed := round(tput*H/30*K);
  biz := round(tput*12*PU);
  reserve := round(biz*RR);
  dist := round(biz*(1-RR));
  inv_profit := round(dist*ids);
  founder_profit := round(dist*coalesce(fs,0));
  return json_build_object('ok',true,
    'funding',p_funding,'deployed',deployed,'idle',round(p_funding-deployed),
    'utilization_pct',round(deployed/nullif(p_funding,0)*100),
    'capital_enabled_concurrent',round(cap_conc,1),
    'capital_enabled_throughput_mo',round(cap_tput,1),
    'actual_throughput_mo',round(tput,2),'ops_ceiling_mo',T,
    'required_throughput_mo',round(cap_tput,1),
    'capacity_gap_mo',round(greatest(cap_tput - T,0),1),
    'annual_business_profit',biz,'reserve_retention',reserve,'distributable_profit',dist,
    'founder_mgmt_share',coalesce(fs,0),'investor_share_of_distributable',ids,
    'investor_realized_profit',inv_profit,'founder_mgmt_profit',founder_profit,
    'operating_roi_on_deployed_pct',round(biz/nullif(deployed,0)*100),
    'investor_roi_on_funded_pct',round(inv_profit/nullif(p_funding,0)*100),
    'investor_roi_on_deployed_pct',round(inv_profit/nullif(deployed,0)*100),
    'investor_return_multiple_on_funded',round(1+inv_profit/nullif(p_funding,0),2),
    'scenario_label',case when coalesce(fs,0)=0
      then 'Illustrative capital-only scenario — commercial profit-sharing terms not finalized'
      else 'Investor '||round(ids*100)||'% / founder mgmt '||round(coalesce(fs,0)*100)||'% of distributable' end);
end; $$;
grant execute on function pm_funding_sim(numeric) to anon,authenticated;

-- Single-row Command Center KPI aggregate (pulls from validated views)
create or replace view v_command_center as
select
  (select reserve_balance from v_reserve_summary)                       as reserve_balance,
  (select available_reserve from v_reserve_summary)                     as available_reserve,
  (select deployed_reserve from v_reserve_summary)                      as deployed_reserve,
  (select coalesce(sum(economic_cost),0) from v_inventory)              as inventory_at_cost,
  (select coalesce(sum(funded),0) from v_investor_summary)              as capital_funded,
  (select coalesce(sum(deployed),0) from v_investor_summary)            as capital_deployed,
  (select coalesce(sum(available),0) from v_investor_summary)           as capital_available,
  (select coalesce(sum(capital_returned),0) from v_investor_summary)    as capital_returned,
  (select realized_unit_profit from v_pnl)                             as realized_profit,
  (select net_operating_profit from v_pnl)                             as net_operating_profit,
  (select revenue from v_pnl)                                          as revenue,
  (select gross_margin_pct from v_pnl)                                 as gross_margin_pct,
  (select units_sold from v_profitability)                            as units_sold,
  (select mean_holding from v_profitability)                          as mean_holding,
  (select median_holding from v_profitability)                        as median_holding,
  (select round(throughput_per_month,2) from v_funding_capacity)      as throughput_mo,
  (select value::numeric from app_config where key='opening_cash')     as opening_cash,
  (select value from app_config where key='opening_cash_verified')     as opening_cash_verified,
  (select count(*) from units where status<>'terjual')                 as active_units,
  (select count(*) from v_investor_summary where role<>'founder' and current_exposure>0) as active_investors,
  (select coalesce(sum(current_exposure),0) from v_investor_summary where role<>'founder') as investor_exposure,
  (select coalesce(sum(realized_profit),0) from v_investor_summary where role<>'founder')  as investor_realized_profit,
  30000000::numeric                                                    as reserve_target,
  (select rate from financial_policy where status='active' order by effective_date desc limit 1) as reserve_rate,
  -- open items surfaced (never hidden)
  (select coalesce(sum(amount),0) from settlement_variances where status='unresolved') as unresolved_variance,
  (select count(*) from capital_accounts where account_username is null and role<>'founder') as unmapped_accounts;

-- P&L split by legacy vs current (for the P&L filter — one source, filtered)
create or replace view v_pnl_by_class as
with s as (select * from v_unit_economics where status='terjual')
select model_class,
  sum(revenue) as revenue, sum(unit_cost) as cogs, sum(revenue-unit_cost) as gross_profit,
  sum(fixed_fees) as unit_financing_fees, sum(revenue-unit_cost-fixed_fees) as realized_unit_profit,
  count(*) as units
from s group by model_class;

grant select on v_command_center, v_pnl_by_class to anon,authenticated;
