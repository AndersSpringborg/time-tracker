# Product Revision (Senior Product Owner View)

Last updated: 2026-02-10

## Executive Assessment

Yes, there are too many parallel feature ambitions for a clean 1.0.

Current roadmap + project plan mixes:

- core reliability work,
- product workflow work,
- advanced intelligence,
- integrations,
- platform/ops hardening.

That creates diffuse execution and a weaker product story.

## Recommended 1.0 Product Vision

**One-line vision:**
A local-first tracker that captures work automatically, lets users fix categorization fast, and produces trustworthy daily time logs.

**Primary promise for 1.0:**
- No lost data.
- Minimal manual effort.
- Clear daily workflow.

## Simplified Core Workflow (1.0)

1. Start tracker once, it captures activity continuously.
2. WiFi is always captured as context (for later analysis), not used to block tracking.
3. User opens daily review and sees grouped unmapped work.
4. User labels a few groups, creates reusable rules.
5. Rules apply retroactively for the day.
6. User has a clean daily report.

If this workflow is fast and reliable, 1.0 wins.

## What To Keep in 1.0 (Must-Have)

## A. Trust and reliability
- Migration parity (Go/Zig) and migration drift guard.
- Pre-migration backup for file DB.
- Buffered-write retry behavior (no silent event loss).
- Graceful shutdown flush.

## B. Capture quality
- Always-on tracking.
- WiFi SSID capture persisted on events.
- Idle/AFK detection (to reduce false active time).

## C. Fast correction loop
- Review grouped unmapped events.
- Label group -> map now -> create rule.
- Apply rules for date scope.

## D. Minimum release operability
- Basic health/readiness signal.
- Critical test coverage for review/lifecycle/settings and CLI behavior.

## What To Cut or Defer (for cleaner 1.0)

## Defer to Release 2
- Bayesian/ML classifier.
- Git branch integration.
- Calendar integration.
- Advanced heuristic explainability UI polish.
- WiFi transition boundary modeling (nice-to-have analytics refinement).

## De-scope from 1.0 success criteria
- Any large UI expansion not directly reducing daily correction time.
- Additional automation layers that increase complexity before reliability is proven.

## Suggested Planning Changes to Current `PROJECT_PLANNING.md`

## Keep as P0
- A1, A2, A3
- B1, B2
- C1, C2

## Move to P1 (only if P0 done early)
- E1 (request IDs + `/healthz`) keep minimal implementation.
- F1, F2, F3 test expansion.
- E2 worker replacement flag.

## Move to Post-1.0
- C4 (WiFi transition boundary support)
- D3 (heuristic explainability UI)
- Release-2 intelligence items (ML/integrations)

## Product Clarity Rules (Decision Filter)

Before adding any 1.0 task, ask:

1. Does it directly improve trust (no data loss, correct data)?
2. Does it directly reduce user correction time in daily workflow?
3. Is it required to ship and operate safely?

If answer is "no" to all three, defer.

## 1.0 Success Metrics

- Data integrity: zero known event-loss bugs in controlled stop/restart and transient DB failure scenarios.
- Time-to-clean-day: user can clean and categorize a day in under 5 minutes.
- Mapping coverage: unmapped event share reduced day-over-day after rule adoption.
- Operational stability: install/start/stop/report flow works without manual DB intervention.

## Final Recommendation

Ship a **reliability-first, workflow-simple 1.0**.

Do fewer things:
- capture always,
- keep context (including WiFi),
- make correction fast,
- guarantee data safety.

Then expand intelligence and integrations in release 2 after trust is established.
