# Cara Deploy Apps Script

1. Buka https://script.google.com
2. Klik **New Project** (atau buka project yang existing)
3. Hapus semua kode yang ada, paste seluruh isi `Code.gs`
4. Klik **Save** (Ctrl+S)
5. Klik **Deploy → New deployment**
   - Type: **Web app**
   - Execute as: **Me**
   - Who has access: **Anyone**
6. Klik **Deploy**, copy URL-nya
7. Update `APPS_SCRIPT_URL` di `index.html` dengan URL baru

## Kolom baru yang perlu ditambah di sheet "Units"
Jika sheet sudah ada datanya, tambahkan kolom berikut di akhir (kolom U–AB):
- U: Sumber Beli
- V: PIC
- W: Kategori
- X: Kondisi
- Y: Lokasi
- Z: Harga Beli
- AA: Target Jual
- AB: Target Profit

Kolom yang sudah ada (A–T) tidak perlu diubah.
