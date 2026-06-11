// ============================================================
//  Perkasa Motors — Google Apps Script Backend
//  Sheet: "Units", "Biaya", "Partners", "Config"
//  Phase 4 columns added: Sumber Beli, PIC, Kategori,
//    Kondisi, Lokasi, Harga Beli, Target Jual, Target Profit
// ============================================================

const SHEET_UNITS    = 'Units';
const SHEET_BIAYA    = 'Biaya';
const SHEET_PARTNERS = 'Partners';
const SHEET_CONFIG   = 'Config';

// Column indices in "Units" sheet (0-based)
const COL = {
  ID:0, NAMA:1, JENIS:2, TGL:3, STATUS:4, HARGA_JUAL:5,
  MODAL_PANJI:6, PCT_PANJI:7, MODAL_PANDU:8, PCT_PANDU:9,
  MODAL_PARTNER:10, TOTAL_MODAL:11, TOTAL_FEE:12,
  KEUNTUNGAN_KOTOR:13, KEUNTUNGAN_BERSIH:14,
  BAGI_PANJI:15, BAGI_PANDU:16,
  TGL_JUAL:17, PLAT:18, TAHUN:19,
  // Phase 4
  SUMBER_BELI:20, PIC:21, KATEGORI:22, KONDISI:23, LOKASI:24,
  HARGA_BELI:25, TARGET_JUAL:26, TARGET_PROFIT:27
};
const TOTAL_COLS = 28;

// ─── CORS helper ────────────────────────────────────────────
function cors(output) {
  return output
    .setMimeType(ContentService.MimeType.JSON)
    .addHeader('Access-Control-Allow-Origin', '*');
}
function json(data) {
  return cors(ContentService.createTextOutput(JSON.stringify(data)));
}

// ─── GET: return all units ───────────────────────────────────
function doGet(e) {
  try {
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const units = getUnits(ss);
    return json({ ok: true, units });
  } catch(err) {
    return json({ ok: false, error: err.message });
  }
}

// ─── POST: dispatch actions ──────────────────────────────────
function doPost(e) {
  try {
    const body = JSON.parse(e.postData.contents);
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    switch(body.action) {
      case 'login':          return handleLogin(ss, body);
      case 'save':           return handleSave(ss, body);
      case 'edit':           return handleEdit(ss, body);
      case 'delete':         return handleDelete(ss, body);
      case 'update_status':  return handleUpdateStatus(ss, body);
      case 'get_admin_config':   return handleGetConfig(ss, body);
      case 'save_admin_config':  return handleSaveConfig(ss, body);
      default: return json({ ok: false, error: 'Unknown action: ' + body.action });
    }
  } catch(err) {
    return json({ ok: false, error: err.message });
  }
}

// ─── LOGIN ───────────────────────────────────────────────────
function handleLogin(ss, body) {
  const cfg = getConfig(ss);
  const u = (body.user || '').toLowerCase().trim();
  const p = (body.pass || '').trim();

  if (u === 'panji'  && p === (cfg['panji_pass']  || '12345678')) return json({ ok: true, role: 'panji' });
  if (u === 'pandu'  && p === (cfg['pandu_pass']  || 'perkasa123')) return json({ ok: true, role: 'pandu' });
  if (u === 'admin'  && p === (cfg['admin_pass']  || 'admin123'))  return json({ ok: true, role: 'admin' });

  // Investor accounts: username starts with "inv_" or "investor"
  const investors = getInvestorAccounts(cfg);
  if (investors[u] && investors[u] === p) return json({ ok: true, role: u });

  return json({ ok: false, error: 'Username atau password salah.' });
}

function getInvestorAccounts(cfg) {
  const accounts = {};
  Object.keys(cfg).forEach(k => {
    if (k.startsWith('inv_') || k.startsWith('investor_')) {
      accounts[k] = cfg[k];
    }
  });
  return accounts;
}

// ─── SAVE new unit ───────────────────────────────────────────
function handleSave(ss, body) {
  const d = body.data;
  const id = Date.now();
  const sheetU = getOrCreateSheet(ss, SHEET_UNITS);
  ensureUnitHeaders(sheetU);

  const row = buildUnitRow(id, d);
  sheetU.appendRow(row);

  saveBiaya(ss, id, d.nama, d.panji, 'Panji');
  saveBiaya(ss, id, d.nama, d.pandu, 'Pandu');
  savePartners(ss, id, d.nama, d.partners || []);

  return json({ ok: true, id });
}

