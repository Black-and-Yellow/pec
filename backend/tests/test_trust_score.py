from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

from app.repositories.reputation_repository import ReputationSnapshot, unknown_snapshot
from app.schemas import TrustGrade, TrustPillarCode, TrustPillarStatus
from app.services.trust_score import TrustInputs, TrustScorer
from app.services.vpa_identity import HandleClass, analyze_vpa


def snapshot(
    vpa: str,
    *,
    days: int,
    checks: int,
    devices: int,
    safe: int = 0,
    caution: int = 0,
    high: int = 0,
    reported: int = 0,
    recent: int = 0,
) -> ReputationSnapshot:
    now = datetime.now(UTC)
    return ReputationSnapshot(
        vpa=vpa,
        first_seen_at=now - timedelta(days=days),
        last_seen_at=now,
        check_count=checks,
        distinct_device_count=devices,
        safe_count=safe,
        caution_count=caution,
        high_count=high,
        reported_count=reported,
        recent_new_device_count=recent,
    )


def score(vpa: str, reputation: ReputationSnapshot | None = None, label: str | None = None):
    return TrustScorer().score(
        TrustInputs(
            vpa=vpa,
            reputation=reputation or unknown_snapshot(vpa),
            seeded_indicator_label=label,
        )
    )


class TestVpaIdentity:
    def test_recognized_consumer_handle_earns_identity_points(self) -> None:
        identity = analyze_vpa("ramesh.kumar@okaxis")
        assert identity.handle_class is HandleClass.CONSUMER_PSP
        assert identity.points == 28
        assert not identity.is_impersonation

    def test_borrowed_bank_name_on_a_personal_handle_is_impersonation(self) -> None:
        identity = analyze_vpa("sbi.refund@okaxis")
        assert identity.impersonated_brand == "sbi"
        assert identity.is_impersonation

    def test_a_bank_own_handle_may_use_its_own_name(self) -> None:
        identity = analyze_vpa("sbi.collections@sbi")
        assert identity.impersonated_brand is None
        assert not identity.is_impersonation

    def test_single_character_handle_miss_is_flagged_as_a_lookalike(self) -> None:
        identity = analyze_vpa("ramesh@oksbii")
        assert identity.lookalike_of == "oksbi"
        assert identity.is_impersonation

    def test_pretext_wording_in_the_address_scores_nothing_for_that_check(self) -> None:
        identity = analyze_vpa("kyc-verify-now@ybl")
        assert identity.pretext_token is not None

    def test_phone_derived_address_earns_no_stability_points(self) -> None:
        identity = analyze_vpa("9876543210@ybl")
        codes = {finding.code for finding in identity.findings}
        assert "PHONE_DERIVED_ADDRESS" in codes

    def test_unknown_handle_is_not_treated_as_fraud(self) -> None:
        identity = analyze_vpa("shopkeeper@somenewpsp")
        assert identity.handle_class is HandleClass.UNRECOGNIZED
        assert not identity.is_impersonation

    def test_malformed_address_scores_zero_without_raising(self) -> None:
        identity = analyze_vpa("not-a-vpa")
        assert identity.points == 0


class TestTrustScore:
    def test_a_payee_nobody_has_seen_grades_new_and_withholds_a_number(self) -> None:
        trust = score("new.bakery@okhdfcbank")
        assert trust.grade is TrustGrade.NEW
        assert trust.thin_file is True
        # A thin file must not display a number: identity alone scores high on
        # an address nobody has ever paid, and that reads as a recommendation.
        assert trust.score is None
        assert trust.confidence == "LOW"

    def test_ledger_pillars_report_no_data_for_a_thin_file(self) -> None:
        trust = score("new.bakery@okhdfcbank")
        by_code = {pillar.code: pillar for pillar in trust.pillars}
        assert by_code[TrustPillarCode.IDENTITY].status is not TrustPillarStatus.NO_DATA
        for code in (
            TrustPillarCode.TENURE,
            TrustPillarCode.REACH,
            TrustPillarCode.CONDUCT,
            TrustPillarCode.VELOCITY,
        ):
            assert by_code[code].status is TrustPillarStatus.NO_DATA
        assert trust.assessable_maximum == 30

    def test_long_established_clean_payee_reaches_the_top_band(self) -> None:
        trust = score(
            "coffee.corner@okaxis",
            snapshot(
                "coffee.corner@okaxis",
                days=612,
                checks=1_483,
                devices=412,
                safe=1_471,
                caution=12,
                recent=9,
            ),
        )
        assert trust.grade is TrustGrade.A_PLUS
        assert trust.score is not None and trust.score >= 85
        assert trust.confidence == "HIGH"

    def test_impersonation_cannot_be_outweighed_by_tenure_and_reach(self) -> None:
        trust = score(
            "sbi.refund@okaxis",
            snapshot(
                "sbi.refund@okaxis",
                days=800,
                checks=5_000,
                devices=480,
                safe=5_000,
                recent=2,
            ),
        )
        assert trust.grade is TrustGrade.D
        assert trust.impersonation is True
        assert trust.score is not None and trust.score <= 24

    def test_a_reported_payee_drops_to_the_bottom_band(self) -> None:
        trust = score(
            "market.seller@okaxis",
            snapshot(
                "market.seller@okaxis",
                days=200,
                checks=300,
                devices=120,
                safe=280,
                reported=4,
                recent=5,
            ),
        )
        assert trust.grade is TrustGrade.D

    def test_a_seeded_indicator_zeroes_the_conduct_pillar(self) -> None:
        trust = score(
            "secure-kyc-update@okaxis",
            snapshot("secure-kyc-update@okaxis", days=9, checks=64, devices=57, high=58),
            label="Seeded fake KYC payment recipient",
        )
        conduct = next(p for p in trust.pillars if p.code is TrustPillarCode.CONDUCT)
        assert conduct.points == 0
        assert trust.grade is TrustGrade.D

    def test_a_campaign_burst_costs_the_velocity_pillar(self) -> None:
        trust = score(
            "claim.reward@okaxis",
            snapshot("claim.reward@okaxis", days=10, checks=40, devices=38, high=30, recent=36),
        )
        velocity = next(p for p in trust.pillars if p.code is TrustPillarCode.VELOCITY)
        assert velocity.points == 0

    def test_every_report_carries_its_provenance_disclaimer(self) -> None:
        trust = score("anyone@okaxis")
        assert "not an NPCI" in trust.disclaimer

    @pytest.mark.parametrize(
        "vpa",
        ["coffee.corner@okaxis", "9876543210@ybl", "kyc@unknownpsp", "a@b"],
    )
    def test_scoring_never_raises_for_any_shape_of_address(self, vpa: str) -> None:
        assert score(vpa) is not None
