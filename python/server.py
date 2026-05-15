import io
import os
import json
from urllib.parse import quote
import time
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
import requests as req_lib
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import StreamingResponse
# from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
import xlsxwriter
from dotenv import load_dotenv
import logging

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

load_dotenv()

# ── App ───────────────────────────────────────────────────────────────────────

app = FastAPI(title="Table Widget API")

# app.add_middleware(
#     CORSMiddleware,
#     allow_origins=["https://dev6.savin-it.ru", "https://dev.savin-it.ru", "https://rufago.ru"],
#     allow_methods=["GET", "POST"],
#     allow_headers=["*"],
# )

# ── Config ────────────────────────────────────────────────────────────────────

SCOPES = ['https://www.googleapis.com/auth/spreadsheets.readonly']
SERVICE_ACCOUNT_FILE = os.getenv("CREDENTIALS_FILE", 'credentials.json')
API_TIMEOUT = int(os.getenv("API_TIMEOUT", "60"))

# Row heights fetched only for first N rows — fetching all rows on 20k+ sheets causes 504s
ROW_META_ROWS = int(os.getenv("ROW_META_ROWS", "50"))

# XLSX export: skip per-cell formatting fetch for sheets larger than this many rows
EXPORT_FORMAT_MAX_ROWS = int(os.getenv("EXPORT_FORMAT_MAX_ROWS", "5000"))

# ── Google Sheets service — new per request ───────────────────────────────────

def get_sheets_service():
    creds = service_account.Credentials.from_service_account_file(
        SERVICE_ACCOUNT_FILE, scopes=SCOPES
    )
    return build('sheets', 'v4', credentials=creds)


# ── Retry helper ──────────────────────────────────────────────────────────────

_RETRYABLE = ("SSL", "WRONG_VERSION", "Connection", "Broken", "RemoteDisconnected", "reset")


def _with_retry(fn, max_retries=3):
    last_exc = None
    for attempt in range(max_retries):
        try:
            return fn()
        except Exception as e:
            err = str(e)
            if any(s in err for s in _RETRYABLE) and attempt < max_retries - 1:
                logger.warning(
                    f"Retryable error (attempt {attempt + 1}/{max_retries}, "
                    f"{type(e).__name__}): {e} — retrying in {0.3 * (attempt + 1):.1f}s"
                )
                last_exc = e
                time.sleep(0.3 * (attempt + 1))
                continue
            raise
    raise last_exc


# ── In-memory cache ───────────────────────────────────────────────────────────

CACHE_TTL_MS       = int(os.getenv("CACHE_TTL_MS",       str(6 * 60 * 60 * 1000)))  # default 6h
CACHE_FRESH_MS     = int(os.getenv("CACHE_FRESH_MS",     str(5 * 60 * 60 * 1000)))  # default 5h
ERROR_CACHE_TTL_MS = int(os.getenv("ERROR_CACHE_TTL_MS", str(5 * 60 * 1000)))       # default 5min
MAX_CACHE_SIZE     = int(os.getenv("MAX_CACHE_SIZE",     "1000"))
WARMUP_WORKERS     = int(os.getenv("WARMUP_WORKERS",     "10"))

_cache: dict = {}
_cache_lock = threading.Lock()
_error_cache: dict = {}
_error_cache_lock = threading.Lock()


def get_cached(key: str):
    with _cache_lock:
        entry = _cache.get(key)
        if entry is None:
            return None
        if time.time() * 1000 - entry["ts"] > CACHE_TTL_MS:
            del _cache[key]
            return None
        return entry["data"]


def set_cached(key: str, data: dict):
    with _cache_lock:
        if len(_cache) >= MAX_CACHE_SIZE:
            oldest = min(_cache, key=lambda k: _cache[k]["ts"])
            del _cache[oldest]
        _cache[key] = {"data": data, "ts": time.time() * 1000}


def get_cached_error(key: str):
    with _error_cache_lock:
        entry = _error_cache.get(key)
        if entry is None:
            return None
        if time.time() * 1000 - entry["ts"] > ERROR_CACHE_TTL_MS:
            del _error_cache[key]
            return None
        return entry


