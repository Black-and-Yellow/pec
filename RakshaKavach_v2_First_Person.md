# RakshaKavach v2 — Rebuilt Against Real 2026 Fraud Data

I built RakshaKavach v2 around one simple belief: detecting a scam is not enough. The system should also help the victim take the next step before panic, confusion, or hesitation causes them to do nothing.

When I looked at the latest fraud data, I realized that the original version needed to change. India lost roughly ₹22,495 crore to cyber fraud in 2025. Complaint volume reached around 2.81 million cases, RBI reported a 34% rise in digital payment fraud, and one survey found that 51% of UPI fraud victims never reported what happened. That statistic became the foundation of my solution. My goal is not only to prevent fraud, but also to remove the friction that stops victims from reporting it.

## What I changed

### 1. I narrowed the scope honestly.

Instead of claiming to stop every UPI scam, I focus on QR-code fraud and fake collect-request scams, where users can scan a QR code or paste a UPI payment link before paying.

For digital-arrest scams, I connect this solution with **Raksha Sathi**, which uses the same backend but accepts forwarded screenshots instead. Together, both products share a scam-classification engine while solving different parts of the fraud landscape.

### 2. I replaced the "merchant registry" idea.

Rather than relying on a national merchant database that doesn't exist, I built the risk score using signals that can actually be computed, including:

- Whether this is a first-time payee
- Approximate account/VPA age
- Transaction amount compared to normal behavior
- Suspicious onboarding patterns
- Other heuristic fraud indicators

This makes the model realistic and defensible.

### 3. I changed blocking into a tiered response.

Instead of blocking every suspicious payment, I use three confidence levels.

- **Low risk:** show information only.
- **Medium risk:** show a warning that the user may dismiss.
- **High risk:** pause the payment and prepare the next actions.

At the highest tier, I generate a pre-filled cybercrime complaint and a trusted-contact alert, but I still ask for one confirmation before sending them.

### 4. I prioritized the trusted-contact alert.

Digital-arrest scams isolate victims from their families. Because of that, I believe notifying a trusted contact is the most valuable feature in the system. If development time becomes limited, I would always preserve this capability before adding extra polish elsewhere.

## How RakshaKavach works

The user scans a QR code or pastes a UPI payment request before making the payment.

My heuristic model evaluates the payment using multiple fraud signals and assigns a confidence score.

Depending on the score:

- Safe payments continue normally.
- Medium-risk payments show a dismissible warning.
- High-risk payments are paused while the system prepares a cybercrime report and trusted-contact notification for one-tap confirmation.

The AI agent drafts both actions automatically, while the user remains in control of the final submission.

## Technology Stack

- Heuristic fraud-scoring engine
- QR and payment-link parser
- LLM tool calling for report generation
- Notification service for trusted-contact alerts
- Seeded dataset containing QR-swap and fake collect-request scams

## Scope

I want to be transparent about the current scope.

RakshaKavach can analyze payment requests that users intentionally bring into the application by scanning a QR code or pasting a UPI link.

It does not intercept transactions happening directly inside Google Pay or PhonePe. Supporting that would require Android Accessibility Services and additional permissions, which are outside a 36-hour hackathon build.

## Build Plan

**0–6 hours:** Build and test the heuristic scoring model.

**6–16 hours:** Develop the three-tier response interface.

**16–24 hours:** Integrate report drafting and trusted-contact notifications.

**24–30 hours:** Tune thresholds to reduce false positives.

**30–36 hours:** Rehearse and freeze the demo.

## Demo

First, I scan a legitimate payment request to demonstrate that the system does not raise unnecessary alarms.

Next, I scan a medium-risk payment request and show the warning experience.

Finally, I scan a known scam QR code. The payment pauses, the complaint and trusted-contact alert are generated automatically, and with one confirmation both actions are sent.

This demonstrates not only detection, but also calibrated decision-making and rapid response.

## Why I believe this solution is stronger

I intentionally designed RakshaKavach to answer the difficult questions before judges ask them.

I clearly define which scams it covers and which ones it does not.

I use explainable heuristic signals instead of an unavailable merchant registry.

I reduce false positives through tiered risk levels.

Finally, I keep the user in control by asking for confirmation before any irreversible action.

My goal is not to claim that I can stop every cyber scam. My goal is to build a practical, realistic, and trustworthy system that can meaningfully reduce losses while making it dramatically easier for victims to respond immediately.
