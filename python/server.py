from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:8080",
        "https://localhost:8443",
        "http://72.56.101.248:8080",
        "https://72.56.101.248:8443",    # ← ДОБАВИТЬ
        "https://72.56.101.248:8443",
        "https://dev.savin-it.ru:8443",
        "*"
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/health")
def health():
    return {"status": "ok"}

@app.get("/")
def root():
    return {"message": "Server is working"}

@app.get("/api/sheet-data")
def get_sheet_data():
    return {"headers": ["Column1"], "data": [["test"]], "columnWidths": [100]}