// ─── EDIT existing unit ──────────────────────────────────────
function handleEdit(ss, body) {
  const d = body.data;
  const id = body.id;
  const sheetU = getOrCreateSheet(ss, SHEET_UNITS);
  const rowIdx = findRowById(sheetU, id);
  if (rowIdx < 0) return json({ ok: false, error: 'Unit tidak ditemukan.' });

  const row = buildUnitRow(id, d);
  const range = sheetU.getRange(rowIdx + 1, 1, 1, TOTAL_COLS);
  range.setValues([row]);

  // Replace biaya & partners
  deleteBiayaByUnitId(ss, id);
  deletePartnersByUnitId(ss, id);
  saveBiaya(ss, id, d.nama, d.panji, 'Panji');
  saveBiaya(ss, id, d.nama, d.pandu, 'Pandu');
  savePartners(ss, id, d.nama, d.partners || []);

  return json({ ok: true });
}

// ─── DELETE unit ─────────────────────────────────────────────
function handleDelete(ss, body) {
  const id = body.id;
  const sheetU = getOrCreateSheet(ss, SHEET_UNITS);
  const rowIdx = findRowById(sheetU, id);
  if (rowIdx < 0) return json({ ok: false, error: 'Unit tidak ditemukan.' });
  sheetU.deleteRow(rowIdx + 1);
  deleteBiayaByUnitId(ss, id);
  deletePartnersByUnitId(ss, id);
  return json({ ok: true });
}

// ─── UPDATE STATUS (tandai terjual) ──────────────────────────
function handleUpdateStatus(ss, body) {
  const id = body.id;
  const harga = body.hargaJual || 0;
  const sheetU = getOrCreateSheet(ss, SHEET_UNITS);
  const rowIdx = findRowById(sheetU, id);
  if (rowIdx < 0) return json({ ok: false, error: 'Unit tidak ditemukan.' });

  const r = sheetU.getRange(rowIdx + 1, 1, 1, TOTAL_COLS).getValues()[0];
  const totalModal = parseNum(r[COL.TOTAL_MODAL]);
  const totalFee   = parseNum(r[COL.TOTAL_FEE]);
  const pctPanji   = parseNum(r[COL.PCT_PANJI]);
  const pctPandu   = parseNum(r[COL.PCT_PANDU]);

  const kotor  = harga - totalModal;
  const bersih = kotor - totalFee;
  const bP     = bersih * pctPanji / 100;
  const bD     = bersih * pctPandu / 100;

  r[COL.STATUS]            = 'terjual';
  r[COL.HARGA_JUAL]        = harga;
  r[COL.KEUNTUNGAN_KOTOR]  = kotor;
  r[COL.KEUNTUNGAN_BERSIH] = bersih;
  r[COL.BAGI_PANJI]        = bP;
  r[COL.BAGI_PANDU]        = bD;
  r[COL.TGL_JUAL]          = new Date().toISOString().slice(0,10);

  sheetU.getRange(rowIdx + 1, 1, 1, TOTAL_COLS).setValues([r]);
  return json({ ok: true });
}

// ─── ADMIN CONFIG ────────────────────────────────────────────
function handleGetConfig(ss, body) {
  const cfg = getConfig(ss);
  if ((body.adminPass || '') !== (cfg['admin_pass'] || 'admin123'))
    return json({ ok: false, error: 'Password admin salah.' });
  return json({ ok: true, config: cfg });
}

function handleSaveConfig(ss, body) {
  const cfg = getConfig(ss);
  if ((body.adminPass || '') !== (cfg['admin_pass'] || 'admin123'))
    return json({ ok: false, error: 'Password admin salah.' });

  const sheet = getOrCreateSheet(ss, SHEET_CONFIG);
  const s = body.settings || {};
  ['brand','tagline','taglineShort','accent','logoType','initial',
   'panji_pass','pandu_pass','admin_pass','emails','email_enabled'].forEach(k => {
    if (s[k] !== undefined) setConfig(sheet, k, s[k]);
  });
  return json({ ok: true });
}

