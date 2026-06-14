# Panduan Setup Supabase — Perkasa Motors

## Langkah 1: Jalankan Schema

1. Buka [Supabase Dashboard](https://supabase.com/dashboard)
2. Pilih project Perkasa Motors
3. Klik **SQL Editor** di sidebar kiri
4. Copy-paste isi `schema.sql` → klik **Run**

## Langkah 2: Buat Akun Pengguna

Edit file `seed.sql` — **ganti password** Panji dan Pandu terlebih dahulu:

```sql
INSERT INTO accounts (username, password, role) VALUES
  ('panji',  'PASSWORD_PANJI_DISINI',  'partner'),
  ('pandu',  'PASSWORD_PANDU_DISINI',  'partner'),
  ('admin',  'admin123',               'admin')
```

Lalu jalankan `seed.sql` di SQL Editor.

> **PENTING:** Jangan commit file `seed.sql` setelah mengisi password ke GitHub.

## Langkah 3: Migrasi Data dari Google Sheets (opsional)

Jika ingin memindahkan data lama dari Google Sheets:

1. Di Apps Script, tambahkan endpoint `export_all` yang mengembalikan semua unit sebagai JSON
2. Download data JSON tersebut
3. Transform dan insert ke tabel `units` Supabase via SQL Editor

Atau mulai fresh — data baru akan masuk ke Supabase langsung dari dashboard.

## Langkah 4: Test Login

Buka dashboard di browser, login dengan username `panji` dan password yang sudah diset.

## Struktur Tabel

| Tabel | Keterangan |
|-------|-----------|
| `accounts` | Akun pengguna (panji, pandu, investor_xxx) |
| `units` | Data unit kendaraan |
| `kas_keluar` | Pengeluaran kas bisnis |
| `aset_inventori` | Inventori aset non-kendaraan |
| `app_config` | Konfigurasi aplikasi (admin pass, notif) |

## Menambah Akun Investor

Login ke dashboard sebagai Panji/Pandu → Pengaturan → Panel Admin → Kelola Akun Investor.
