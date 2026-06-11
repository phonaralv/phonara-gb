# Wave 9.0 — Phase 5 Design (KYC, Screening, Solvency, KRW Reconciliation)

> Status: **v2 approved — Wave 9.1 implemented 2026-06-10**
> Scope: design only. **No migrations, no withdrawal GRANT, no product code.**
> Next: Wave 9.1 implementation with **RED-first TDD** on all money gates.

---

## 1. KYC tiers (reuse existing ENUM)

Existing: `profiles.kyc_tier` — `anonymous` | `email_verified` | `phone_verified` | `id_verified`.

| Tier | Gate |
|------|------|
| `anonymous` | Read-only wallet; no deposit credit, no withdrawal |
| `email_verified` | Magic Link complete — games, rewards, internal PHON (non-withdrawable free tier until policy split) |
| `phone_verified` | Optional — KRW deposit SMS/alerts (Phase 5.1 if needed) |
| `id_verified` | **Minimum tier for PHON_real withdrawal** — hooks `kyc_verified` mission (000032) |

**`_assert_kyc_withdrawal_gate`:** reject below `id_verified` with stable code `kyc_insufficient` → i18n. UI: §6-6 lock overlay + “Complete KYC” CTA (form never hidden).

---

## 2. Sanctions screening — three touchpoints (v2)

### 2.1 Onboarding (async screen)

- After consent gate, run sanctions check against admin-maintained denylist + `sanctions_screenings` row.
- **UX:** signup completes (email verified path) — do not block form submit on slow external-less check.
- **On confirmed hit (not “pending”):**
  - Set `risk_flags` type `sanctions_hit` + **`account_activity_frozen`** (not withdrawal-only).
  - Block: game, trade, stake, deposit credit, internal transfers, withdrawal.
  - Allow: sign-out, support/read-only status page, admin appeal queue.
  - Rationale: providing platform services to a sanctioned party is a compliance violation even if funds cannot exit.

**Pending/async window:** if check not yet resolved, user may browse with **`sanctions_pending`** flag — no withdrawal, no deposit credit until cleared.

### 2.2 Deposit (KRW credited path)

Screen on **`krw_deposit_requests` → `credited`** (near existing `first_deposit` trigger).

**v2 — not single-amount threshold only:**

| Signal | Rule (config keys) |
|--------|---------------------|
| Single deposit | `screening_deposit_single_krw_threshold` — screen if ≥ |
| **Rolling cumulative** | `screening_deposit_rolling_krw_threshold` over `screening_deposit_rolling_days` (default 7) — catches **structuring** below single-shot threshold |
| **Frequency** | `screening_deposit_count_threshold` in rolling window — e.g. ≥ N deposits in 7 days |

On hit: deposit **`freeze`** (no PHON credit reversal if already credited — escalate to admin queue + optional readonly), `risk_flags`, STR case if in scope.

### 2.3 Withdrawal (final gate)

Inside `rpc_request_withdrawal` before any ledger move:

1. `_assert_kyc_withdrawal_gate`
2. `_assert_sanctions_screening` — **fresh** screening TTL `screening_withdrawal_max_age_hours` (default 24)
3. `_assert_solvency_withdrawal_gate` (§4)

All three must pass. No GRANT on withdrawal RPC until each has RED-first neg test green in Wave 9.1.

---

## 3. STR v1 scope (approved — unchanged)

**In scope v1:**

- Withdrawal ≥ `str_withdrawal_krw_threshold`
- Sanctions hit (any)
- Reconciliation mismatch (`rpc_run_reconciliation` → readonly, 000026) — link to STR auto-open
- Manual admin flag
- **Structuring signal** from §2.2 rolling deposit rules

**Out of scope v1 (Wave 10+):** ML anomaly, velocity-only STR without rule, SAR auto-file to regulator.

**`str_cases`:** `open | reviewing | filed | dismissed`. Every manual disposition: reason + `audit_logs`.

---

## 4. Solvency gate — reuse 000026 (approved + input hardening)

**Do not build a new solvency engine.** Reuse:

- `treasury_reserves` (admin-attested custodied balance per currency)
- `rpc_run_reconciliation()` + daily pg_cron
- `reconciliation_log`, mismatch → `system_readonly`

### 4.1 `_assert_solvency_withdrawal_gate` (new wrapper in 9.1)

All must be true:

```
Σ(user withdrawable per currency) ≤ attested_balance × (1 − buffer_pct)
AND last reconciliation success within 24h
AND is_match = true
AND NOT system_readonly
AND NOT feature_withdrawal_kill (explicit kill switch)
```

Fail → `withdrawal_solvency_hold` (stable code → i18n).

### 4.2 Attested balance — weak link mitigation (9.1 mandatory)

`attested_balance` is admin-entered. Without input controls the gate is meaningless.

**Wave 9.1 requirements:**