// ─── FETCH ALL UNITS ─────────────────────────────────────────
function getUnits(ss) {
  const sheetU = getOrCreateSheet(ss, SHEET_UNITS);
  const data = sheetU.getDataRange().getValues();
  if (data.length < 2) return [];

  const biayaMap    = getBiayaMap(ss);
  const partnerMap  = getPartnerMap(ss);

  return data.slice(1).map(r => {
    const id = r[COL.ID];
    if (!id) return null;

    const biayaPanji = (biayaMap[id] || []).filter(b => b.who === 'Panji');
    const biayaPandu = (biayaMap[id] || []).filter(b => b.who === 'Pandu');
    const partners   = partnerMap[id] || [];

    const modalPanji  = biayaPanji.reduce((s,b) => s + b.nominal, 0);
    const modalPandu  = biayaPandu.reduce((s,b) => s + b.nominal, 0);
    const modalPartner = partners.reduce((s,p) => s + p.funding, 0);
    const totalModal  = modalPanji + modalPandu + modalPartner;
    const totalFee    = partners.reduce((s,p) => s + (p.feeAmount || 0), 0);
    const pctPanji    = totalModal > 0 ? (modalPanji  / (modalPanji + modalPandu)) * 100 : 0;
    const pctPandu    = totalModal > 0 ? (modalPandu  / (modalPanji + modalPandu)) * 100 : 0;

    return {
      id,
      nama:             r[COL.NAMA]    || '',
      jenis:            r[COL.JENIS]   || 'Mobil',
      tgl:              fmtDate(r[COL.TGL]),
      status:           r[COL.STATUS]  || 'aktif',
      hargaJual:        parseNum(r[COL.HARGA_JUAL]),
      tglJual:          fmtDate(r[COL.TGL_JUAL]),
      plat:             r[COL.PLAT]    || '',
      tahun:            r[COL.TAHUN]   || '',
      // Phase 4
      sumberBeli:       r[COL.SUMBER_BELI]  || '',
      pic:              r[COL.PIC]          || '',
      kategori:         r[COL.KATEGORI]     || '',
      kondisi:          r[COL.KONDISI]      || '',
      lokasi:           r[COL.LOKASI]       || '',
      hargaBeli:        parseNum(r[COL.HARGA_BELI]),
      targetJual:       parseNum(r[COL.TARGET_JUAL]),
      targetProfit:     parseNum(r[COL.TARGET_PROFIT]),
      // Calculated
      panji:  { total: modalPanji,  biaya: biayaPanji.map(b=>({keterangan:b.ket,nominal:b.nominal})) },
      pandu:  { total: modalPandu,  biaya: biayaPandu.map(b=>({keterangan:b.ket,nominal:b.nominal})) },
      partners,
      totalModal,
      modalPartner,
      totalFee,
      pctPanji:  +pctPanji.toFixed(2),
      pctPandu:  +pctPandu.toFixed(2),
      keuntunganBersih: parseNum(r[COL.KEUNTUNGAN_BERSIH])
    };
  }).filter(Boolean);
}

// ─── BIAYA helpers ───────────────────────────────────────────
function getBiayaMap(ss) {
  const sheet = getOrCreateSheet(ss, SHEET_BIAYA);
  const data  = sheet.getDataRange().getValues();
  const map   = {};
  data.slice(1).forEach(r => {
    const id  = r[0]; if (!id) return;
    const who = r[2] || '';
    const ket = r[3] || '';
    const nom = parseNum(r[4]);
    if (!map[id]) map[id] = [];
    map[id].push({ who, ket, nominal: nom });
  });
  return map;
}

function saveBiaya(ss, unitId, unitNama, biayaObj, who) {
  if (!biayaObj || !biayaObj.biaya) return;
  const sheet = getOrCreateSheet(ss, SHEET_BIAYA);
  ensureBiayaHeaders(sheet);
  biayaObj.biaya.forEach(b => {
    if (!b.keterangan && !b.nominal) return;
    sheet.appendRow([unitId, unitNama, who, b.keterangan || '', parseNum(b.nominal)]);
  });
}

function deleteBiayaByUnitId(ss, unitId) {
  const sheet = getOrCreateSheet(ss, SHEET_BIAYA);
  deleteRowsWhere(sheet, row => String(row[0]) === String(unitId));
}

// ─── PARTNERS helpers ────────────────────────────────────────
function getPartnerMap(ss) {
  const sheet = getOrCreateSheet(ss, SHEET_PARTNERS);
  const data  = sheet.getDataRange().getValues();
  const map   = {};
  data.slice(1).forEach(r => {
    const id = r[0]; if (!id) return;
    const funding  = parseNum(r[3]);
    const feeType  = r[4] || 'fixed';
    const feeValue = parseNum(r[5]);
    const feeAmount = feeType === 'pct' ? funding * feeValue / 100 : feeValue;
    if (!map[id]) map[id] = [];
    map[id].push({ nama: r[2]||'', funding, feeType, feeValue, feeAmount });
  });
  return map;
}

