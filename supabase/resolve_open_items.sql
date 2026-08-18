-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — SELESAIKAN ITEM TERBUKA "SESUAI LOGIC SEKARANG"
-- Menghapus penanda kuning dengan cara MENYELESAIKAN datanya (bukan menyembunyikan).
-- Baca komentar tiap blok — ini keputusan uang. Jalankan blok yang Anda setujui saja.
-- Aman & idempotent. TIDAK menghapus data historis.
-- ══════════════════════════════════════════════════════════════════════════

-- ── 1) Unit #37 — selisih Rp50.000 ──────────────────────────────────────────
-- "Sesuai logic sekarang" = terima Rp50.000 sebagai final (tidak diutak-atik).
-- Ini menandai variance-nya RESOLVED; nilainya tetap tercatat sebagai fakta.
update settlement_variances
   set status='resolved',
       keterangan = coalesce(keterangan,'') || ' | diterima final sesuai keputusan founder'
 where unit_id = 37 and status = 'unresolved';

-- ── 2) Saldo kas awal — verifikasi pada nilai saat ini ──────────────────────
-- "Sesuai logic sekarang" = terima nilai kas awal yang tercatat (default Rp0)
-- sebagai baseline resmi. Kalau kas awal sebenarnya BUKAN 0, ganti dulu angkanya
-- pada baris pertama sebelum menandai verified.
-- update app_config set value = '0'    where key = 'opening_cash';           -- ganti bila perlu
update app_config set value = 'true' where key = 'opening_cash_verified';

-- ── 3) Akun "Modal" belum dipetakan ─────────────────────────────────────────
-- KEPUTUSAN FOUNDER: akun "Modal" adalah milik Pandu → dipetakan ke login 'pandu'.
update capital_accounts set account_username = 'pandu' where lower(name) = 'modal';
-- (Alternatif lain, tidak dipakai:)
--   pool/kas perusahaan:  set account_username='modal'  where lower(name)='modal';
--   milik Panji:          set account_username='panji'  where lower(name)='modal';

-- ── VERIFIKASI (harus 0 setelah blok yang relevan dijalankan) ───────────────
select
  (select coalesce(sum(amount),0) from settlement_variances where status='unresolved') as sisa_variance,
  (select value from app_config where key='opening_cash_verified')                     as kas_awal_verified,
  (select count(*) from capital_accounts where account_username is null and role<>'founder') as akun_belum_dipetakan;