def set_cached_error(key: str, status: int, detail: str):
    with _error_cache_lock:
        _error_cache[key] = {"status": status, "detail": detail, "ts": time.time() * 1000}


def _is_error_cached(spreadsheetId: str, sheetName: str) -> bool:
    return get_cached_error(f"{spreadsheetId}::{sheetName}") is not None


# ── Warmup registry — survives server restarts ────────────────────────────────

WARMUP_REGISTRY_FILE = os.getenv("WARMUP_REGISTRY_FILE", "warmup_registry.json")
_registry: list = []
_registry_lock = threading.Lock()


def _load_registry():
    global _registry
    try:
        with open(WARMUP_REGISTRY_FILE, "r", encoding="utf-8") as f:
            _registry = json.load(f)
        logger.info(f"Warmup registry loaded: {len(_registry)} sheet(s)")
    except FileNotFoundError:
        _registry = []
    except Exception as e:
        logger.warning(f"Failed to load warmup registry: {e}")
        _registry = []


def _save_registry():
    try:
        with open(WARMUP_REGISTRY_FILE, "w", encoding="utf-8") as f:
            json.dump(_registry, f, ensure_ascii=False, indent=2)
    except Exception as e:
        logger.warning(f"Failed to save warmup registry: {e}")


def _update_registry(sheets: list):
    with _registry_lock:
        existing = {(s["spreadsheetId"], s["sheetName"]) for s in _registry}
        added = 0
        for s in sheets:
            key = (s["spreadsheetId"], s["sheetName"])
            if key not in existing:
                _registry.append(s)
                existing.add(key)
                added += 1
        if added:
            _save_registry()
            logger.info(f"Registry updated: +{added} sheet(s), total {len(_registry)}")


_load_registry()


@app.on_event("startup")
def startup_warmup():
    sheets = list(_registry)
    if not sheets:
        logger.info("[startup] Warmup registry is empty — skipping")
        return

    def _do():
        time.sleep(3)
        logger.info(f"[startup] Warming up {len(sheets)} sheet(s), workers={WARMUP_WORKERS}")
        with ThreadPoolExecutor(max_workers=WARMUP_WORKERS) as pool:
            future_to_sheet = {pool.submit(_warmup_if_needed, s, "startup"): s for s in sheets}
            for fut in as_completed(future_to_sheet):
                s = future_to_sheet[fut]
                try:
                    fut.result()
                except Exception as e:
                    logger.warning(f"[startup] {s['sheetName']}: {e}")
        logger.info("[startup] Done")

    threading.Thread(target=_do, daemon=True).start()


# ── Error helpers ─────────────────────────────────────────────────────────────

def _get_sheet_names(spreadsheetId: str) -> list:
    cache_key = f"sheet_names::{spreadsheetId}"
    cached = get_cached(cache_key)
    if cached is not None:
        return cached

    def do_get():
        svc = get_sheets_service()
        res = svc.spreadsheets().get(
            spreadsheetId=spreadsheetId,
            fields="sheets(properties(title))",
        ).execute()
        return [s["properties"]["title"] for s in res.get("sheets", [])]

    names = _with_retry(do_get)
    set_cached(cache_key, names)
    return names


def _humanize_google_error(e: HttpError, sheet_name: str, spreadsheetId: str = "") -> str:
    status = int(e.resp.status)
    msg = str(e).lower()
    try:
        reason = (e.error_details[0].get("reason") or "").lower()
    except Exception:
        reason = ""

    if status == 403 or reason == "forbidden":
        return "Нет доступа к таблице. Проверьте права доступа для сервисного аккаунта."
    if status == 404 or reason == "notfound":
        return "Таблица не найдена. Проверьте ID таблицы."
    if status == 400:
        if "unable to parse range" in msg:
            base = f"Лист «{sheet_name}» не найден в таблице."
            if spreadsheetId:
                try:
                    names = _get_sheet_names(spreadsheetId)
                    if names:
                        quoted = ", ".join(f"«{n}»" for n in names)
                        return f"{base} Доступные листы: {quoted}."
                except Exception:
                    pass
            return f"{base} Проверьте название листа в настройках."
        if "requested entity was not found" in msg:
            return "Таблица не найдена. Проверьте ID таблицы."
        return f"Некорректный запрос: {e}"
    if status >= 500:
        return "Ошибка сервера Google. Попробуйте повторить позже."
    return str(e) or "Не удалось загрузить данные."


# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/")
def root():
    return {"message": "Server is working"}


# GET /api/sheet-data?spreadsheetId=...&sheetName=...
@app.get("/api/sheet-data")
def get_sheet_data(
    spreadsheetId: str = Query(...),
    sheetName: str = Query(...),
):
    spreadsheetId = spreadsheetId.strip()
    sheetName = sheetName.strip()
    cache_key = f"{spreadsheetId}::{sheetName}"

    cached = get_cached(cache_key)
    if cached:
        logger.info(f"Cache hit: {cache_key}")
        return cached

    cached_err = get_cached_error(cache_key)
    if cached_err:
        logger.info(f"Error cache hit: {cache_key}")
        raise HTTPException(status_code=cached_err["status"], detail=cached_err["detail"])

    t_start = time.perf_counter()

    try:
        result = _fetch_all(spreadsheetId, sheetName)
        set_cached(cache_key, result)
        logger.info(
            f"Fresh: {sheetName} rows={len(result['data'])} "
            f"in {(time.perf_counter() - t_start) * 1000:.0f}ms"
        )
        return result

    except HttpError as e:
        status = int(e.resp.status)
        logger.error(f"[sheet-data] Google API {status}: {e}")
        http_status = status if status in (400, 403, 404) else 502
        detail = _humanize_google_error(e, sheetName, spreadsheetId)
        set_cached_error(cache_key, http_status, detail)
        raise HTTPException(status_code=http_status, detail=detail)
    except Exception as e:
        logger.error(f"[sheet-data] {e}")
        raise HTTPException(status_code=500, detail=str(e) or "Не удалось загрузить данные.")


def _fetch_all(spreadsheetId: str, sheetName: str) -> dict:
    def do_values():
        svc = get_sheets_service()
        t0 = time.perf_counter()
        res = svc.spreadsheets().values().get(
            spreadsheetId=spreadsheetId,
            range=f"'{sheetName}'",
            valueRenderOption="UNFORMATTED_VALUE",
            dateTimeRenderOption="FORMATTED_STRING",
        ).execute()
        logger.info(f"  values.get: {(time.perf_counter() - t0) * 1000:.0f}ms")
        return res

    values_res = _with_retry(do_values)
    rows = values_res.get("values") or []
    headers = rows[0] if rows else []
    data = rows[1:] if len(rows) > 1 else []

    # ranges= limits rowMetadata scope; without it Google returns metadata for ALL rows —
    # on 20k+ row sheets that is megabytes of JSON and causes 504 timeouts.
    meta_range = f"'{sheetName}'!1:{ROW_META_ROWS + 1}"

    def do_meta():
        svc = get_sheets_service()
        t0 = time.perf_counter()
        res = svc.spreadsheets().get(
            spreadsheetId=spreadsheetId,
            ranges=[meta_range],
            fields=(
                "sheets(properties(title),"
                "data(startRow,columnMetadata(pixelSize),rowMetadata(pixelSize)))"
            ),
        ).execute()
        logger.info(f"  spreadsheets.get: {(time.perf_counter() - t0) * 1000:.0f}ms")
        return res

    meta_res = _with_retry(do_meta)

    sheet_meta = next(
        (s for s in meta_res.get("sheets", [])
         if s.get("properties", {}).get("title") == sheetName),
        None,
    )

    data_block = (sheet_meta or {}).get("data", [{}])[0]
    block_start = data_block.get("startRow", 0)

    col_meta = data_block.get("columnMetadata", [])
    column_widths = [col.get("pixelSize", 100) for col in col_meta]

    row_heights = {}
    for idx, row in enumerate(data_block.get("rowMetadata", [])):
        pixel_size = row.get("pixelSize")
        if pixel_size:
            data_idx = block_start + idx - 1
            if data_idx >= 0:
                row_heights[data_idx] = pixel_size

    return {
        "headers": headers,
        "data": data,
        "columnWidths": column_widths,
        "rowHeights": row_heights,
        "total": len(data),
    }


