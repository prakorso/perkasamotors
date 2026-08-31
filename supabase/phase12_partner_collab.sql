-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 12 · PARTNER COLLABORATION  (additive, non-destructive)
-- Configurable profit-share policy matrix + saved partner deals.
-- Partner Profit Share % = share of NET PROFIT (after capital return + direct
-- costs). It is NOT interest / ROI on capital. Capital is returned separately.
-- share_pct NULL = "Custom" (bespoke agreement required).
-- The frontend falls back to a built-in V1 matrix until this file is run.
-- ══════════════════════════════════════════════════════════════════════════

create table if not exists partner_profit_policy (
  id            bigserial primary key,
  vehicle_type  text not null,                 -- 'Mobil' | 'Motor'
  bracket_label text not null,                 -- '<10%','10-20%','20-30%','30-40%','40-50%','>50%'
  holding_label text not null,                 -- '<30','31-60','61-90','91-120','121-180'
  share_pct     numeric,                       -- NULL = Custom
  updated_at    timestamptz default now(),
  unique(vehicle_type, bracket_label, holding_label)
);

-- Seed V1 policy (idempotent; existing edited rows are preserved via do-nothing)
insert into partner_profit_policy(vehicle_type,bracket_label,holding_label,share_pct) values
 ('Mobil','<10%','<30',6),('Mobil','<10%','31-60',7),('Mobil','<10%','61-90',8),('Mobil','<10%','91-120',9),('Mobil','<10%','121-180',10),
 ('Mobil','10-20%','<30',9),('Mobil','10-20%','31-60',10),('Mobil','10-20%','61-90',11),('Mobil','10-20%','91-120',12),('Mobil','10-20%','121-180',13),
 ('Mobil','20-30%','<30',11),('Mobil','20-30%','31-60',12),('Mobil','20-30%','61-90',14),('Mobil','20-30%','91-120',15),('Mobil','20-30%','121-180',17),
 ('Mobil','30-40%','<30',14),('Mobil','30-40%','31-60',15),('Mobil','30-40%','61-90',17),('Mobil','30-40%','91-120',18),('Mobil','30-40%','121-180',20),
 ('Mobil','40-50%','<30',17),('Mobil','40-50%','31-60',18),('Mobil','40-50%','61-90',20),('Mobil','40-50%','91-120',22),('Mobil','40-50%','121-180',24),
 ('Mobil','>50%','<30',20),('Mobil','>50%','31-60',20),('Mobil','>50%','61-90',null),('Mobil','>50%','91-120',null),('Mobil','>50%','121-180',null),
 ('Motor','<10%','<30',5),('Motor','<10%','31-60',5),('Motor','<10%','61-90',6),('Motor','<10%','91-120',7),('Motor','<10%','121-180',8),
 ('Motor','10-20%','<30',8),('Motor','10-20%','31-60',9),('Motor','10-20%','61-90',10),('Motor','10-20%','91-120',11),('Motor','10-20%','121-180',12),
 ('Motor','20-30%','<30',9),('Motor','20-30%','31-60',10),('Motor','20-30%','61-90',11),('Motor','20-30%','91-120',12),('Motor','20-30%','121-180',14),
 ('Motor','30-40%','<30',11),('Motor','30-40%','31-60',12),('Motor','30-40%','61-90',14),('Motor','30-40%','91-120',15),('Motor','30-40%','121-180',17),
 ('Motor','40-50%','<30',14),('Motor','40-50%','31-60',15),('Motor','40-50%','61-90',17),('Motor','40-50%','91-120',18),('Motor','40-50%','121-180',20),
 ('Motor','>50%','<30',20),('Motor','>50%','31-60',null),('Motor','>50%','61-90',null),('Motor','>50%','91-120',null),('Motor','>50%','121-180',null)
on conflict (vehicle_type,bracket_label,holding_label) do nothing;

create table if not exists partner_deals (
  id             bigserial primary key,
  unit_name      text not null default '',
  vehicle_type   text not null default 'Motor',
  base_price     numeric not null default 0,
  selling_price  numeric not null default 0,
  partner_capital numeric not null default 0,
  perkasa_capital numeric not null default 0,
  repair_cost    numeric not null default 0,
  transport_cost numeric not null default 0,
  doc_cost       numeric not null default 0,
  marketing_cost numeric not null default 0,
  holding_days   int not null default 0,
  status         text not null default 'Simulation',  -- Simulation|Funded|In Inventory|Sold|Settlement Pending|Settled|Loss
  notes          text default '',
  created_at     timestamptz default now(),
  updated_at     timestamptz default now()
);

alter table partner_profit_policy enable row level security;
alter table partner_deals         enable row level security;
do $$ begin execute 'create policy allow_all_ppp on partner_profit_policy for all to anon,authenticated using(true) with check(true)'; exception when duplicate_object then null; end $$;
do $$ begin execute 'create policy allow_all_pd on partner_deals for all to anon,authenticated using(true) with check(true)'; exception when duplicate_object then null; end $$;

grant select,insert,update,delete on partner_profit_policy, partner_deals to anon,authenticated;
grant usage,select on sequence partner_profit_policy_id_seq, partner_deals_id_seq to anon,authenticated;

-- ── VALIDATION ──
--   select vehicle_type,count(*) from partner_profit_policy group by 1;   -- expect 30 each
--   select * from partner_deals;                                          -- deals saved from the simulator
