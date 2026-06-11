# PHONARA Wave Autonomous Execution Driver

> Status: approved on 2026-06-10 with two operating conditions:
> 1. This driver must be stored in the repository and treated as truth source #5 before execution starts.
> 2. Escalation rules are PART E items 1-8 in full, including schedule slip of 30% or more.

## PART A - Truth Sources

If sources conflict, the higher source wins. Do not redefine these priorities.

1. `.cursor/rules/*.mdc`
2. `docs/PHONARA_V2_MASTER_PLAN.md` body and Build Log
3. Integrated execution contract v1.1: `C:/Users/PC/.cursor/plans/phonara_ultimate_masterplan_52cae995.plan.md`
4. `docs/PHONARA_UI_UX_MASTER.md`
5. This driver: `docs/PHONARA_WAVE_DRIVER.md`
6. `docs/HANDOVER_PHASE4_CASINO.md`

If code and docs disagree, inspect code first, update stale docs immediately, and record the decision in the Build Log. If this driver conflicts with sources 1-4, sources 1-4 win and the conflict itself must be recorded in the Build Log.

Confirmed decisions are not to be reopened: ADR-001 through ADR-007 are fixed. ADR-004 means atomic SQL settlement, no Edge settlement worker. There are exactly six betting RPC guards. Solvency is the Wave 9.1 withdrawal gate, not a betting RPC guard. Per-game kill keys are `feature_game_<code>_enabled`. Wave 0 is closed: case (a) repair completed, remote canonical 24 migrations, local 28 migrations, ADR-007 confirmed real users 0. Non-casino UI polish is Wave 9.5 (9.5a–d), not Wave 9. Wave 10 Lighthouse/axe requires Wave 9.5 green first.

## PART B - Pre-Patches Before Wave 1

Scope lock: docs/plan updates only. Do not change code or SQL. Do not opportunistically fix Slider `border-white` or Sheet `bg-black/60`; those are deferred to Wave 6.

1. Build Log 0.7 reconciliation backfill in `docs/PHONARA_V2_MASTER_PLAN.md`:
   - `0.7 @phonara/ui 5종 - 기록 화해 (코드 승인, 출처 부분 확인)`
   - git `f1f2d55 feat(ui)` confirms Sheet/Slider/Tabs/DataTable/Tooltip.
   - Reconcile the conflict where Zero Tech Debt S2 excluded Sheet/Skeleton, while later `s1-design-foundation` added five components without a superseding Build Log entry.
   - Clarify that `[S1]` commit naming differs from Zero Tech Debt Closeout S1.
   - Verdict: rules 85 and gates approve §5-1; source is commit existence plus missing session/supersession record, reconciled in Wave 0.7.
2. `docs/PHONARA_UI_UX_MASTER.md` §5-1:
   - Replace any unconditional "S1 design system foundation" source claim with the reconciliation tone: commit `f1f2d55`, session record missing, approved by Wave 0.7 reconciliation.
   - Append change history.
3. Naming and Wave 12 confirmation:
   - Replace `feature_<game>_enabled` recommendations with `feature_game_<code>_enabled`, for example `feature_game_crash_enabled`.
   - Rationale: two-layer structure with global `feature_game_enabled` from migration 000019 plus per-game checks; separate namespace.
   - Add Wave 12 gate: `supabase db diff --linked` must prove local db reset schema vs remote diff 0.

Report these only in the first Wave 1 report as: `사전 패치 3건 완료`.

## PART C - Self-Review Protocol

Before closing every Wave, answer these six questions adversarially in the Wave report. If any answer is NO, the Wave cannot close.

1. Contract comparison: list every deliverable from the integrated plan's Wave section and check each one. Do not compress obligations into summary wording.
2. Regression proof: for every new bug-fix test, prove it would fail before the fix. Use RED-before-GREEN TDD or temporary revert to prove RED. Post-fix GREEN alone is not sufficient.
3. Compression loss scan: confirm updated docs/plans did not collapse required guards, scenarios, or checklists into "etc." or summary language.
4. Record integrity: confirm Build Log states what changed, how, errors, root cause, fix, and gate results, without introducing contradictions.
5. Doc-code sync: confirm no document now lies about the code, including UI_UX_MASTER §5, plan snapshots, and handover checklists.
6. Namespace collision: grep new app_config keys, cron jobs, RPCs, i18n keys, and component names against existing names: `feature_*`, `phonara_*`, `rpc_*`, `_assert_*`.

