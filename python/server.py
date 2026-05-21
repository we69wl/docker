import io
import os
import csv
import json
from urllib.parse import quote
import time
import requests as req_lib
from googleapiclient.http import MediaIoBaseDownload
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import StreamingResponse
# from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Optional
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

SCOPES = [
    'https://www.googleapis.com/auth/spreadsheets.readonly',
    'https://www.googleapis.com/auth/drive.readonly',
]
SERVICE_ACCOUNT_FILE = os.getenv("CREDENTIALS_FILE", 'credentials.json')

# Row heights fetched only for first N rows to avoid 504 timeouts on large sheets
ROW_META_ROWS = int(os.getenv("ROW_META_ROWS", "50"))

# XLSX export: skip per-cell formatting fetch for sheets larger than this many rows
EXPORT_FORMAT_MAX_ROWS = int(os.getenv("EXPORT_FORMAT_MAX_ROWS", "5000"))

# ── Google Sheets service — new per request ───────────────────────────────────

def get_sheets_service():
    creds = service_account.Credentials.from_service_account_file(
        SERVICE_ACCOUNT_FILE, scopes=SCOPES
    )
    return build('sheets', 'v4', credentials=creds)


def get_drive_service():
    creds = service_account.Credentials.from_service_account_file(
        SERVICE_ACCOUNT_FILE, scopes=SCOPES
    )
    return build('drive', 'v3', credentials=creds)


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


# ── Error helpers ─────────────────────────────────────────────────────────────

def _get_sheet_names(spreadsheetId: str) -> list:
    def do_get():
        svc = get_sheets_service()
        res = svc.spreadsheets().get(
            spreadsheetId=spreadsheetId,
            fields="sheets(properties(title))",
        ).execute()
        return [s["properties"]["title"] for s in res.get("sheets", [])]
    return _with_retry(do_get)


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
    t_start = time.perf_counter()

    try:
        result = _fetch_all(spreadsheetId, sheetName)
        logger.info(
            f"Fetched: {sheetName} rows={len(result['data'])} "
            f"in {(time.perf_counter() - t_start) * 1000:.0f}ms"
        )
        return result
    except HttpError as e:
        status = int(e.resp.status)
        logger.error(f"[sheet-data] Google API {status}: {e}")
        http_status = status if status in (400, 403, 404) else 502
        raise HTTPException(status_code=http_status, detail=_humanize_google_error(e, sheetName, spreadsheetId))
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


def _fetch_csv_from_drive(file_id: str) -> dict:
    def do_meta():
        svc = get_drive_service()
        return svc.files().get(fileId=file_id, fields="name").execute()

    def do_download():
        svc = get_drive_service()
        buf = io.BytesIO()
        downloader = MediaIoBaseDownload(buf, svc.files().get_media(fileId=file_id))
        done = False
        while not done:
            _, done = downloader.next_chunk()
        buf.seek(0)
        return buf.getvalue()

    meta = _with_retry(do_meta)
    raw  = _with_retry(do_download)

    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
        encoding = "utf-8"
    else:
        try:
            raw.decode("utf-8")
            encoding = "utf-8"
        except UnicodeDecodeError:
            encoding = "cp1251"

    text = raw.decode(encoding)
    rows = [r for r in csv.reader(io.StringIO(text)) if any(c.strip() for c in r)]

    file_name = meta.get("name", file_id)
    headers   = rows[0] if rows else []
    data      = rows[1:] if len(rows) > 1 else []
    return {
        "headers": headers,
        "data": data,
        "columnWidths": [],
        "rowHeights": {},
        "total": len(data),
        "fileName": file_name,
    }


# GET /api/csv-data?fileId=...
# Downloads a CSV file from Google Drive. Service account must have viewer access.
@app.get("/api/csv-data")
def get_csv_data(fileId: str = Query(...)):
    fileId = fileId.strip()
    try:
        result = _fetch_csv_from_drive(fileId)
        logger.info(f"Fetched CSV: {result.get('fileName')} rows={len(result['data'])}")
        return result
    except HttpError as e:
        status = int(e.resp.status)
        http_status = status if status in (403, 404) else 502
        detail = (
            "Нет доступа к файлу. Поделитесь им с сервисным аккаунтом."
            if status == 403
            else "Файл не найден. Проверьте ID файла."
            if status == 404
            else str(e) or "Не удалось загрузить файл."
        )
        raise HTTPException(status_code=http_status, detail=detail)
    except Exception as e:
        logger.error(f"[csv-data] {e}")
        raise HTTPException(status_code=500, detail=str(e) or "Не удалось загрузить CSV файл.")


