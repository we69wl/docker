from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
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