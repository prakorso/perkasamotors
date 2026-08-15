-- ═══════════════════════════════════════════════════════════
-- PERKASA MOTORS — Kas Masuk Manual
-- Jalankan di Supabase SQL Editor.
-- Tabel ini untuk kas masuk yang DIINPUT MANUAL (mis. modal awal,
-- pemasukan lain di luar penjualan). Kas otomatis 10% dari tiap
-- unit terjual TETAP dihitung dari tabel `units` (tidak disimpan di sini).
-- ═══════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS kas_masuk (
  id          bigserial primary key,
  keterangan  text not null,
  nominal     numeric not null,
  tgl         date,
  created_at  timestamptz default now()
);

CREATE INDEX IF NOT EXISTS kas_masuk_tgl_idx ON kas_masuk(tgl DESC);

-- RLS: sama seperti kas_keluar — bebas diakses anon (dikendalikan di frontend)
ALTER TABLE kas_masuk ENABLE ROW LEVEL SECURITY;
CREATE POLICY "allow_all_kas_masuk" ON kas_masuk FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);