# GET /api/json-data?url=...
# Accepts an absolute URL (https://...) or a local path (/catalog.json).
# Local paths are resolved to data/<filename> relative to cwd and read from disk.
# Expects JSON array: [{ key: value, ... }, ...]
@app.get("/api/json-data")
def get_json_data(url: str = Query(...)):
    url = url.strip()
    cache_key = f"json::{url}"

    cached = get_cached(cache_key)
    if cached:
        logger.info(f"Cache hit: {cache_key}")
        return cached

    try:
        if url.startswith("/"):
            file_name = os.path.basename(url)
            file_path = os.path.join(os.getcwd(), "data", file_name)
            with open(file_path, "r", encoding="utf-8") as f:
                json_array = json.load(f)
        else:
            response = req_lib.get(url, timeout=30)
            if not response.ok:
                raise Exception(f"HTTP {response.status_code} fetching {url}")
            json_array = response.json()

        if not isinstance(json_array, list) or len(json_array) == 0:
            raise HTTPException(status_code=400, detail="Expected a non-empty JSON array")

        headers = list(json_array[0].keys())
        data = [[row.get(h, "") for h in headers] for row in json_array]

        result = {"headers": headers, "data": data, "columnWidths": [], "rowHeights": {}}
        set_cached(cache_key, result)
        logger.info(f"Fresh JSON: {url}, rows: {len(data)}")
        return result

    except HTTPException:
        raise
    except FileNotFoundError:
        raise HTTPException(
            status_code=404,
            detail=f"File not found: {os.path.basename(url)}",
        )
    except Exception as e:
        logger.error(f"[json-data] {e}")
        raise HTTPException(status_code=500, detail=str(e) or "Failed to load JSON")


# ── Warmup helpers ────────────────────────────────────────────────────────────

def _is_cache_fresh(spreadsheetId: str, sheetName: str) -> bool:
    key = f"{spreadsheetId}::{sheetName}"
    with _cache_lock:
        entry = _cache.get(key)
        if entry is None:
            return False
        return time.time() * 1000 - entry["ts"] < CACHE_FRESH_MS


def _warmup_one(s: dict, tag: str):
    sid, name = s["spreadsheetId"], s["sheetName"]
    cache_key = f"{sid}::{name}"
    try:
        result = _fetch_all(sid, name)
        set_cached(cache_key, result)
        logger.info(f"[{tag}] OK: {name} rows={len(result['data'])}")
    except HttpError as e:
        status = int(e.resp.status)
        http_status = status if status in (400, 403, 404) else 502
        detail = _humanize_google_error(e, name, sid)
        set_cached_error(cache_key, http_status, detail)
        logger.warning(f"[{tag}] error cached ({http_status}): {name}")
        raise


def _warmup_if_needed(s: dict, tag: str) -> bool:
    if _is_cache_fresh(s["spreadsheetId"], s["sheetName"]):
        logger.info(f"[{tag}] skipped (fresh): {s['sheetName']}")
        return False
    if _is_error_cached(s["spreadsheetId"], s["sheetName"]):
        logger.info(f"[{tag}] skipped (error cached): {s['sheetName']}")
        return False
    _warmup_one(s, tag)
    return True


# POST /api/warmup
# Body: [{"spreadsheetId": "...", "sheetName": "..."}]
# Pre-warms cache for a page's sheets. Runs in background — returns immediately.
@app.post("/api/warmup")
def warmup(sheets: list[dict]):
    valid = [
        {"spreadsheetId": s["spreadsheetId"].strip(), "sheetName": s["sheetName"].strip()}
        for s in sheets
        if (s.get("spreadsheetId") or "").strip() and (s.get("sheetName") or "").strip()
    ]

    def _do():
        warmed = []
        workers = min(WARMUP_WORKERS, len(valid)) if valid else 1
        with ThreadPoolExecutor(max_workers=workers) as pool:
            future_to_sheet = {pool.submit(_warmup_if_needed, s, "warmup"): s for s in valid}
            for fut in as_completed(future_to_sheet):
                s = future_to_sheet[fut]
                try:
                    if fut.result():
                        warmed.append(s)
                except Exception as e:
                    logger.warning(f"[warmup] {s['sheetName']}: {e}")
        if warmed:
            _update_registry(warmed)

    threading.Thread(target=_do, daemon=True).start()
    return {"message": f"Warmup started for {len(valid)} sheet(s)"}