Always apply these principles:
- Every numeric constant in money/fairness code needs a source comment.
- E2E absolute-value assertions are forbidden; use deltas and conservation.
- After the same gate fails three consecutive times, stop and escalate under PART E.
- PowerShell command chains use `;`, not `&&`.

## PART D - Wave Execution Cards

Each Wave begins by rereading this driver, the integrated plan section, and relevant rules. Then execute, run the PART 7 gate chain from the integrated plan, perform PART C self-review, append Build Log, report using PART F, and automatically enter the next Wave unless PART E applies.

### Wave 1 - Engine Zero-Defect

Deliverables:
- Plinko verified 1% edge table, string multipliers, source comments.
- Mines distinct reveals plus max reveals zod validation.
- HiLo guesses capped at 10.
- Crash manual cashout model.
- `packages/game-engine/src/lib/quantize.ts` using Decimal ROUND_DOWN 6dp.
- Verifier `recomputeResult` with `GameCode` as single source.
- Six game tests importing exports directly.
- Float cursor regeneration using `${clientSeed}:${nonce}:${cursor}`. Exhaustion throw is only a guard, not the solution.
- Deterministic fixed-seed 100k Monte Carlo.
- Browser-node parity.

Core verification:
- Plinko 12-low RTP below 100%, with high-variance configuration band rationale comments such as 16-high.
- Cursor boundary fixed vector: the ninth float request crosses to cursor 1 deterministically; Plinko 16 rows must hit this boundary.
- Exploit regressions for Mines distinct and HiLo cap prove RED-to-GREEN under PART C-2.

Exit: tests green, the three core verifications above, and PART C.

### Wave 2 - Migration 000029 Settlement

Deliverables:
- System accounts `game_house_phon` and `game_house_usdt`; insurance remains separate under ADR-005.
- `UNIQUE(user_id, idempotency_key)` on `game_bets`.
- `rpc_place_game_bet` with ADR-004 atomic place plus settle and exactly six guards:
  1. `_assert_amount_text`
  2. `_fmt6`
  3. token-bucket rate limit
  4. min/max stake
  5. consent plus feature guard: global `_assert_feature_enabled('game')`, then per-game `feature_game_<code>_enabled`
  6. `_assert_game_exposure_cap`: max payout cap, Limbo max target, per-game and total house exposure, reject with `house_exposure_cap`
- Server seed protection: column REVOKE and RLS; `v_game_rounds_public` with `security_invoker=true`; drop `game_rounds FOR SELECT TRUE`; revoke direct table SELECT.
- Settlement conservation with four legs: unlock, credit, house, dust.
- ADR-001 parity mismatch handling: game kill ON, `parity_mismatch` audit, bet `parity_hold`, no automatic refund.
- Stale pending sweep via pg_cron, `app_config.casino_stale_pending_minutes` default 10, excluding `parity_hold`.
- `rpc_reveal_game_round`, `rpc_cancel_game_bet` pending only, `rpc_admin_void_game_bet` with reason and audit.
- Admin RLS SELECT only.
- `first_game` mission hook.

Exit: local `supabase db reset` clean, advisor 0 ERROR, 000029 TODO 0, exposure cap negative case, PART C. On completion, create `docs/ADR/0002-casino-settlement.md` elevating ADR-001 through ADR-007.

### Wave 3 - Parity And SQL Integration

Deliverables:
- `casino-parity.test.ts`.
- `casino_parity_test.sql`: six games times two paths, byte constants following futures parity pattern.
- Strengthen `casino_schema_test`: win/loss Σ=0, house leg, multi-bet, cancel, hash tamper, concurrent two-bet `FOR UPDATE`, idempotency scope, cap rejection, parity kill trigger, stale sweep.
- `casino_security_test`: admin void audit, authenticated settle rejected, payout tamper rejected, server_seed SELECT unavailable negative test.
- Expand futures parity short/loss/wipeout.

Exit: `bun run test:sql` green and PART C, especially proving tamper tests fail without defense.

### Wave 4 - Live Surface Hardening 000030

Precondition: re-check ADR-007 through `auth.users` count. If 0, Wave 12 batch remains allowed. If 1 or more, immediately escalate and propose Wave 4 remote hotfix mode.

Deliverables:
- Roulette HMAC provably fair path: remove `random()`, do not return seed, reveal separately.
- Referral exact match and minimum length 8.
- Reserve RPC admin wrapping.
- Staking deterministic idempotency key.
- Admin i18n and theme drift cleanup.
- `consent_gate` true plus E2E.
- SQL negative proof that referral prefix mint is impossible.

Exit: grep confirms roulette `random()` 0, negative proof, PART C.

### Wave 5 - Types And Integration

