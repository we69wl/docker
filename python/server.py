import os
import json
import time
import requests as req_lib
from fastapi import FastAPI, HTTPException, Query
# from fastapi.middleware.cors import CORSMiddleware
from google.oauth2 import service_account
from googleapiclient.discovery import build
from dotenv import load_dotenv
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

load_dotenv()

app = FastAPI()

# app.add_middleware(
#     CORSMiddleware,
#     allow_origins=["https://dev6.savin-it.ru", "https://dev.savin-it.ru",  "https://rufago.ru",         ],
#     allow_methods=["GET"],
#     allow_headers=["*"],
# )

SCOPES = ['https://www.googleapis.com/auth/spreadsheets.readonly']
SERVICE_ACCOUNT_FILE = 'credentials.json'

def get_sheets_service():
    creds = service_account.Credentials.from_service_account_file(
        SERVICE_ACCOUNT_FILE, scopes=SCOPES
    )
    return build('sheets', 'v4', credentials=creds)

CACHE_TTL = 60 * 60 * 1000  # 1 час в миллисекундах
cache = {}

MAX_CACHE_SIZE = 100

def get_cached(key):
    entry = cache.get(key)
    if not entry:
        return None
    if time.time() * 1000 - entry['ts'] > CACHE_TTL:
        del cache[key]
        return None
    return entry['data']

def set_cached(key, data):
    if len(cache) >= MAX_CACHE_SIZE:
        oldest = min(cache, key=lambda k: cache[k]['ts'])
        del cache[oldest]
    cache[key] = {'data': data, 'ts': time.time() * 1000}

@app.get("/health")
def health():
    return {"status": "ok"}

@app.get("/")
def root():
    return {"message": "Server is working"}

@app.get("/api/sheet-data")
def get_sheet_data(
    spreadsheetId: str = Query(...),
    sheetName: str = Query(...)
):
    cache_key = f"{spreadsheetId}::{sheetName}"
    cached = get_cached(cache_key)
    if cached:
        logger.info(f"Cache hit: {cache_key}")
        return cached

    try:
        service = get_sheets_service()

        values_res = service.spreadsheets().values().get(
            spreadsheetId=spreadsheetId,
            range=f"'{sheetName}'"
        ).execute()

        meta_res = service.spreadsheets().get(
            spreadsheetId=spreadsheetId,
            fields="sheets(properties(title),data(columnMetadata(pixelSize),rowMetadata(pixelSize)))"
        ).execute()

        sheet_meta = None
        for sheet in meta_res.get('sheets', []):
            if sheet.get('properties', {}).get('title') == sheetName:
                sheet_meta = sheet
                break

        col_meta = sheet_meta.get('data', [{}])[0].get('columnMetadata', []) if sheet_meta else []
        column_widths = [col.get('pixelSize', 100) for col in col_meta]

        row_meta = sheet_meta.get('data', [{}])[0].get('rowMetadata', []) if sheet_meta else []
        row_heights = {}
        for idx, row in enumerate(row_meta):
            pixel_size = row.get('pixelSize')
            if pixel_size and idx >= 1:
                row_heights[idx - 1] = pixel_size

        rows = values_res.get('values', [])
        headers = rows[0] if rows else []
        data = rows[1:] if rows else []

        result = {
            "headers": headers,
            "data": data,
            "columnWidths": column_widths,
            "rowHeights": row_heights,
        }
        set_cached(cache_key, result)
        logger.info(f"Fresh data: {cache_key}")
        return result

    except Exception as e:
        logger.error(f"Error {cache_key}: {e}")
        raise HTTPException(status_code=500, detail=str(e))

# GET /api/json-data?url=...
# Accepts either an absolute URL (https://...) or a local path (/catalog.json).
# Local paths are resolved to data/<filename> relative to cwd and read from disk.
# Expects JSON: [{ key: value, ... }, ...]
@app.get("/api/json-data")
def get_json_data(url: str = Query(...)):
    cache_key = f"json::{url}"
    cached = get_cached(cache_key)
    if cached:
        return cached

    try:
        if url.startswith("/"):
            # Local file — os.path.basename prevents path traversal
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
        return result

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"[json-data] {e}")
        raise HTTPException(status_code=500, detail=str(e) or "Failed to load JSON")

@app.post("/api/cache/clear")
def clear_cache():
    cache.clear()
    return {"message": "Cache cleared"}