-- ═══════════════════════════════════════════════════════════
-- PERKASA MOTORS — Initial Seed Data
-- Jalankan SETELAH schema.sql
-- PENTING: Ganti password di bawah sebelum dijalankan!
-- ═══════════════════════════════════════════════════════════

-- Akun internal (GANTI password sesuai yang diinginkan)
INSERT INTO accounts (username, password, role) VALUES
  ('panji',  'GANTI_DENGAN_PASSWORD_PANJI',  'partner'),
  ('pandu',  'GANTI_DENGAN_PASSWORD_PANDU',  'partner'),
  ('admin',  'admin123',                       'admin')
ON CONFLICT (username) DO NOTHING;

-- Default admin config
INSERT INTO app_config (key, value) VALUES
  ('admin_pass',    'admin123'),
  ('notif_emails',  ''),
  ('email_enabled', 'false')
ON CONFLICT (key) DO NOTHING;