No Edge worker. Creating one violates ADR-004.

Deliverables:
- Regenerate shared types after 000029 and 000030.
- Full local stack place to settle to reveal path.
- server_seed SELECT negative test.
- Browser code scan confirms service_role 0.

Exit: typecheck, integration green, PART C.

### Wave 6 - Casino UI And Provably Fair

Precondition: recover deferred token fixes: Slider `border-white` and Sheet `bg-black/60` to `@theme` tokens; update UI_UX_MASTER change history.

Deliverables:
- Build `@phonara/ui` components in this order after preflight: Toast, Skeleton, BetPanel, FairnessVerifier, GameStakeInput, MultiplierDisplay, ProvablyFairBadge, EmptyState/ErrorState, StatusTimeline.
- Routes: `casino/index`, `crash`, `limbo`, `dice`, `mines`, `hilo`, `plinko`, `fairness` with one shell and swappable canvas. If adding a game requires changing shell/verifier, treat as a defect.
- Public provably fair docs page with i18n and HMAC diagram.
- Daily loss limit warning.
- PHON plus USDT toggle.
- Double-click dedupe using futures pattern.
- Four states across all screens.
- `visual.spec` registration.
- Screenshot self-critique for every route using UI_UX_MASTER §9 six criteria.

Exit: build, `check:i18n`, six criteria PASS, styles.css line-count reduction recorded, PART C.

### Wave 7 - E2E And Statistics

`casino.spec.ts` must cover every game, with all seven items listed for each of six games:

1. Seed hash visible before bet.
2. Bet to settle to Σ=0 DB conservation.
3. Reveal to `verifyRound` recompute matches stored outcome.
4. Tampered seed rejected.
5. Duplicate and cross-user idempotency rejected.
6. Unauthorized settle rejected.
7. Teardown leaves residue 0.

Additional requirements: cap rejection, ConfirmDialog cancellation path, daily/roulette browser E2E.

Exit: `casino.spec` green, grep confirms absolute assertions 0, PART C.

### Wave 8 - S2 Security

Deliverables:
- Admin MFA enforcement.
- HIBP leaked password through Dashboard setting and RUNBOOK documentation.
- Remaining mission triggers.

Exit: security E2E positive/negative and PART C.

### Wave 9.0 - Phase 5 Design (KYC, Screening, Solvency)

No product code until this Wave closes. Write the design doc first.

Deliverables:
- KYC tiers, source of funds, sanctions screening policy (3 touchpoints — see `docs/WAVE_9_0_PHASE5_DESIGN.md` v2), STR v1 rules, admin case queue IA.
- **KRW deposit reconciliation design:** auto-match rules (reference, amount, depositor name) vs exception queue; `deposit_reconciliation_jobs` flow — no PG, 1-person ops.
- Screening v2: confirmed sanctions hit → **account activity freeze** (not withdrawal-only); deposit screening uses **rolling cumulative + frequency**, not single-amount threshold alone (anti-structuring).
- ADR-005 solvency gate design: reuse `treasury_reserves` + `rpc_run_reconciliation`; `_assert_solvency_withdrawal_gate` wrapper; **attested_balance change audit + large-delta alert/dual confirm** in 9.1.
- `PHON_real` withdrawal only behind KYC plus screening plus solvency gates.
- Schema draft: `withdrawal_requests`, `deposit_reconciliation_jobs`, `admin_review_queue`, `risk_flags`, `kyc_submissions`, `sanctions_screenings`, `str_cases`, bank transfer staging.

Exit: `docs/WAVE_9_0_PHASE5_DESIGN.md` v2 operator sign-off, Build Log, PART C. No migration or withdrawal GRANT.

### Wave 9.1 - Phase 5 Deposits, Withdrawals, AML/KYC Implementation

Precondition: Wave 9.0 design closed.

Deliverables:
- Implement Wave 9.0 schema and RPCs: deposit/withdrawal with Σ=0, idempotency, audit, kill switch.
- `_assert_kyc_withdrawal_gate`, `_assert_sanctions_screening`, `_assert_solvency_withdrawal_gate` — **RED neg tests first**, then implement, then GREEN; GRANT last.
- **Attested balance controls:** extend `rpc_update_treasury_reserve` audit + large-delta alert/dual confirm per design §4.2.
- **KRW deposit reconciliation:** auto-match (reference, amount, depositor) vs admin exception queue per design §5.
- STR rules to exception queue.
- **Deposit/withdrawal UI built with §6-6 in the same Wave** (QR, copy feedback, KYC lock overlay, StatusTimeline, rate snapshot display) — not a follow-up polish pass.
- Admin exception queue UI using UI_UX_MASTER §6-7.
- ADR-005 solvency gate proven in SQL/E2E before withdrawal RPC GRANT (PART G).
- E2E: KYC positive/negative, screening hit account freeze, conservation. **Report must include RED capture for each of the three withdrawal gates.**

