-- ══════════════════════════════════════════════════════════════
-- PERKASA MOTORS — CFO SYSTEM · PHASE 3b (approved decisions)
-- RUN ORDER:  phase3_capital_seed.sql  →  THEN this file.
-- Additive & non-destructive. Original recorded values are never rewritten.
-- ══════════════════════════════════════════════════════════════

-- DECISION 2 — Reclassify #35/#37/#38 legacy → current (first units under the
-- new Perkasa Reserve model). Recorded values on `units` stay exactly as-is.
update units set model_class='current', reserve_rate=0.10
where id in (35,37,38);

-- Represent their Kas/Reserve in the new architecture: post the ACTUAL recorded
-- kas_bisnis (NOT a recomputed 10%) as the first current retained-profit entries.
insert into reserve_ledger(tgl,tipe,arah,nominal,unit_id,keterangan)
select coalesce(u.tgl_jual::date,current_date),'retained_profit','in',u.kas_bisnis::numeric,u.id,
       'Retained reserve on first current unit (recorded value preserved)'
from units u
where u.id in (35,37,38) and coalesce(u.kas_bisnis::numeric,0) > 0
  and not exists (select 1 from reserve_ledger r where r.unit_id=u.id and r.tipe='retained_profit');

-- DECISION 3 — Unit #37 Rp50.000 unallocated variance: explicit, unassigned, visible.
create table if not exists settlement_variances (
  id         bigserial primary key,
  unit_id    bigint references units(id),
  amount     numeric not null,
  status     text not null default 'unresolved',   -- unresolved | resolved
  keterangan text default '',
  created_at timestamptz default now()
);
alter table settlement_variances enable row level security;
do $$ begin
  execute 'create policy allow_all_sv on settlement_variances for all to anon,authenticated using(true) with check(true)';
exception when duplicate_object then null; end $$;

insert into settlement_variances(unit_id,amount,status,keterangan)
select 37,50000,'unresolved',
  'Kas 800k + distribusi 7.650k = 8.450k vs profit 8.500k. Rp50.000 belum teralokasi (setara selisih kas 800k vs 10% = 850k). Tidak dibebankan ke pihak mana pun tanpa konfirmasi sumber.'
where not exists (select 1 from settlement_variances where unit_id=37);

-- DECISION 4 — Reivan identity: handled in seed via ILIKE '%reivan%'.
--   'Modal Reivan' -> reivan ; 'Reivan' -> reivan ; 'Modal' -> UNMAPPED (account_username stays null).
-- Enforce explicitly (idempotent), and guarantee 'Modal' remains unmapped:
update capital_accounts set account_username='reivan' where name ilike '%reivan%';
update capital_accounts set account_username=null    where name='Modal';
