-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 18b (D9 P3) · Inventory Asset status (ADDITIVE)
-- Adds a lifecycle status to company operating assets (aset_inventori). Trading
-- vehicles remain in the Unit → Cost → Funding → Settlement architecture and are
-- NOT stored here; asset value never enters vehicle Base Unit Cost / profit.
-- Asset purchases already register as cash-out via v_cashflow.outflow_capex.
-- ══════════════════════════════════════════════════════════════════════════
alter table aset_inventori add column if not exists status text not null default 'active';
do $$ begin
  alter table aset_inventori add constraint aset_status_chk check (status in ('active','disposed','sold'));
exception when duplicate_object then null; end $$;
