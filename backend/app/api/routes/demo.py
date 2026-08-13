from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, Depends
from pydantic import TypeAdapter

from app.api.dependencies import get_context_integrity
from app.schemas import DemoScenario, DemoScenariosResponse
from app.services.context_integrity import ContextIntegrityService

router = APIRouter(prefix="/demo", tags=["demo"])
DATA_FILE = Path(__file__).resolve().parents[3] / "data" / "demo_scenarios.json"


@lru_cache(maxsize=1)
def _scenarios() -> tuple[DemoScenario, ...]:
    with DATA_FILE.open(encoding="utf-8") as handle:
        payload = json.load(handle)
    return tuple(TypeAdapter(list[DemoScenario]).validate_python(payload))


@router.get("/scenarios", response_model=DemoScenariosResponse)
def demo_scenarios(
    integrity: Annotated[ContextIntegrityService, Depends(get_context_integrity)],
) -> DemoScenariosResponse:
    scenarios = [
        scenario.model_copy(
            update={
                "context_token": integrity.issue(
                    scenario.context,
                    provenance="demo",
                )
            }
        )
        if scenario.context is not None
        else scenario
        for scenario in _scenarios()
    ]
    return DemoScenariosResponse(scenarios=scenarios)