function savePartners(ss, unitId, unitNama, partners) {
  if (!partners || !partners.length) return;
  const sheet = getOrCreateSheet(ss, SHEET_PARTNERS);
  ensurePartnerHeaders(sheet);
  partners.forEach(p => {
    const feeAmount = p.feeType === 'pct'
      ? (parseNum(p.funding) * parseNum(p.feeValue) / 100)
      : parseNum(p.feeValue);
    sheet.appendRow([unitId, unitNama, p.nama||'', parseNum(p.funding), p.feeType||'fixed', parseNum(p.feeValue), feeAmount]);
  });
}

function deletePartnersByUnitId(ss, unitId) {
  const sheet = getOrCreateSheet(ss, SHEET_PARTNERS);
  deleteRowsWhere(sheet, row => String(row[0]) === String(unitId));
}

// ─── BUILD UNIT ROW ──────────────────────────────────────────
function buildUnitRow(id, d) {
  const panji  = d.panji  || { biaya: [] };
  const pandu  = d.pandu  || { biaya: [] };
  const partners = d.partners || [];

  const modalPanji  = (panji.biaya  || []).reduce((s,b) => s + parseNum(b.nominal), 0);
  const modalPandu  = (pandu.biaya  || []).reduce((s,b) => s + parseNum(b.nominal), 0);
  const modalPartner = partners.reduce((s,p) => s + parseNum(p.funding), 0);
  const totalModal  = modalPanji + modalPandu + modalPartner;
  const totalFee    = partners.reduce((s,p) => {
    const feeAmount = p.feeType === 'pct'
      ? parseNum(p.funding) * parseNum(p.feeValue) / 100
      : parseNum(p.feeValue);
    return s + feeAmount;
  }, 0);
  const base        = modalPanji + modalPandu;
  const pctPanji    = base > 0 ? (modalPanji / base) * 100 : 0;
  const pctPandu    = base > 0 ? (modalPandu / base) * 100 : 0;

  const status   = d.status || 'aktif';
  const harga    = status === 'terjual' ? parseNum(d.hargaJual) : 0;
  const kotor    = status === 'terjual' ? harga - totalModal : '';
  const bersih   = status === 'terjual' ? (kotor - totalFee)  : '';
  const bP       = status === 'terjual' ? bersih * pctPanji / 100 : '';
  const bD       = status === 'terjual' ? bersih * pctPandu / 100 : '';

  const row = new Array(TOTAL_COLS).fill('');
  row[COL.ID]                = id;
  row[COL.NAMA]              = d.nama   || '';
  row[COL.JENIS]             = d.jenis  || 'Mobil';
  row[COL.TGL]               = d.tgl    || new Date().toISOString().slice(0,10);
  row[COL.STATUS]            = status;
  row[COL.HARGA_JUAL]        = harga || '';
  row[COL.MODAL_PANJI]       = modalPanji;
  row[COL.PCT_PANJI]         = +pctPanji.toFixed(2);
  row[COL.MODAL_PANDU]       = modalPandu;
  row[COL.PCT_PANDU]         = +pctPandu.toFixed(2);
  row[COL.MODAL_PARTNER]     = modalPartner;
  row[COL.TOTAL_MODAL]       = totalModal;
  row[COL.TOTAL_FEE]         = totalFee;
  row[COL.KEUNTUNGAN_KOTOR]  = kotor;
  row[COL.KEUNTUNGAN_BERSIH] = bersih;
  row[COL.BAGI_PANJI]        = bP;
  row[COL.BAGI_PANDU]        = bD;
  row[COL.TGL_JUAL]          = status === 'terjual' ? (d.tglJual || new Date().toISOString().slice(0,10)) : '';
  row[COL.PLAT]              = d.plat   || '';
  row[COL.TAHUN]             = d.tahun  || '';
  // Phase 4
  row[COL.SUMBER_BELI]       = d.sumberBeli  || '';
  row[COL.PIC]               = d.pic         || '';
  row[COL.KATEGORI]          = d.kategori    || '';
  row[COL.KONDISI]           = d.kondisi     || '';
  row[COL.LOKASI]            = d.lokasi      || '';
  row[COL.HARGA_BELI]        = parseNum(d.hargaBeli)   || '';
  row[COL.TARGET_JUAL]       = parseNum(d.targetJual)  || '';
  row[COL.TARGET_PROFIT]     = parseNum(d.targetProfit)|| '';
  return row;
}