# POST /api/warmup-all
# Re-warms all registered sheets whose cache has gone stale.
@app.post("/api/warmup-all")
def warmup_all():
    with _registry_lock:
        sheets = list(_registry)

    if not sheets:
        return {"message": "Registry is empty — nothing to warm up"}

    def _do():
        logger.info(f"[warmup-all] Starting: {len(sheets)} sheet(s), workers={WARMUP_WORKERS}")
        with ThreadPoolExecutor(max_workers=WARMUP_WORKERS) as pool:
            future_to_sheet = {pool.submit(_warmup_if_needed, s, "warmup-all"): s for s in sheets}
            for fut in as_completed(future_to_sheet):
                s = future_to_sheet[fut]
                try:
                    fut.result()
                except Exception as e:
                    logger.warning(f"[warmup-all] {s['sheetName']}: {e}")
        logger.info("[warmup-all] Done")

    threading.Thread(target=_do, daemon=True).start()
    return {"message": f"Warmup-all started for {len(sheets)} sheet(s)"}


# GET /api/cache/stats
@app.get("/api/cache/stats")
def cache_stats():
    now = time.time() * 1000
    with _cache_lock:
        data_entries = [
            {"key": k, "age_s": round((now - v["ts"]) / 1000)}
            for k, v in _cache.items()
        ]
    with _error_cache_lock:
        error_entries = [
            {"key": k, "status": v["status"], "age_s": round((now - v["ts"]) / 1000)}
            for k, v in _error_cache.items()
        ]
    with _registry_lock:
        registry_count = len(_registry)
    return {
        "data_cache": {"count": len(data_entries), "entries": data_entries},
        "error_cache": {"count": len(error_entries), "entries": error_entries},
        "registry": {"count": registry_count},
    }


# POST /api/cache/clear
@app.post("/api/cache/clear")
def clear_cache():
    with _cache_lock:
        count = len(_cache)
        _cache.clear()
    with _error_cache_lock:
        err_count = len(_error_cache)
        _error_cache.clear()
    logger.info(f"Cache cleared ({count} data + {err_count} error entries)")
    return {"message": f"Cache cleared ({count} data + {err_count} error entries)"}


# POST /api/export
# Body: { "spreadsheetId": "...", "sheetName": "..." }
# Returns XLSX built from cached data (open the modal first to populate the cache).

class ExportRequest(BaseModel):
    spreadsheetId: str
    sheetName: str