Exit: full Phase 5 checklist, solvency proof, money/security E2E, PART C.

### Wave 9.5 - Non-Casino UI Polish (blocks Wave 10 metrics)

Precondition: Wave 9.1 closed. This Wave is a **contract slot** — do not compress into Wave 9 or Wave 10. Casino UI was Wave 6; non-casino routes remain MVP wiring until this Wave.

Purpose: bring login, dashboard, trading, ledger, and retention surfaces to UI_UX_MASTER §6 without blocking Wave 9 money work.

#### Wave 9.5a - Login and Dashboard (§6-1, §6-2)

Deliverables:
- Login/signup flow vs §6-1 (consent gate, post-signup welcome path, inline errors).
- Dashboard vs §6-2 (total assets, PHON real/free split, next-action CTAs, previews).
- Migrate ad-hoc `auth-*` / `dash-*` / wallet card layout toward `@phonara/ui` + tokens; record `styles.css` line count.

#### Wave 9.5b - Trading Layout and Chart (§6-4)

Deliverables:
- Standard trading layout: chart region + order panel + positions table (TradingView Lightweight Charts).
- Liquidation price on chart, leverage slider with live margin/liq recompute, mobile Sheet order panel.
- B-book oracle disclosure in market info area.

#### Wave 9.5c - Ledger DataTable (§6-6 ledger slice)

Deliverables:
- Replace ad-hoc `ledger-table` with `@phonara/ui` DataTable (or approved composite).
- Loading/empty/error via `@phonara/ui` primitives (`Skeleton`, `EmptyState`, `ErrorState`).
- CTA to wallet/deposit flows when Wave 9.1 routes exist.

#### Wave 9.5d - Retention and Missions (§6-3)

Deliverables:
- Top-of-section total claimable PHON, referral dashboard (code, invite status, Web Share).
- Migrate `streak-bar`, `mission-list`, roulette/daily ad-hoc classes toward ui + tokens.
- FOMO copy enabled. During launch, numeric/result-style values are allowed as operator-configured campaign values; do not present them as live measured data until connected.

**Wave 9.5 exit (all sub-waves 9.5a–d):**
- Each sub-wave: relevant **§6 page spec** checklist item-by-item (no "etc." compression).
- **UI_UX_MASTER §9 six criteria** self-critique per touched route.
- **Screenshot self-review** registered in visual spec or Wave report (mobile + desktop safe width).
- `styles.css` line count recorded in Build Log (monotonic decrease vs Wave 9.5 entry baseline).
- `check:i18n`, `check:release`, typecheck, lint green; relevant E2E smoke updated.
- PART C.

Wave 10 Lighthouse/axe/Lighthouse 95+ **must not start** until Wave 9.5 exit is green (measuring unpolished surfaces is invalid).

### Wave 10 - Quality Closeout And Phase 6 Prep

Precondition: Wave 9.5 exit green.

Deliverables:
- Local full gate chain: `bun run check`, `bun run build`, `bun run check:pwa`,
  `supabase db reset`, `bun run test:sql`, and `bun run test:e2e`.
- CI advisor policy documentation: remote/local advisor gate is 0 ERROR; WARNs
  must be reviewed and either fixed or explicitly justified.
- E2E stabilization for flaky critical suites. Fix root causes such as stale Vite
  ports, stale built package dist, or browser/local-network hangs. Do not weaken
  DB conservation, hash-chain, authorization, or provably-fair assertions.
- RUNBOOK six scenarios: house exposure, RTP drift, mass cancel, settle parity
  mismatch, solvency violation, and remote config drift.
- Dependency-gated Phase 6 items are NOT automatic in this session: Playwright
  plus axe for WCAG AA, Lighthouse 95+, PWA polish that needs new packages,
  charts/realtime library work, Sentry, and PostHog all enter PART E item 6
  if a new dependency is required.

Exit: local gates green, E2E stabilization green, RUNBOOK/policy documentation
updated, dependency-gated items explicitly deferred or approved under PART E,
and PART C.

### Wave 11 - Phase 4.5 Post-Launch Non-Blocking

Deliverables:
- Mines session RPC.
- Live Crash WebSocket.
- ADR-004 Edge seed reconsideration.

Wave 11 must not block Wave 12.

