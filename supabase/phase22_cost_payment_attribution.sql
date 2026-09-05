-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 22 · D-Fx3 · UNIT COST PAYMENT ATTRIBUTION (ADDITIVE)
-- STATUS: PREPARED — NOT YET EXECUTED (awaiting explicit apply authorization).
--
-- Adds OPTIONAL, NULLABLE attribution to unit_cost_entries so a cost can record
-- WHO paid it and WHETHER it is paid — WITHOUT turning a cost into a cash event
-- automatically and WITHOUT changing Base Unit Cost or settlement.
--   • Base Unit Cost stays SUM(unit_cost_entries.amount) — unchanged.
--   • Funding Gap stays Base Unit Cost − Total Funding — unchanged.
--   • Settlement / v_pnl / legacy — untouched.
-- No backfill: existing rows keep NULL attribution (unknown), which the UI shows
-- as "belum diklasifikasikan". These fields exist to let a FUTURE D11 cash ledger
-- consume clean cash events; this phase does NOT build D11.
-- Fully reversible (drop columns/constraints).
-- ══════════════════════════════════════════════════════════════════════════

alter table unit_cost_entries add column if not exists paid_source    text;
alter table unit_cost_entries add column if not exists payment_status text;
alter table unit_cost_entries add column if not exists paid_date      date;

do $$ begin
  alter table unit_cost_entries add constraint uce_paid_source_chk
    check (paid_source is null or paid_source in ('company','perkasa','partner','other'));
exception when duplicate_object then null; end $$;

do $$ begin
  alter table unit_cost_entries add constraint uce_pay_status_chk
    check (payment_status is null or payment_status in ('unpaid','paid'));
exception when duplicate_object then null; end $$;
