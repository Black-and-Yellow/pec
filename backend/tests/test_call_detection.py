from __future__ import annotations

from decimal import Decimal

import pytest

from app.schemas import (
    CallActivity,
    EnvironmentSignals,
    PaymentDetails,
    RemoteAccessTool,
    RiskLevel,
)
from app.services.risk_engine import RiskEngine, RiskInputs


def assess(environment: EnvironmentSignals | None):
    return RiskEngine().score(
        RiskInputs(
            payment=PaymentDetails(
                vpa="coffee.corner@okaxis",
                payee_name="Coffee Corner",
                amount="180.00",
            ),
            known_payee=True,
            typical_amount=Decimal("240"),
            indicator=None,
            environment=environment,
        )
    )


def codes(result) -> list[str]:
    return [signal.code for signal in result.signals]


def test_no_environment_reported_leaves_the_score_untouched() -> None:
    result = assess(None)
    assert codes(result) == ["PAYEE_NAME_UNVERIFIED"]
    assert result.signals[0].weight == 0
    assert result.score == 0


def test_a_check_with_no_call_adds_nothing() -> None:
    result = assess(EnvironmentSignals(call_activity=CallActivity.NONE))
    assert codes(result) == ["PAYEE_NAME_UNVERIFIED"]
    assert result.signals[0].weight == 0
    assert result.score == 0


@pytest.mark.parametrize(
    "activity",
    [CallActivity.CELLULAR, CallActivity.VOICE_OVER_IP, CallActivity.UNKNOWN],
)
def test_an_active_call_of_any_kind_raises_the_score(activity: CallActivity) -> None:
    result = assess(EnvironmentSignals(call_activity=activity))
    assert codes(result) == ["ACTIVE_CALL_DURING_CHECK", "PAYEE_NAME_UNVERIFIED"]
    assert result.score == 18


def test_an_internet_call_is_named_as_such_in_the_evidence() -> None:
    result = assess(EnvironmentSignals(call_activity=CallActivity.VOICE_OVER_IP))
    assert "WhatsApp" in result.signals[0].evidence


def test_a_ringing_call_is_weighted_far_below_an_answered_one() -> None:
    result = assess(EnvironmentSignals(call_activity=CallActivity.RINGING))
    assert codes(result) == ["INCOMING_CALL_DURING_CHECK", "PAYEE_NAME_UNVERIFIED"]
    assert result.score == 6


def test_a_call_plus_remote_access_escalates_beyond_the_sum_of_its_parts() -> None:
    result = assess(
        EnvironmentSignals(
            call_activity=CallActivity.CELLULAR,
            remote_access_tools=[RemoteAccessTool.ANYDESK],
        )
    )
    assert codes(result) == [
        "REMOTE_ACCESS_TOOL_PRESENT",
        "ACTIVE_CALL_DURING_CHECK",
        "SCREEN_SHARE_DURING_CALL",
        "PAYEE_NAME_UNVERIFIED",
    ]
    # 25 + 18 + 12: the pairing is the digital-arrest setup, so a known payee
    # and a familiar amount still land in the top band.
    assert result.score == 55
    assert result.level is RiskLevel.CAUTION


def test_a_ringing_call_does_not_trigger_the_screen_share_escalation() -> None:
    result = assess(
        EnvironmentSignals(
            call_activity=CallActivity.RINGING,
            remote_access_tools=[RemoteAccessTool.ANYDESK],
        )
    )
    assert "SCREEN_SHARE_DURING_CALL" not in codes(result)


def test_an_unspecified_amount_is_escalated_when_a_call_is_live() -> None:
    result = RiskEngine().score(
        RiskInputs(
            payment=PaymentDetails(vpa="chai.point@okicici"),
            known_payee=True,
            typical_amount=Decimal("240"),
            indicator=None,
            environment=EnvironmentSignals(call_activity=CallActivity.CELLULAR),
        )
    )
    amount_signal = next(s for s in result.signals if s.code == "AMOUNT_NOT_SPECIFIED")
    assert amount_signal.weight == 20
