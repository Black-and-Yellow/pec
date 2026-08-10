from __future__ import annotations

import json
from datetime import datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

from sqlalchemy.orm import Session

from app.db.models import FraudIndicator, Transaction

DATA_DIRECTORY = Path(__file__).resolve().parents[2] / "data"


def _load_json(filename: str) -> list[dict[str, Any]]:
    with (DATA_DIRECTORY / filename).open(encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, list):
        raise ValueError(f"{filename} must contain a JSON array")
    return payload


def seed_demo_data(session: Session) -> None:
    for item in _load_json("demo_fraud_indicators.json"):
        indicator = session.get(FraudIndicator, item["id"])
        if indicator is None:
            indicator = FraudIndicator(id=item["id"])
            session.add(indicator)
        indicator.indicator_type = item["indicator_type"]
        indicator.normalized_value = item["value"].strip().lower()
        indicator.label = item["label"]
        indicator.report_count = int(item["report_count"])
        indicator.relationships = item["relationships"]
        indicator.source = item["source"]

    for item in _load_json("demo_transaction_history.json"):
        transaction = session.get(Transaction, item["id"])
        if transaction is None:
            transaction = Transaction(id=item["id"])
            session.add(transaction)
        transaction.device_id = item["device_id"]
        transaction.vpa = item["vpa"].strip().lower()
        transaction.payee_name = item.get("payee_name")
        transaction.amount = Decimal(item["amount"])
        transaction.transaction_note = item.get("transaction_note")
        transaction.currency = item.get("currency", "INR")
        transaction.transaction_reference = item.get("transaction_reference")
        transaction.status = "COMPLETED"
        transaction.source = "SEEDED_DEMO_HISTORY"
        transaction.created_at = datetime.fromisoformat(
            item["completed_at"].replace("Z", "+00:00")
        )
    session.commit()