| Control | Behavior |
|---------|----------|
| **Audit** | Every `treasury_reserves` balance change → `audit_logs` (extend 000030 `rpc_update_treasury_reserve` pattern) |
| **Large delta alert** | If `|new − old| / old > attested_change_alert_pct` (default 10%) → require **second admin confirm** or block until operator acknowledges in Admin UI (configurable) |
| **Downward-only fast path** | Optional: decreases allowed single-step; increases above threshold need dual control |
| **Readonly side effect** | Reconciliation mismatch already sets readonly — withdrawal gate must read live flag |

---

## 5. KRW deposit reconciliation (v2 — was missing)

Platform model: **no PG** — users transfer KRW to disclosed bank account with **unique `reference_code`** per request (`krw_deposit_requests` exists in 000001).

### 5.1 Actors

- **User:** creates deposit request (amount, gets reference code + bank instructions).
- **Bank feed (v1):** manual CSV import or Admin “record incoming transfer” — full Open Banking is out of v1.
- **Matcher job:** `deposit_reconciliation_jobs` + `rpc_run_deposit_reconciliation()` (service_role / cron).
- **Admin:** exception queue only.

### 5.2 Status machine (extends `deposit_status`)

```
pending → matched → credited
         ↘ unmatched → expired | admin_rejected
         ↘ disputed → admin_resolved
```

- **`matched`:** incoming row matches one pending request (rules below).
- **`credited`:** atomic PHON credit + rate snapshot + ledger Σ=0 (Wave 9.1 RPC).

### 5.3 Auto-match rules (normal path — no human)

All required for auto-match:

| # | Rule |
|---|------|
| 1 | **Reference code** exact match on transfer memo/description |
| 2 | **Amount** exact match `amount_krw` (no partial v1 — partial → exception) |
| 3 | **Depositor name** fuzzy match score ≥ threshold against `profiles` legal name / KYC name when present (configurable strictness) |
| 4 | Request `status = pending` and not `expired` |
| 5 | No existing `risk_flags` blocking deposit credit |
| 6 | Sanctions screen §2.2 pass (including rolling cumulative) |

On success: job writes `matched_at`, then calls credit RPC idempotently.

### 5.4 Exception queue (admin — 1-person ops)

Route to `admin_review_queue` when **any**:

- Amount mismatch (over/under)
- Reference code missing or ambiguous (multiple pending)
- Depositor name mismatch
- Duplicate transfer id
- Rolling deposit structuring signal
- Sanctions pending/hit
- Auto-match confidence below threshold

Admin actions (all audited): approve match, reject, refund instruction note, link to different user (high risk — dual confirm).

### 5.5 `deposit_reconciliation_jobs` schema (draft)

- `id`, `source` (`csv_import` | `manual_entry`), `payload`, `status`, `matched_count`, `exception_count`, `run_at`, `operator_id` nullable
- Incoming transfer staging table or JSONB rows in job payload for v1 simplicity

### 5.6 User-facing §6-6 (Wave 9.1 — same Wave as RPC)

- Deposit instructions: QR/bank copy, **“this network/account only”** amber box
- StatusTimeline: `pending → matched → confirming → credited` (not single word “processing”)
- Expected PHON + rate snapshot + fee repeated in form, status, notification copy

---

## 6. Wave 9.1 schema draft (implementation reference)

- `withdrawal_requests`, `kyc_submissions`, `sanctions_screenings`, `str_cases`, `risk_flags`, `admin_review_queue`, `deposit_reconciliation_jobs`, `bank_incoming_transfers` (or equivalent staging)
- Extend `profiles` / `risk_flags` for **`account_activity_frozen`**

---

## 7. Wave 9.1 exit — RED-first order (mandatory)

**No `rpc_request_withdrawal` GRANT until all green.**

| Step | Action |
|------|--------|
| 1 | Write SQL neg tests (RED) for `_assert_kyc_withdrawal_gate`, `_assert_sanctions_screening`, `_assert_solvency_withdrawal_gate` |
| 2 | Implement guards (GREEN) |
| 3 | Write deposit reconciliation + withdrawal RPC neg tests (RED) |
| 4 | Implement RPCs (GREEN) |
| 5 | GRANT withdrawal/deposit RPCs to `authenticated` |
| 6 | §6-6 UI in same Wave (KYC overlay, StatusTimeline, copy feedback) |
| 7 | E2E: KYC +/-, screening hit freeze, solvency block, KRW auto-match vs exception, Σ=0 |

**9.1 report must include:** RED capture for each of the three withdrawal gates (not post-fix green only).

Solvency gate = direct money path → **RED-first required**, not revert-after-fix.

---

## 8. Wave 9.0 exit checklist

- [x] v2 operator review items: screening freeze scope, deposit rolling rules, KRW reconciliation, attested input controls
- [ ] Operator sign-off on v2
- [ ] Build Log entry
- [ ] PART C (design wave — code 0)
- [ ] Proceed to Wave 9.1

---

## 9. Explicitly deferred

- Wave 9.5 — non-casino UI polish (login, dashboard, trade chart, ledger DataTable, retention)
- Coin on-chain deposits
- Open Banking auto-feed
- SAR electronic filing
