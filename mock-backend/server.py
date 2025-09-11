# server.py
from fastapi import FastAPI, Header
from pydantic import BaseModel
from typing import Optional, List
from datetime import datetime
from fastapi.middleware.cors import CORSMiddleware
import json, os, socket

# --- CORS: allow your GitHub Pages origin (no trailing slash) ---
ALLOWED_ORIGINS = [
    "https://brankobajic77.github.io",
]

app = FastAPI(title="Yettel Speed Mock")

# No-cache to avoid stale responses in browsers/CDN
@app.middleware("http")
async def no_cache(request, call_next):
    resp = await call_next(request)
    resp.headers["Cache-Control"] = "no-store, max-age=0"
    resp.headers["Pragma"] = "no-cache"
    resp.headers["Expires"] = "0"
    return resp

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "Accept"],
    max_age=0,
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
    geofenceRadius: Optional[float] = 300  # meters (bigger for easier testing)

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

# --- Seed data: multiple cameras around your area (adjust if needed) ---
# A & B are your two points; others are nearby offsets to have more test points.
CAMERAS: List[CameraDTO] = [
    CameraDTO(id="SOF-A1", lat=42.6281474, lng=23.3711704, direction=270.0),  # A
    CameraDTO(id="SOF-B1", lat=42.6199365, lng=23.3664081, direction=270.0),  # B
    CameraDTO(id="SOF-C1", lat=42.6321474, lng=23.3791704, direction=180.0),  # C (A + ~0.004,+0.008)
    CameraDTO(id="SOF-D1", lat=42.6241474, lng=23.3841704, direction= 90.0),  # D
    CameraDTO(id="SOF-E1", lat=42.6161474, lng=23.3721704, direction= 45.0),  # E
    CameraDTO(id="SOF-F1", lat=42.6211474, lng=23.3811704, direction=315.0),  # F
    CameraDTO(id="SOF-G1", lat=42.6291474, lng=23.3601704, direction=225.0),  # G
    CameraDTO(id="SOF-H1", lat=42.6139474, lng=23.3526704, direction=135.0),  # H
]

# Cover all cameras with some test segments so geofences are drawn for each
SEGMENTS: List[SegmentDTO] = [
    SegmentDTO(name="A→C", startCameraId="SOF-A1", endCameraId="SOF-C1", geofenceRadius=300),
    SegmentDTO(name="C→D", startCameraId="SOF-C1", endCameraId="SOF-D1", geofenceRadius=300),
    SegmentDTO(name="D→F", startCameraId="SOF-D1", endCameraId="SOF-F1", geofenceRadius=300),
    SegmentDTO(name="F→B", startCameraId="SOF-F1", endCameraId="SOF-B1", geofenceRadius=300),
    SegmentDTO(name="B→E", startCameraId="SOF-B1", endCameraId="SOF-E1", geofenceRadius=300),
    SegmentDTO(name="E→G", startCameraId="SOF-E1", endCameraId="SOF-G1", geofenceRadius=300),
    SegmentDTO(name="G→H", startCameraId="SOF-G1", endCameraId="SOF-H1", geofenceRadius=300),
    SegmentDTO(name="H→A", startCameraId="SOF-H1", endCameraId="SOF-A1", geofenceRadius=300),
]

REPORTS_FILE = "avg_speed_reports.json"

# --- Debug on startup ---
print("SERVER FILE:", __file__)
print("SEED CAMERAS:", [(c.id, c.lat, c.lng) for c in CAMERAS])

# Handy debug endpoints
@app.get("/whoami")
def whoami():
    return {
        "file": __file__,
        "host": socket.gethostname(),
        "codespace": os.getenv("CODESPACE_NAME"),
        "time": datetime.utcnow().isoformat() + "Z",
        "cameras": [c.model_dump() for c in CAMERAS],
    }

@app.get("/debug/seed")
def debug_seed():
    return {
        "file": __file__,
        "cameras": [c.model_dump() for c in CAMERAS],
        "segments": [s.model_dump() for s in SEGMENTS],
    }

def _auth_ok(authorization: Optional[str]) -> bool:
    # DEV: accept any "Bearer ..." token. In production validate JWT properly.
    return authorization is None or authorization.startswith("Bearer ")

# --- Health/ping ---
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
