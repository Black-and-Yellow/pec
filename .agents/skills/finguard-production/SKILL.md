---
name: finguard-production
description: Harden, test, review, or prepare FinGuard for a production-like release while preserving deterministic UPI risk scoring, privacy, and explicit human confirmation. Use for FinGuard backend, Flutter Web/Android, parser, authentication, deployment, security, QA, release-readiness, or incident-response changes; do not use to add bank/payment execution or unverifiable fraud-intelligence integrations.
---

# FinGuard production hardening

## Workflow

1. Read root `AGENTS.md`, `PLAN.md`, and [acceptance gates](references/acceptance-gates.md).
2. Verify the active branch and preserve existing user changes. Establish the narrow baseline before editing.
3. Prioritize P0 correctness, secrets, trust boundaries, deterministic scoring, and human-control failures; then address evidence-backed P1 readiness gaps.
4. Delegate one bounded implementation or validation surface at a time to the matching High-reasoning FinGuard agent.
5. Add regression coverage for each behavior change. Stop expansion on failure, identify the root cause, fix it, and rerun the focused and relevant regression gates.
6. Record exact commands, outcomes, artifacts, blockers, and decisions in `PLAN.md`. Never report an unexecuted gate as passing.

## Implementation rules

- Keep score weights and thresholds in backend policy; never duplicate them as client authority.
- Validate untrusted input at every trust boundary and keep external provider output schema-bound.
- Keep screenshots, credentials, tokens, passwords, and complete payment input out of logs and reports.
- Preserve explicit confirmation before every external handoff. Never simulate payment, reporting, reversal, or institutional access.
- Prefer direct typed functions and existing dependencies. Document SQLite's single-node boundary instead of migrating it cosmetically.
- Use only local/demo data and no paid services.

## Completion

Finish only after relevant gates pass, an independent read-only review is resolved, `PLAN.md` is current, and local checkpoint commits are created without pushing or deploying.
