from fastapi import FastAPI, Header
from pydantic import BaseModel
from typing import Optional, List
from datetime import datetime
from fastapi.middleware.cors import CORSMiddleware
import json, os

app = FastAPI(title="Yettel Speed Mock")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], allow_credentials=True,
    allow_methods=["*"], allow_headers=["*"],
)

class CameraDTO(BaseModel):
    id: str
    lat: float
    lng: float
    direction: Optional[float] = None

class SegmentDTO(BaseModel):
    name: str
    startCameraId: str
    endCameraId: str
    geofenceRadius: Optional[float] = 120

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

CAMERAS: List[CameraDTO] = [
    CameraDTO(id="SOF-A1", lat=42.6510, lng=23.3640, direction=270.0),
    CameraDTO(id="SOF-B1", lat=42.6660, lng=23.3210, direction=270.0),
]
SEGMENTS: List[SegmentDTO] = [
    SegmentDTO(name="Ring A→B", startCameraId="SOF-A1", endCameraId="SOF-B1", geofenceRadius=150),
]

REPORTS_FILE = "avg_speed_reports.json"

def _auth_ok(authorization: Optional[str]) -> bool:
    return authorization is None or authorization.startswith("Bearer ")

@app.get("/v1/traffic/cameras", response_model=List[CameraDTO])
def get_cameras(authorization: Optional[str] = Header(default=None)):
    if not _auth_ok(authorization): return []
    return CAMERAS

@app.get("/v1/traffic/segments", response_model=List[SegmentDTO])
def get_segments(authorization: Optional[str] = Header(default=None)):
    if not _auth_ok(authorization): return []
    return SEGMENTS

@app.post("/v1/traffic/avg-speed-report")
def post_avg_speed(report: AvgSpeedReportDTO, authorization: Optional[str] = Header(default=None)):
    if not _auth_ok(authorization): return {"status": "unauthorized"}
    prev = []
    if os.path.exists(REPORTS_FILE):
        with open(REPORTS_FILE, "r") as f:
            try: prev = json.load(f)
            except Exception: prev = []
    prev.append(json.loads(report.model_dump_json()))
    with open(REPORTS_FILE, "w") as f:
        json.dump(prev, f, indent=2, default=str)
    print("New avg-speed report:", report)
    return {"status": "ok"}
