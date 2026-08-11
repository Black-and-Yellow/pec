from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class RiskWeights:
    seeded_fraud_match: int = 30
    first_time_payee: int = 18
    amount_not_specified: int = 30
    unusual_amount: int = 15
    suspicious_note: int = 10
    identifier_relationship: int = 8
    context_impersonation: int = 8
    context_urgency: int = 8
    context_kyc_threat: int = 10
    context_reward_or_refund: int = 6
    context_suspicious_support: int = 8


@dataclass(frozen=True, slots=True)
class RiskThresholds:
    safe_max: int = 29
    caution_max: int = 69
    minimum_unusual_amount: int = 2_000
    no_history_unusual_amount: int = 4_000
    amount_multiplier: int = 3
    minimum_context_confidence: float = 0.55


WEIGHTS = RiskWeights()
THRESHOLDS = RiskThresholds()
