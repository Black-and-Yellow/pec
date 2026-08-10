from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path

from fastapi import APIRouter
from pydantic import TypeAdapter

from app.schemas import DemoScenario, DemoScenariosResponse

router = APIRouter(prefix="/demo", tags=["demo"])
DATA_FILE = Path(__file__).resolve().parents[3] / "data" / "demo_scenarios.json"


@lru_cache(maxsize=1)
def _scenarios() -> tuple[DemoScenario, ...]:
    with DATA_FILE.open(encoding="utf-8") as handle:
        payload = json.load(handle)
    return tuple(TypeAdapter(list[DemoScenario]).validate_python(payload))


@router.get("/scenarios", response_model=DemoScenariosResponse)
def demo_scenarios() -> DemoScenariosResponse:
    return DemoScenariosResponse(scenarios=list(_scenarios()))
