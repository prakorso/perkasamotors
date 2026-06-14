-- ═══════════════════════════════════════════════════════════
-- PERKASA MOTORS — Audit Trail Schema
-- Jalankan di Supabase SQL Editor setelah schema.sql
-- ═══════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS audit_log (
  id          bigserial primary key,
  user_name   text not null,
  action      text not null,       -- SIMPAN, EDIT, HAPUS, TERJUAL, KAS, ASET
  entity      text not null,       -- unit, kas_keluar, aset_inventori, dll
  entity_id   text default '',
  detail      text default '',
  created_at  timestamptz default now()
);

-- Index untuk query cepat
CREATE INDEX IF NOT EXISTS audit_log_created_at_idx ON audit_log(created_at DESC);
CREATE INDEX IF NOT EXISTS audit_log_user_idx ON audit_log(user_name);

-- RLS: bisa insert dari anon (frontend), bisa select, tidak bisa update/delete
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY "allow_insert_audit" ON audit_log FOR INSERT TO anon, authenticated WITH CHECK (true);
CREATE POLICY "allow_select_audit" ON audit_log FOR SELECT TO anon, authenticated USING (true);
