# server.py
from fastapi import FastAPI, Header
from pydantic import BaseModel
from typing import Optional, List
from datetime import datetime
from fastapi.middleware.cors import CORSMiddleware
import json, os

# --- CORS ---
# Allow ONLY your GitHub Pages origin. No trailing slash.
ALLOWED_ORIGINS = [
    "https://brankobajic77.github.io",
]

app = FastAPI(title="Yettel Speed Mock")

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=False,                 # no cookies; keep it false so wildcard isn't required
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "Accept"],
    max_age=86400,
)

# --- DTOs ---
class CameraDTO(BaseModel):
    id: str
    lat: float
    lng: float
    direction: Optional[float] = None   # degrees (0..360), optional

class SegmentDTO(BaseModel):
    name: str
    startCameraId: str
    endCameraId: str
    geofenceRadius: Optional[float] = 120  # meters

class AvgSpeedReportDTO(BaseModel):
    segmentName: str
    startCameraId: str
    endCameraId: str
    startedAt: datetime
    endedAt: datetime
    routeDistanceMeters: float
    avgSpeedKmH: float
    appVersion: str
    deviceId: Optional[str] = None

# --- Seed data (adjust to your area if needed) ---
CAMERAS: List[CameraDTO] = [
    CameraDTO(id="SOF-A1", lat=42.6281474, lng=23.3711704, direction=270.0),
    CameraDTO(id="SOF-B1", lat=42.6199365, lng=23.3664081, direction=270.0),
]
SEGMENTS: List[SegmentDTO] = [
    SegmentDTO(name="Ring A→B", startCameraId="SOF-A1", endCameraId="SOF-B1", geofenceRadius=150),
]
# --- DEBUG prints on startup ---
print("SERVER FILE:", __file__)
print("SEED CAMERAS:", [(c.id, c.lat, c.lng) for c in CAMERAS])

# --- DEBUG endpoint: see what this running process has loaded ---
@app.get("/debug/seed")
def debug_seed():
    return {
        "file": __file__,
        "cameras": [c.model_dump() for c in CAMERAS],
        "segments": [s.model_dump() for s in SEGMENTS],
    }
REPORTS_FILE = "avg_speed_reports.json"

def _auth_ok(authorization: Optional[str]) -> bool:
    # DEV: accept any "Bearer ..." token. In production validate JWT properly.
    return authorization is None or authorization.startswith("Bearer ")

# --- Health/ping (handy for testing in the browser) ---
@app.get("/ping")
def ping():
    return {"status": "ok", "time": datetime.utcnow().isoformat() + "Z"}

# --- API routes ---
@app.get("/v1/traffic/cameras", response_model=List[CameraDTO])
def get_cameras(authorization: Optional[str] = Header(default=None)):
    if not _auth_ok(authorization):
        return []
    return CAMERAS

@app.get("/v1/traffic/segments", response_model=List[SegmentDTO])
def get_segments(authorization: Optional[str] = Header(default=None)):
    if not _auth_ok(authorization):
        return []
    return SEGMENTS

@app.post("/v1/traffic/avg-speed-report")
def post_avg_speed(report: AvgSpeedReportDTO, authorization: Optional[str] = Header(default=None)):
    if not _auth_ok(authorization):
        return {"status": "unauthorized"}

    # Append report to a JSON file (simple dev storage)
    prev = []
    if os.path.exists(REPORTS_FILE):
        with open(REPORTS_FILE, "r") as f:
            try:
                prev = json.load(f)
            except Exception:
                prev = []

    prev.append(json.loads(report.model_dump_json()))
    with open(REPORTS_FILE, "w") as f:
        json.dump(prev, f, indent=2, default=str)

    print("New avg-speed report:", report)
    return {"status": "ok"}
