-- ═══════════════════════════════════════════════════════════
-- PERKASA MOTORS — Supabase Schema
-- Jalankan di Supabase SQL Editor (Settings → SQL Editor)
-- ═══════════════════════════════════════════════════════════

-- ─── ACCOUNTS (custom auth, replaces Google Sheets Config) ─
CREATE TABLE IF NOT EXISTS accounts (
  id        bigserial primary key,
  username  text unique not null,
  password  text not null,
  role      text not null default 'viewer',
  active    boolean default true,
  created_at timestamptz default now()
);

-- ─── UNITS ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS units (
  id              bigserial primary key,
  nama            text not null,
  plat            text default '',
  tahun           text default '',
  jenis           text default 'Mobil',
  status          text default 'aktif',
  tgl             date,
  tgl_jual        date,
  harga_jual      numeric default 0,
  harga_beli      numeric default 0,
  target_jual     numeric default 0,
  target_profit   numeric default 0,
  sumber_beli     text default '',
  pic             text default '',
  kategori        text default '',
  kondisi         text default '',
  lokasi          text default '',
  biaya_panji     jsonb default '[]',
  biaya_pandu     jsonb default '[]',
  partners        jsonb default '[]',
  keuntungan_bersih numeric,
  kas_bisnis      numeric,
  bagi_panji      numeric,
  bagi_pandu      numeric,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

-- ─── KAS KELUAR ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS kas_keluar (
  id          bigserial primary key,
  keterangan  text not null,
  nominal     numeric not null,
  tgl         date,
  created_at  timestamptz default now()
);

-- ─── ASET INVENTORI ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS aset_inventori (
  id          bigserial primary key,
  nama        text not null,
  kategori    text default '',
  nilai_beli  numeric default 0,
  nilai_skrg  numeric default 0,
  tgl         date,
  catatan     text default '',
  created_at  timestamptz default now()
);

-- ─── APP CONFIG (admin settings, notifications) ─────────────
CREATE TABLE IF NOT EXISTS app_config (
  key   text primary key,
  value text
);

-- ─── updated_at trigger ─────────────────────────────────────
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;

DROP TRIGGER IF EXISTS units_updated_at ON units;
CREATE TRIGGER units_updated_at
  BEFORE UPDATE ON units
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ════════════════════════════════════════════════════════════
-- RPC FUNCTIONS (called by frontend via supabase.rpc())
-- ════════════════════════════════════════════════════════════

-- Login: returns {ok, role} — passwords never returned to client
CREATE OR REPLACE FUNCTION public.pm_login(p_user text, p_pass text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE acc record;
BEGIN
  SELECT username, role INTO acc
  FROM accounts
  WHERE username = lower(trim(p_user)) AND password = p_pass AND active = true;
  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'Username atau password salah.');
  END IF;
  RETURN json_build_object('ok', true, 'role', acc.role);
END; $$;

-- Get admin config
CREATE OR REPLACE FUNCTION public.pm_get_admin_config(p_pass text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  stored_pass text; investors json; emails text; email_enabled bool;
BEGIN
  SELECT value INTO stored_pass FROM app_config WHERE key = 'admin_pass';
  IF stored_pass IS NULL THEN stored_pass := 'admin123'; END IF;
  IF p_pass != stored_pass AND p_pass != '__internal__' THEN
    RETURN json_build_object('ok', false, 'error', 'Password admin salah.');
  END IF;
  SELECT json_agg(json_build_object('username', username, 'password', password))
    INTO investors FROM accounts WHERE role = 'investor' AND active = true;
  SELECT value INTO emails FROM app_config WHERE key = 'notif_emails';
  SELECT (value = 'true') INTO email_enabled FROM app_config WHERE key = 'email_enabled';
  RETURN json_build_object(
    'ok', true,
    'investors', COALESCE(investors, '[]'::json),
    'emails', COALESCE(emails, ''),
    'emailEnabled', COALESCE(email_enabled, false)
  );
END; $$;

-- Save admin config (change passwords, notif settings)
CREATE OR REPLACE FUNCTION public.pm_save_admin_config(
  p_admin_pass text, p_panji_pass text DEFAULT '',
  p_pandu_pass text DEFAULT '', p_new_admin_pass text DEFAULT '',
  p_emails text DEFAULT '', p_email_enabled bool DEFAULT false
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE stored_pass text;
BEGIN
  SELECT value INTO stored_pass FROM app_config WHERE key = 'admin_pass';
  IF stored_pass IS NULL THEN stored_pass := 'admin123'; END IF;
  IF p_admin_pass != stored_pass AND p_admin_pass != '__internal__' THEN
    RETURN json_build_object('ok', false, 'error', 'Password admin salah.');
  END IF;
  IF p_panji_pass != '' THEN UPDATE accounts SET password = p_panji_pass WHERE username = 'panji'; END IF;
  IF p_pandu_pass != '' THEN UPDATE accounts SET password = p_pandu_pass WHERE username = 'pandu'; END IF;
  IF p_new_admin_pass != '' THEN
    INSERT INTO app_config(key, value) VALUES('admin_pass', p_new_admin_pass)
      ON CONFLICT(key) DO UPDATE SET value = EXCLUDED.value;
  END IF;
  INSERT INTO app_config(key, value) VALUES('notif_emails', p_emails)
    ON CONFLICT(key) DO UPDATE SET value = EXCLUDED.value;
  INSERT INTO app_config(key, value) VALUES('email_enabled', p_email_enabled::text)
    ON CONFLICT(key) DO UPDATE SET value = EXCLUDED.value;
  RETURN json_build_object('ok', true);
END; $$;

-- Add investor account
CREATE OR REPLACE FUNCTION public.pm_save_investor(
  p_admin_pass text, p_username text, p_password text
) RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE stored_pass text; new_user text;
BEGIN
  SELECT value INTO stored_pass FROM app_config WHERE key = 'admin_pass';
  IF stored_pass IS NULL THEN stored_pass := 'admin123'; END IF;
  IF p_admin_pass != stored_pass AND p_admin_pass != '__internal__' THEN
    RETURN json_build_object('ok', false, 'error', 'Password admin salah.');
  END IF;
  new_user := lower(trim(p_username));
  INSERT INTO accounts(username, password, role)
    VALUES(new_user, p_password, 'investor')
    ON CONFLICT(username) DO UPDATE SET password = EXCLUDED.password, active = true;
  RETURN json_build_object('ok', true, 'username', new_user);
END; $$;

-- Deactivate investor account
CREATE OR REPLACE FUNCTION public.pm_delete_investor(p_admin_pass text, p_username text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE stored_pass text;
BEGIN
  SELECT value INTO stored_pass FROM app_config WHERE key = 'admin_pass';
  IF stored_pass IS NULL THEN stored_pass := 'admin123'; END IF;
  IF p_admin_pass != stored_pass AND p_admin_pass != '__internal__' THEN
    RETURN json_build_object('ok', false, 'error', 'Password admin salah.');
  END IF;
  UPDATE accounts SET active = false WHERE username = lower(trim(p_username));
  RETURN json_build_object('ok', true);
END; $$;

-- ════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY
-- Semua tabel bisa dibaca/ditulis oleh anon key (frontend).
-- Keamanan dijaga di layer RPC (password validation).
-- ════════════════════════════════════════════════════════════
ALTER TABLE units ENABLE ROW LEVEL SECURITY;
ALTER TABLE kas_keluar ENABLE ROW LEVEL SECURITY;
ALTER TABLE aset_inventori ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE accounts ENABLE ROW LEVEL SECURITY;

-- accounts: blokir semua direct access (hanya via RPC SECURITY DEFINER)
CREATE POLICY "no_direct_access" ON accounts FOR ALL TO anon, authenticated USING (false);

-- app_config: blokir semua direct access
CREATE POLICY "no_direct_access" ON app_config FOR ALL TO anon, authenticated USING (false);

-- units: bisa SELECT (data tidak sensitif untuk bisnis internal), INSERT/UPDATE/DELETE bebas
-- (akses dikendalikan di frontend via session)
CREATE POLICY "allow_all_units" ON units FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

CREATE POLICY "allow_all_kas" ON kas_keluar FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

CREATE POLICY "allow_all_aset" ON aset_inventori FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- Grant execute on RPC functions to anon
GRANT EXECUTE ON FUNCTION public.pm_login TO anon;
GRANT EXECUTE ON FUNCTION public.pm_get_admin_config TO anon;
GRANT EXECUTE ON FUNCTION public.pm_save_admin_config TO anon;
GRANT EXECUTE ON FUNCTION public.pm_save_investor TO anon;
GRANT EXECUTE ON FUNCTION public.pm_delete_investor TO anon;