### Wave 12 Prep - Remote Launch Readiness (No Apply)

This wave is verification only. It must not apply remote migrations, run remote
DDL, or change remote data.

Deliverables:
- All local gates green: `bun run check`, `bun run build`, `bun run check:pwa`,
  `supabase db reset`, `bun run test:sql`, `bun run test:e2e`, and advisor 0 ERROR.
- Re-check ADR-007 with a live read-only `auth.users` count. If the count is 1
  or more, immediately §STOP.
- Compare remote `list_migrations` with local migration files. Expected current
  state is remote through `000024` and local pending `000025` through `000037`.
- Classify `supabase db diff --linked` into exactly one of:
  1. clean(diff 0);
  2. expected diff only from the 13 pending migrations `000025` through `000037`;
  3. unexplained diff. Case 3 is §STOP and must not be auto-labeled explained.
- Confirm remote advisor 0 ERROR.
- Confirm no Edge casino worker exists.
- Dry-verify the batch order: remote apply would include `000025` through latest
  as one ordered batch; never apply `000028` placeholder alone because `000029`
  corrects it.
- Wave 12 applies the 13 pending migration files `000025` through `000037` in
  order. It does NOT apply raw `supabase db diff --linked` output. Environment
  baseline noise such as local-only `pg_net` must not be included in the push.
- Batch order must preserve the withdrawal seal: `000033` creates Phase 5
  withdrawal RPCs, `000034` seals withdrawals, and `000035` replaces request with
  the lock lifecycle and sets `feature_withdrawal_enabled=false`.
- Withdrawal flag dry check: local `000035` must set
  `feature_withdrawal_enabled=false` after `000033` creates withdrawal RPCs.
  Because this prep wave does not push, the live post-push flag value is NOT
  verified here. The operator-facing Wave 12 apply session must directly query
  remote `app_config` after push and confirm `feature_withdrawal_enabled == false`;
  otherwise §STOP.
- Build Log and checklist updated with exact results.

Exit: all prep checks above, PART C, and STOP with "Wave 12 remote push awaits
operator-facing approval." No remote apply is part of this exit.

### Wave 12 Apply - Remote Money-System Launch (Operator-Facing Only)

Deliverables:
- Starts only after Wave 12 Prep is green and the operator gives explicit
  face-to-face approval for remote launch.
- Remote apply `000025` through latest as a single ordered batch.
- Immediately re-run live gates, including remote `feature_withdrawal_enabled`
  real value == `false`, advisor 0 ERROR, `auth.users` safety, and diff status.

Exit: all remote launch gates green, PART C, Build Log, RUNBOOK, and final
operator launch approval. This wave is never entered automatically.

## PART E - Escalation Conditions

Stop and ask the operator only for these eight conditions:

1. Schema drift case (b): unknown remote DDL with no local counterpart.
2. ADR change needed for ADR-001 through ADR-007.
3. Money meaning conflict where plan and code disagree on Σ=0, solvency, or idempotency and code-first inspection cannot resolve it.
4. ADR-007 trigger: `auth.users` count is 1 or more.
5. Any desire for remote changes before Wave 12.
6. New dependency required.
7. Same gate fails three consecutive times.
8. Expected schedule slip of 30% or more.

Do not ask about names, file choices, i18n key names, component internal structure, guard order, token naming, E2E scenario composition, commit timing, or Wave-to-Wave entry when exit gates and PART C pass.

## PART F - Operator Report Card

Use this exact shape after every Wave:

```text
■ Wave N 종료 — <한 줄 요약>
산출: <계약 대조 체크리스트 — 전수, 각 [x]>
게이트: typecheck/lint/i18n/release/test/sql/advisor/e2e <green/상세>
자가 검수(§C 6문): <각 1줄 답 — 특히 C-2 회귀 증명 방법 명시>
오류→수정: <근본원인 포함, 없으면 "없음">
문서 갱신: <Build Log/플랜/UI_UX_MASTER 등 — 파일명>
일정: <예정 대비>
다음: Wave N+1 <첫 작업 1줄>
결정 필요: <§E 해당 시만 — 보통 "없음">
```

## PART G - Absolute Prohibitions

No unapproved remote changes before Wave 12, no Edge casino settlement worker, no omitted guard from the six, no absolute-value E2E assertions, no bug-fix tests without regression proof, no compressed summaries replacing required lists, no missing or sanitized Build Log, no client RNG, no float money, no hardcoded hex, no Korean JSX, no ConfirmDialog bypass, no server_seed exposure before reveal, no unilateral ADR changes, and no withdrawal GRANT without the solvency gate.
