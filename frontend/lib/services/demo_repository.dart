import '../models/payment.dart';
import '../models/risk.dart';

final class DemoRepository {
  const DemoRepository();

  static const List<DemoScenario> bundled = <DemoScenario>[
    DemoScenario(
      id: 'coffee-shop',
      title: 'Coffee-shop QR',
      subtitle: 'Known recipient · ₹180',
      payment: Payment(
        upiUri:
            'upi://pay?pa=coffee.corner%40okaxis&pn=Coffee%20Corner&am=180.00&cu=INR&tn=Coffee',
        payeeVpa: 'coffee.corner@okaxis',
        payeeName: 'Coffee Corner',
        amount: 180,
        note: 'Coffee',
        currency: 'INR',
      ),
      assessment: RiskAssessment(
        score: 0,
        level: RiskLevel.safe,
        signals: <RiskSignal>[],
        recommendedAction:
            'Verify the recipient details, then continue in your usual UPI app if they are correct.',
      ),
    ),
    DemoScenario(
      id: 'tea-stall',
      title: 'Tea-stall sticker QR',
      subtitle: 'Static merchant QR · amount entered later',
      payment: Payment(
        upiUri: 'upi://pay?pa=chai.point%40okicici&pn=Chai%20Point&cu=INR',
        payeeVpa: 'chai.point@okicici',
        payeeName: 'Chai Point',
        currency: 'INR',
      ),
      assessment: RiskAssessment(
        score: 23,
        level: RiskLevel.safe,
        signals: <RiskSignal>[
          RiskSignal(
            code: 'FIRST_TIME_PAYEE',
            label: 'This is a first-time recipient on this device',
            weight: 18,
            evidence:
                'No completed payment to this VPA exists in this device\'s local history',
          ),
          RiskSignal(
            code: 'AMOUNT_NOT_SPECIFIED',
            label: 'Payment amount is not specified',
            weight: 5,
            evidence:
                'The amount will be entered in your UPI app. This is normal for a static merchant QR, so FinGuard weights it lightly on its own.',
          ),
        ],
        recommendedAction:
            'Verify the recipient details, then continue in your usual UPI app if they are correct.',
      ),
    ),
    DemoScenario(
      id: 'marketplace-seller',
      title: 'Marketplace seller',
      subtitle: 'First-time recipient · ₹4,500',
      payment: Payment(
        upiUri:
            'upi://pay?pa=swift.resale%40okaxis&pn=Marketplace%20Seller&am=4500.00&cu=INR&tn=Order%20payment',
        payeeVpa: 'swift.resale@okaxis',
        payeeName: 'Marketplace Seller',
        amount: 4500,
        note: 'Order payment',
        currency: 'INR',
      ),
      assessment: RiskAssessment(
        score: 33,
        level: RiskLevel.caution,
        signals: <RiskSignal>[
          RiskSignal(
            code: 'FIRST_TIME_PAYEE',
            label: 'This is a first-time recipient on this device',
            weight: 18,
            evidence:
                'No completed payment to this VPA exists in this device\'s local history',
          ),
          RiskSignal(
            code: 'AMOUNT_SCALED_BY_TRUST',
            label: "Amount risk is scaled by the recipient's network record",
            weight: 15,
            evidence:
                'INR 4500.00 is high for a new recipient; payee trust grade NEW '
                'scales this contribution.',
          ),
        ],
        recommendedAction:
            'Check the recipient independently and review the amount before deliberately continuing.',
      ),
    ),
    DemoScenario(
      id: 'fake-kyc',
      title: 'Fake KYC request',
      subtitle: 'Seeded scam recipient · ₹25,000',
      payment: Payment(
        upiUri:
            'upi://pay?pa=secure-kyc-update%40okaxis&pn=KYC%20Support&am=25000.00&cu=INR&tn=Urgent%20KYC%20account%20block&tr=DEMO-KYC-001',
        payeeVpa: 'secure-kyc-update@okaxis',
        payeeName: 'KYC Support',
        amount: 25000,
        note: 'Urgent KYC account block',
        currency: 'INR',
        transactionReference: 'DEMO-KYC-001',
      ),
      assessment: RiskAssessment(
        score: 100,
        level: RiskLevel.highRisk,
        signals: <RiskSignal>[
          RiskSignal(
            code: "PAYEE_ADDRESS_PRETEXT",
            label: "The address names a reason to pay rather than a payee",
            weight: 16,
            evidence:
                "The word secure appears in the address itself. Genuine payees are named after a person or a shop, not after the excuse for the payment.",
          ),
          RiskSignal(
            code: "SEEDED_FRAUD_MATCH",
            label: "Recipient matches a seeded scam indicator",
            weight: 30,
            evidence:
                "VPA matched 'Seeded fake KYC payment recipient' in clearly labelled seeded demo data",
          ),
          RiskSignal(
            code: "FIRST_TIME_PAYEE",
            label: "This is a first-time recipient on this device",
            weight: 18,
            evidence:
                "No completed payment to this VPA exists in this device's local history",
          ),
          RiskSignal(
            code: "MULE_ACCOUNT_SIGNATURE",
            label: "This address is collecting like a money-mule account",
            weight: 22,
            evidence:
                "57 different people have checked this address in 9 day(s), 89% for the first and only time. Mule accounts collect from many unrelated payers at once, then go quiet. A busy new business can look the same, so treat this as a reason to confirm who you are paying, not as proof of fraud.",
          ),
          RiskSignal(
            code: "PAYEE_NAME_UNVERIFIED",
            label: "The claimed payee name is not independently verified",
            weight: 0,
            evidence:
                "The payee name comes from the payment request and cannot be verified from the VPA alone. Compare it against the bank-verified name your UPI app is required to show on the confirmation screen.",
          ),
          RiskSignal(
            code: "AMOUNT_SCALED_BY_TRUST",
            label: "Amount risk is scaled by the recipient's network record",
            weight: 20,
            evidence:
                "INR 25000.00 is high for a new recipient; payee trust grade D scales this contribution.",
          ),
          RiskSignal(
            code: "QR_PROVENANCE_MISSING",
            label: "Merchant-shaped QR does not include provenance fields",
            weight: 8,
            evidence:
                "The supplied QR describes a priced merchant payment but does not include a sign or organisation identifier. FinGuard only checks field presence; it cannot validate NPCI signatures.",
          ),
          RiskSignal(
            code: "SUSPICIOUS_PAYMENT_NOTE",
            label:
                "Payment note contains suspicious pressure or pretext language",
            weight: 10,
            evidence:
                "The supplied payment note contains urgency, KYC, support, or reward wording",
          ),
          RiskSignal(
            code: "SEEDED_IDENTIFIER_RELATIONSHIP",
            label: "Recipient is linked to other seeded suspicious identifiers",
            weight: 8,
            evidence:
                "Seeded demo data links this VPA to 4 other identifier(s) and 3 seeded report(s)",
          ),
          RiskSignal(
            code: "CONTEXT_URGENCY",
            label: "Message applies unusual urgency or pressure",
            weight: 8,
            evidence: "User-supplied context analysis flagged urgency language",
          ),
          RiskSignal(
            code: "CONTEXT_KYC_THREAT",
            label: "Message uses a KYC or account-blocking threat",
            weight: 10,
            evidence:
                "User-supplied context analysis flagged a KYC-related threat",
          ),
        ],
        recommendedAction:
            "Stop the UPI handoff and verify the recipient independently. Prepare recovery actions if you already paid.",
      ),
    ),
  ];

  Future<DemoScenario> load(String id) => Future<DemoScenario>.value(
    bundled.firstWhere((DemoScenario scenario) => scenario.id == id),
  );
}