# GET /api/json-data?url=...
# Accepts an absolute URL (https://...) or a local path (/catalog.json).
# Local paths are resolved to data/<filename> relative to cwd and read from disk.
# Expects JSON array: [{ key: value, ... }, ...]
@app.get("/api/json-data")
def get_json_data(url: str = Query(...)):
    url = url.strip()

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

        logger.info(f"Fetched JSON: {url}, rows: {len(data)}")
        return {"headers": headers, "data": data, "columnWidths": [], "rowHeights": {}}

    except HTTPException:
        raise
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail=f"File not found: {os.path.basename(url)}")
    except Exception as e:
        logger.error(f"[json-data] {e}")
        raise HTTPException(status_code=500, detail=str(e) or "Failed to load JSON")


# POST /api/export
# Body: { "spreadsheetId": "...", "sheetName": "...", "jsonUrl": "..." }
# Fetches data fresh and returns an XLSX file.

class ExportRequest(BaseModel):
    spreadsheetId: Optional[str] = None
    sheetName: Optional[str] = None
    jsonUrl: Optional[str] = None
    csvFileId: Optional[str] = None


@app.post("/api/export")
def export_xlsx(req: ExportRequest):
    # ── Fetch data ────────────────────────────────────────────────────────────
    if req.csvFileId:
        file_id = req.csvFileId.strip()
        try:
            fetched = _fetch_csv_from_drive(file_id)
        except HttpError as e:
            status = int(e.resp.status)
            http_status = status if status in (403, 404) else 502
            raise HTTPException(status_code=http_status, detail=str(e))
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))
        headers     = fetched.get("headers") or []
        data        = fetched.get("data") or []
        col_widths: list = []
        row_heights: dict = {}
        sname = os.path.splitext(fetched.get("fileName", file_id))[0]

    elif req.jsonUrl:
        url = req.jsonUrl.strip()
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
            headers = list(json_array[0].keys()) if json_array else []
            data = [[row.get(h, "") for h in headers] for row in json_array]
            col_widths: list = []
            row_heights: dict = {}
            sname = os.path.splitext(os.path.basename(url))[0] or "export"
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e) or "Failed to load JSON")

    elif req.spreadsheetId and req.sheetName:
        sid = req.spreadsheetId.strip()
        sname = req.sheetName.strip()
        try:
            fetched = _fetch_all(sid, sname)
        except HttpError as e:
            status = int(e.resp.status)
            http_status = status if status in (400, 403, 404) else 502
            raise HTTPException(status_code=http_status, detail=_humanize_google_error(e, sname, sid))
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))
        headers = fetched.get("headers") or []
        data = fetched.get("data") or []
        col_widths = fetched.get("columnWidths") or []
        row_heights = fetched.get("rowHeights") or {}
    else:
        raise HTTPException(status_code=400, detail="Provide spreadsheetId+sheetName or jsonUrl")

    num_rows = len(data) + 1  # including header row

    # ── Formatting (Google Sheets only, skipped for large sheets) ─────────────
    use_fmt = bool(req.spreadsheetId) and num_rows <= EXPORT_FORMAT_MAX_ROWS
    fmt_row_data: list = []
    fmt_col_meta: list = []
    fmt_row_meta: list = []
    merges: list = []

    if use_fmt:
        def do_get_format():
            svc = get_sheets_service()
            return svc.spreadsheets().get(
                spreadsheetId=req.spreadsheetId.strip(),
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

    # ── Helpers ───────────────────────────────────────────────────────────────

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

    # ── Build XLSX ────────────────────────────────────────────────────────────
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
            or (col_widths[ci] if ci < len(col_widths) else None)
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
            px_h = row_heights.get(ri - 1) or row_heights.get(str(ri - 1))
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