@app.post("/api/export")
def export_xlsx(req: ExportRequest):
    sid = req.spreadsheetId.strip()
    sname = req.sheetName.strip()
    cache_key = f"{sid}::{sname}"

    cached = get_cached(cache_key)
    if not cached:
        raise HTTPException(
            status_code=404,
            detail="Данные не найдены в кэше. Сначала откройте таблицу в браузере.",
        )

    headers = cached.get("headers") or []
    data = cached.get("data") or []
    cached_col_widths = cached.get("columnWidths") or []
    cached_row_heights = cached.get("rowHeights") or {}
    num_rows = len(data) + 1  # including header row

    # Skip per-cell formatting for large sheets — the includeGridData payload is
    # enormous for 5k+ rows and will OOM or timeout the process.
    use_fmt = num_rows <= EXPORT_FORMAT_MAX_ROWS

    fmt_row_data: list = []
    fmt_col_meta: list = []
    fmt_row_meta: list = []
    merges: list = []

    if use_fmt:
        def do_get_format():
            svc = get_sheets_service()
            return svc.spreadsheets().get(
                spreadsheetId=sid,
                ranges=[f"'{sname}'!1:{num_rows}"],
                includeGridData=True,
                fields=(
                    "sheets(properties(title),"
                    "data(startRow,startColumn,"
                    "columnMetadata(pixelSize),"
                    "rowMetadata(pixelSize),"
                    "rowData(values(effectiveFormat))),"
                    "merges)"
                ),
            ).execute()

        try:
            fmt_res = _with_retry(do_get_format)
            for s in fmt_res.get("sheets", []):
                if s.get("properties", {}).get("title") == sname:
                    merges = s.get("merges", [])
                    blocks = s.get("data", [])
                    if blocks:
                        b = blocks[0]
                        fmt_row_data = b.get("rowData", [])
                        fmt_col_meta = b.get("columnMetadata", [])
                        fmt_row_meta = b.get("rowMetadata", [])
                    break
        except Exception as e:
            logger.warning(f"[export] Formatting fetch failed ({e}) — using basic style")
            use_fmt = False

    def _rgb_hex(color: dict) -> str | None:
        if not color:
            return None
        r = round(color.get("red", 0) * 255)
        g = round(color.get("green", 0) * 255)
        b = round(color.get("blue", 0) * 255)
        h = f"#{r:02X}{g:02X}{b:02X}"
        return None if h in ("#FFFFFF", "#000000") else h

    _BORDER_STYLE = {
        "SOLID": 1, "SOLID_MEDIUM": 2, "SOLID_THICK": 5,
        "DOTTED": 4, "DASHED": 8, "DOUBLE": 6,
    }

    output = io.BytesIO()
    workbook_opts = {"in_memory": True} if use_fmt else {"constant_memory": True}
    workbook = xlsxwriter.Workbook(output, workbook_opts)
    worksheet = workbook.add_worksheet(sname[:31])

    fmt_cache: dict = {}

    def _get_fmt(eff: dict | None):
        key = json.dumps(eff, sort_keys=True, default=str) if eff else ""
        if key in fmt_cache:
            return fmt_cache[key]

        p: dict = {}
        if eff:
            bg = eff.get("backgroundColor") or (
                eff.get("backgroundColorStyle") or {}
            ).get("rgbColor")
            if bg:
                h = _rgb_hex(bg)
                if h:
                    p["bg_color"] = h

            tf = eff.get("textFormat") or {}
            if tf.get("bold"):           p["bold"] = True
            if tf.get("italic"):         p["italic"] = True
            if tf.get("strikethrough"):  p["font_strikeout"] = True
            if tf.get("underline"):      p["underline"] = 1
            if tf.get("fontSize"):       p["font_size"] = tf["fontSize"]
            if tf.get("fontFamily"):     p["font_name"] = tf["fontFamily"]
            fg = tf.get("foregroundColor") or (
                tf.get("foregroundColorStyle") or {}
            ).get("rgbColor")
            if fg:
                h = _rgb_hex(fg)
                if h:
                    p["font_color"] = h

            ha = eff.get("horizontalAlignment", "").upper()
            if ha in ("LEFT", "CENTER", "RIGHT"):
                p["align"] = ha.lower()
            va = eff.get("verticalAlignment", "").upper()
            va_map = {"TOP": "top", "MIDDLE": "vcenter", "BOTTOM": "bottom"}
            if va in va_map:
                p["valign"] = va_map[va]

            if eff.get("wrapStrategy") == "WRAP":
                p["text_wrap"] = True

            nf = (eff.get("numberFormat") or {}).get("pattern")
            if nf:
                p["num_format"] = nf

            for side in ("top", "bottom", "left", "right"):
                bd = (eff.get("borders") or {}).get(side) or {}
                bs = _BORDER_STYLE.get(bd.get("style", ""), 0)
                if bs:
                    p[side] = bs
                    bc = bd.get("color") or (bd.get("colorStyle") or {}).get("rgbColor")
                    if bc:
                        h = _rgb_hex(bc)
                        if h:
                            p[f"{side}_color"] = h

        fmt = workbook.add_format(p)
        fmt_cache[key] = fmt
        return fmt

    # Column widths (pixels → Excel char units, ~7 px per char)
    for ci in range(len(headers)):
        px = (fmt_col_meta[ci].get("pixelSize") if ci < len(fmt_col_meta) else None) \
            or (cached_col_widths[ci] if ci < len(cached_col_widths) else None)
        if px:
            worksheet.set_column(ci, ci, min(px / 7, 80))
        else:
            max_len = max(
                (len(str(row[ci])) for row in data if ci < len(row) and row[ci] is not None),
                default=0,
            )
            worksheet.set_column(ci, ci, min(max(len(str(headers[ci])), max_len) + 2, 50))

    # Track top-left cells of merged ranges so we skip writing duplicates
    merged_skip: set = set()
    if use_fmt:
        for mg in merges:
            sr, er = mg.get("startRowIndex", 0), mg.get("endRowIndex", 0) - 1
            sc, ec = mg.get("startColumnIndex", 0), mg.get("endColumnIndex", 0) - 1
            for r in range(sr, er + 1):
                for c in range(sc, ec + 1):
                    if r != sr or c != sc:
                        merged_skip.add((r, c))

    for ri in range(num_rows):
        px_h = (fmt_row_meta[ri].get("pixelSize") if ri < len(fmt_row_meta) else None)
        if px_h is None and ri > 0:
            px_h = cached_row_heights.get(ri - 1) or cached_row_heights.get(str(ri - 1))
        if px_h:
            worksheet.set_row(ri, px_h * 0.75)

        rd = fmt_row_data[ri] if ri < len(fmt_row_data) else {}
        cell_vals = (rd.get("values") or []) if rd else []

        for ci in range(len(headers)):
            if (ri, ci) in merged_skip:
                continue
            eff = (cell_vals[ci].get("effectiveFormat") if ci < len(cell_vals) else None)
            fmt = _get_fmt(eff)
            val = headers[ci] if ri == 0 else (
                data[ri - 1][ci] if ci < len(data[ri - 1]) else ""
            )
            if val is None:
                val = ""
            worksheet.write(ri, ci, val, fmt)

    # constant_memory mode doesn't support merge_range — return early for large sheets
    if not use_fmt:
        worksheet.freeze_panes(1, 0)
        workbook.close()
        output.seek(0)
        filename = f"{sname}.xlsx"
        encoded = quote(filename)
        safe_ascii = sname.encode("ascii", "replace").decode().replace("?", "_") + ".xlsx"
        return StreamingResponse(
            output,
            media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            headers={"Content-Disposition": f"attachment; filename=\"{safe_ascii}\"; filename*=UTF-8''{encoded}"},
        )

    for mg in merges:
        sr, er = mg.get("startRowIndex", 0), mg.get("endRowIndex", 0) - 1
        sc, ec = mg.get("startColumnIndex", 0), mg.get("endColumnIndex", 0) - 1
        if sr >= num_rows or sc >= len(headers):
            continue
        er, ec = min(er, num_rows - 1), min(ec, len(headers) - 1)
        if sr == er and sc == ec:
            continue
        rd = fmt_row_data[sr] if sr < len(fmt_row_data) else {}
        cell_vals = (rd.get("values") or []) if rd else []
        eff = (cell_vals[sc].get("effectiveFormat") if sc < len(cell_vals) else None)
        val = headers[sc] if sr == 0 else (
            data[sr - 1][sc] if sc < len(data[sr - 1]) else ""
        )
        if val is None:
            val = ""
        try:
            worksheet.merge_range(sr, sc, er, ec, val, _get_fmt(eff))
        except Exception:
            pass  # ignore overlapping merge errors

    worksheet.freeze_panes(1, 0)
    workbook.close()
    output.seek(0)

    filename = f"{sname}.xlsx"
    encoded = quote(filename)
    safe_ascii = sname.encode("ascii", "replace").decode().replace("?", "_") + ".xlsx"
    return StreamingResponse(
        output,
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": f"attachment; filename=\"{safe_ascii}\"; filename*=UTF-8''{encoded}"},
    )