// ─── CONFIG helpers ──────────────────────────────────────────
function getConfig(ss) {
  const sheet = getOrCreateSheet(ss, SHEET_CONFIG);
  const data  = sheet.getDataRange().getValues();
  const cfg   = {};
  data.slice(1).forEach(r => { if (r[0]) cfg[r[0]] = r[1]; });
  return cfg;
}

function setConfig(sheet, key, value) {
  const data = sheet.getDataRange().getValues();
  for (let i = 1; i < data.length; i++) {
    if (data[i][0] === key) { sheet.getRange(i+1, 2).setValue(value); return; }
  }
  sheet.appendRow([key, value]);
}

// ─── Sheet resolution ────────────────────────────────────────
// Resolve a sheet by NAME first; if not found, auto-detect by the
// header signature of its first row, so it works regardless of the
// actual tab name. Falls back to creating a tab with the canonical name.
function getOrCreateSheet(ss, name) {
  // direct name match
  let sheet = ss.getSheetByName(name);
  if (sheet) return sheet;

  // signature-based detection
  const SIGNATURES = {
    'Units':    ['nama unit', 'status'],
    'Biaya':    ['keterangan', 'nominal'],
    'Partners': ['jumlah funding'],
    'Config':   ['key', 'value']
  };
  const sig = SIGNATURES[name];
  if (sig) {
    const sheets = ss.getSheets();
    for (let i = 0; i < sheets.length; i++) {
      const sh = sheets[i];
      if (sh.getLastColumn() === 0) continue;
      const headers = sh.getRange(1, 1, 1, sh.getLastColumn())
        .getValues()[0].map(h => String(h).toLowerCase().trim());
      // Config special-case: exactly Key/Value 2-col table
      if (name === 'Config') {
        if (headers[0] === 'key' && headers[1] === 'value') return sh;
        continue;
      }
      const matchAll = sig.every(s => headers.indexOf(s) >= 0);
      // make sure we don't confuse Biaya vs Partners (both have Unit ID/Nama Unit)
      if (name === 'Biaya'    && headers.indexOf('jumlah funding') >= 0) continue;
      if (name === 'Partners' && headers.indexOf('nominal') >= 0 && headers.indexOf('jumlah funding') < 0) continue;
      if (matchAll) return sh;
    }
  }
  // not found anywhere → create canonical
  return ss.insertSheet(name);
}

function ensureUnitHeaders(sheet) {
  if (sheet.getLastRow() > 0) return;
  sheet.appendRow([
    'ID','Nama Unit','Jenis','Tanggal Masuk','Status','Harga Jual',
    'Modal Panji','% Panji','Modal Pandu','% Pandu','Modal Partner',
    'Total Modal','Total Fee Partner','Keuntungan Kotor','Keuntungan Bersih',
    'Bagi Panji','Bagi Pandu','Tanggal Jual','Plat Nomor','Tahun Unit',
    'Sumber Beli','PIC','Kategori','Kondisi','Lokasi',
    'Harga Beli','Target Jual','Target Profit'
  ]);
}

function ensureBiayaHeaders(sheet) {
  if (sheet.getLastRow() > 0) return;
  sheet.appendRow(['Unit ID','Nama Unit','Partner','Keterangan','Nominal']);
}

function ensurePartnerHeaders(sheet) {
  if (sheet.getLastRow() > 0) return;
  sheet.appendRow(['Unit ID','Nama Unit','Nama Partner','Jumlah Funding','Tipe Fee','Nilai Fee','Fee (Rp)']);
}

function findRowById(sheet, id) {
  const data = sheet.getDataRange().getValues();
  for (let i = 1; i < data.length; i++) {
    if (String(data[i][0]) === String(id)) return i;
  }
  return -1;
}

function deleteRowsWhere(sheet, predicate) {
  const data = sheet.getDataRange().getValues();
  for (let i = data.length - 1; i >= 1; i--) {
    if (predicate(data[i])) sheet.deleteRow(i + 1);
  }
}

// ─── Number / date helpers ───────────────────────────────────
function parseNum(v) {
  if (v === '' || v === null || v === undefined) return 0;
  if (typeof v === 'number') return v;
  return parseFloat(String(v).replace(/[^0-9.-]/g, '')) || 0;
}

function fmtDate(v) {
  if (!v) return '';
  if (typeof v === 'string') return v.slice(0,10);
  if (v instanceof Date) return Utilities.formatDate(v, Session.getScriptTimeZone(), 'yyyy-MM-dd');
  return String(v).slice(0,10);
}
