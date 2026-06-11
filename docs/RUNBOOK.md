# PHONARA 운영 Runbook (B3) — 새벽 3시 인시던트 대응

> **1인 운영 생명줄.** 이 문서는 야간 알람이 울릴 때 혼자서 빠르게 판단하고
> 조치하기 위한 체크리스트다. 자동화가 이미 대부분을 처리하지만, 자동화가
> 트리거한 상태를 확인·복구하는 건 사람의 몫이다.
>
> **단일 진실 공급원**: `docs/PHONARA_V2_MASTER_PLAN.md`
> **빠른 접속**: Supabase Dashboard → SQL Editor

---

## Admin Overview 빠른 판정

Admin Overview는 `rpc_get_ops_health()`가 저장된 최신 운영 신호만 읽어 5개 카드로 표시한다.
빨간 항목은 아래 Runbook 시나리오로 바로 연결해 확인한다. 이 화면은 즉석 재조정이나
hash-chain 검사를 실행하지 않으며, 최신 로그를 보고 새벽 대응 우선순위를 정하는 용도다.

| Admin 카드 | 빨간 항목 / runbookKey | 확인할 시나리오 |
|------------|------------------------|-----------------|
| 시스템 모드 | `system_mode_active` | Scenario 1, Scenario 2, Scenario 5 |
| 재조정 | `reconciliation_mismatch` | Scenario 1 |
| 크론/청산 | `cron_liquidation_stale`, `liquidation_recent_error` | Scenario 4 |
| 리저브 최신성 | `treasury_stale` | Scenario 3 |
| 최근 운영자 조치 | `operator_actions_review` | 감사 로그에서 변경 사유와 대상 확인 |

---

## 🔴 Scenario 1: Reconciliation 불일치 → 자동 system_readonly

**발동 조건**: `rpc_run_reconciliation()` (매일 02:00 UTC, pg_cron)이 아래 **5종 검사** 중
하나라도 실패 → `app_config.system_readonly = true` 자동 설정.

| check_type | 무엇을 검사하는가 |
|------------|-------------------|
| `wallet` | 통화별 Σ(user wallet balances) == wallet_ledger net |
| `system` | 통화별 Σ(system_accounts.balance) == system_account_ledger net |
| `global_zero` | 통화별 Σ(wallets + system) == 0 |
| `hash_chain_wallet` | `verify_ledger_hash_chain()` broken count == 0 |
| `hash_chain_system` | `verify_system_account_hash_chain()` broken count == 0 |

**증상**: 유저가 "잠시 서비스 점검 중" 오류를 봄. 지갑 잔액 변경 RPC 전체 차단.
(청산 RPC는 `system_readonly`와 무관하게 계속 동작.)

**확인 쿼리**:
```sql
-- 1. 최신 reconciliation 결과 (5 check types)
SELECT run_at, check_type, currency, wallet_sum, ledger_net, delta,
       broken_count, is_match, triggered_halt
  FROM reconciliation_log
 ORDER BY run_at DESC, check_type
 LIMIT 20;

-- 2. 현재 시스템 상태 확인
SELECT key, value FROM app_config WHERE key IN ('system_halt', 'system_readonly');

-- 3. 이번 run에서 실패한 검사만
SELECT check_type, currency, wallet_sum, ledger_net, delta, broken_count
  FROM reconciliation_log
 WHERE is_match = FALSE
 ORDER BY run_at DESC
 LIMIT 10;

-- 4. hash-chain 실패 여부 (sum은 맞지만 tamper 가능)
SELECT check_type, broken_count, triggered_halt
  FROM reconciliation_log
 WHERE check_type IN ('hash_chain_wallet', 'hash_chain_system')
   AND is_match = FALSE
 ORDER BY run_at DESC
 LIMIT 5;
```

**원인 가능성**:
- 직접 DB 조작(침해 또는 DB 버그) → `delta` 양수면 wallet이 더 많음(=돈 추가됨)
- Decimal 계산 누적 오차(극히 드뭄) → `delta`가 0.000001 미만
- 마이그레이션 중 atomic 실패

**대응 절차**:
1. 심각도 판단: `delta > 1.0` → 즉시 `system_halt` 고려. `delta < 0.000001` → 부동소수 오차, 즉시 해제 가능.
2. 침해 의심 시: `system_halt = true` 설정 후 포렌식.
3. 오차 범위 내 확인 시: 수동 원인 확인 후 `system_readonly = false` 해제.
4. 해시체인 검증: `SELECT * FROM verify_ledger_hash_chain();` → 0건이어야 정상.

**복구**:
```sql
-- readonly 해제 (원인 확인 후에만)
SELECT rpc_set_system_mode(false, false, '재조정 완료 확인 후 서비스 재개');
```

---

## 🔴 Scenario 2: 해시체인 손상 → 전 RPC 중단

**발동 조건**: `verify_ledger_hash_chain()` 가 비어있지 않은 결과 반환.
(A4 hardening_test가 이미 이 함수의 정확성을 검증함)

**증상**: 지갑 원장 tamper 가능성. 직접 발동되진 않지만 정기 모니터링에서 감지.

**확인 쿼리**:
```sql
SELECT broken_user_id, entry_id, entry_seq, expected, actual
  FROM verify_ledger_hash_chain()
 LIMIT 20;
```

**대응 절차**:
1. 즉시 `system_halt = true` 설정.
2. 손상된 `entry_id`와 `broken_user_id` 기록.
3. `wallet_ledger` 해당 행의 `idempotency_key`, `reason_code`, `created_at` 확인.
4. 동시간대 audit_log, DB 접속 기록 대조.
5. 포렌식 완료 전까지 서비스 중단 유지.

**halt 설정**:
```sql
SELECT rpc_set_system_mode(true, false, '해시체인 손상 감지 - 포렌식 진행 중');
```

---

## 🟠 Scenario 3: 리저브 비율 위험 수준

**발동 조건**: 수동 모니터링 또는 Admin 대시보드 알람.
`treasury_reserves.real_balance < Σ(user wallets) × (1 + buffer_pct/100)`

**확인 쿼리**:
```sql
-- 리저브 현황
SELECT r.currency,
       r.real_balance,
       r.buffer_pct,
       CASE r.currency
         WHEN 'PHON' THEN (SELECT SUM(phon_available::NUMERIC + phon_locked::NUMERIC) FROM wallets)::TEXT
         WHEN 'USDT' THEN (SELECT SUM(usdt_available::NUMERIC + usdt_locked::NUMERIC) FROM wallets)::TEXT
         ELSE '0'
       END AS user_total
  FROM treasury_reserves r;
```

**대응 절차**:
1. 출금 요청 검토 → 큰 이상 없으면 리저브 업데이트(온체인 자산 이동 후).
2. 대규모 이상 출금 패턴 → AML 검토.
3. 리저브 업데이트(admin RPC):
```sql
SELECT rpc_update_treasury_reserve('USDT', '50000.000000', 10, 5, '자산 재확인 후 업데이트');
```

---

## 🟡 Scenario 4: 자동청산 실패 / pg_cron 미실행

**확인 쿼리**:
```sql
-- pg_cron 마지막 실행 시각
SELECT jobname, schedule, active FROM cron.job WHERE jobname = 'phonara_auto_liquidations';
SELECT * FROM cron.job_run_details WHERE jobname = 'phonara_auto_liquidations'
  ORDER BY start_time DESC LIMIT 5;

-- 마지막 청산 이벤트
SELECT * FROM liquidation_run_log ORDER BY ran_at DESC LIMIT 5;

-- 청산 가능한 포지션 (수동 확인)
SELECT id, user_id, market, side, liquidation_price FROM futures_positions
 WHERE status = 'open';
```

**수동 청산 실행** (긴급 시):
```sql
PERFORM set_config('request.jwt.claims', '{}', true);
SELECT rpc_run_liquidations();
```

---

## 🟢 Scenario 5: 서비스 정상화 절차

모든 인시던트 해소 후 서비스 재개 전 체크리스트:

- [ ] `verify_ledger_hash_chain()` = 0행
- [ ] `reconciliation_log` 최신 = `is_match = true`
- [ ] `treasury_reserves` 리저브 비율 정상
- [ ] `app_config`: `system_halt = false`, `system_readonly = false`
- [ ] `cron.job_run_details` pg_cron 정상 실행 중
- [ ] 이번 인시던트 원인·대응 내용을 `docs/PHONARA_V2_MASTER_PLAN.md` Build Log에 기록

**서비스 재개**:
```sql
SELECT rpc_set_system_mode(false, false, '인시던트 해소 확인 - 서비스 정상화');
```

---

## B1 동의 시스템 상태 확인

```sql
-- 동의 게이트 활성 여부
SELECT key, value FROM app_config WHERE key = 'consent_gate_enabled';

-- 특정 유저의 동의 현황
SELECT user_id, doc_type, doc_version, accepted, accepted_at
  FROM user_consents WHERE user_id = '<uuid>';

-- 미동의 유저 현황 (게이트가 켜진 경우 이들은 거래 불가)
SELECT u.id, u.email
  FROM auth.users u
 WHERE NOT EXISTS (
   SELECT 1 FROM user_consents uc
   WHERE uc.user_id = u.id AND uc.accepted = TRUE
     AND uc.doc_type IN ('terms_of_service', 'privacy_policy', 'risk_disclosure')
 );
```

---

## Admin MFA + HIBP 설정 확인

프로덕션 Admin 콘솔은 앱 레벨에서 AAL2(MFA 완료 세션)를 요구한다. Supabase Dashboard 설정이 꺼져 있거나 관리자 계정에 factor가 없으면 운영자가 콘솔에 접근할 수 없다.

**Dashboard 확인 경로**:
1. Supabase Dashboard → Authentication → MFA → TOTP 활성화.
2. 관리자 계정에 MFA factor 등록.
3. Supabase Dashboard → Authentication → Password Policies → "Check for compromised passwords (HIBP)" 활성화.

**장애 대응**:
- Admin 로그인 후 `admin-mfa-required` 화면이 보이면 MFA challenge가 완료되지 않은 세션이다. 로그아웃 후 MFA 등록/인증을 완료한다.
- HIBP 설정 후 약한/유출 비밀번호로 가입 또는 비밀번호 변경이 거부되는지 Dashboard Auth logs에서 확인한다.
- MFA factor 분실 시 Supabase Dashboard에서 해당 admin 계정 factor를 재등록하고, 조치 이유를 Build Log에 남긴다.

---

## Wave 10 Critical Scenarios

### 1. House exposure spike

**Trigger**: casino/system account exposure rises above the configured operator
limit or `insurance_fund_phon` becomes materially negative.

**Auto-response**:
- Game settlement RPCs continue to conserve Σ=0.
- Admin must pause the affected game family with the existing feature flag or
  system mode RPC if exposure cannot be explained.

**Recovery checklist**:
- [ ] Check system accounts:
```sql
SELECT code, currency, balance FROM system_accounts ORDER BY currency, code;
```
- [ ] Check recent casino settlement legs and largest payouts:
```sql
SELECT user_id, game, stake_amount, payout_amount, settled_at
  FROM casino_bets
 ORDER BY settled_at DESC
 LIMIT 50;
```
- [ ] Verify ledger conservation:
```sql
SELECT * FROM verify_ledger_hash_chain();
```
- [ ] If exposure is from fair wins, top up/rebalance reserves and record the
      operator decision in the Build Log.
- [ ] If exposure is unexplained, set `system_halt = true` and start forensic
      review before re-enabling games.

### Post-launch UI improvements

These are not launch blockers after PART E.5 because the shipped surfaces use the
shared shell/components and pass the safety gates. Keep them as scoped follow-up
work rather than open-ended visual polishing:

- Casino game-specific canvas/animation depth: the shared casino shell,
  BetPanel, FairnessVerifier, confirmation, and parity flows are launch-ready.
  Stake/Rollbit-level per-game canvas feel is a post-launch enhancement.
- Admin visual polish: the current Admin supports the 1-person operating path
  with guarded actions, reason capture, audit, and queues. Denser mobile/admin
  scan-speed refinements can follow after launch.

### 2. RTP drift

**Trigger**: rolling RTP for a game deviates outside the documented tolerance
after enough settled bets to be statistically meaningful.

**Auto-response**:
- Settlement remains atomic; no retroactive user balance mutation is allowed.
- Affected game should be disabled if drift suggests implementation or seed
  verification risk.

**Recovery checklist**:
- [ ] Inspect rolling RTP:
```sql
SELECT game,
       COUNT(*) AS bets,
       SUM(stake_amount::NUMERIC) AS stake,
       SUM(payout_amount::NUMERIC) AS payout,
       CASE WHEN SUM(stake_amount::NUMERIC) = 0
            THEN NULL
            ELSE SUM(payout_amount::NUMERIC) / SUM(stake_amount::NUMERIC)
        END AS rtp
  FROM casino_bets
 WHERE settled_at > NOW() - INTERVAL '24 hours'
 GROUP BY game;
```
- [ ] Recompute a sample of settled results from revealed server seeds.
- [ ] Compare implementation against ADR-001 settle parity requirements.
- [ ] If parity mismatch is confirmed, keep the game disabled and use Scenario 4.

### 2-a. Post-reveal client verification mismatch

**Current launch posture**: the shipped browser flow verifies after reveal only.
`rpc_open_game_round` exposes `server_seed_hash` before the bet and reveals
`server_seed` only after settlement, so the client cannot compute
`p_expected_result` before betting without breaking the provably-fair
commitment. The server remains the settlement authority, and the post-reveal
`verifyRound` result is the user-visible PF check.

**Known gap**: a browser-detected post-reveal mismatch is shown in the casino UI
but is not currently reported back to an audit/flag RPC. This is not a launch
blocker because the primary defense remains server-authoritative settlement plus
hash-before-bet/reveal verification, but it should be considered for a
post-launch lightweight reporting path.

**Post-launch option**: enabling the `parity_hold` belt on the real browser path
requires a commitment-preserving trusted verifier architecture. Do not wire
arbitrary `p_expected_result` from `casino.tsx`; it would create false positives
or weaken the seed commitment.

### 3. Mass cancel

**Trigger**: an oracle outage, market halt, sanctions batch, or operational
incident requires many open positions/requests to be cancelled without breaking
ledger conservation.

**Auto-response**:
- Use only idempotent RPCs or reviewed admin queue actions.
- Never update wallets directly.

**Recovery checklist**:
- [ ] Freeze new affected actions through feature flags or `system_readonly`.
- [ ] Export the target rows and reason before mutation:
```sql
SELECT id, user_id, status, created_at
  FROM withdrawal_requests
 WHERE status = 'pending'
 ORDER BY created_at;
```
- [ ] Process cancellations through the admin queue/RPC path with a consistent
      reason string.
- [ ] Verify every rejected withdrawal unlocked funds:
```sql
SELECT id, user_id, amount, status, ledger_unlock_id
  FROM withdrawal_requests
 WHERE status = 'rejected'
 ORDER BY reviewed_at DESC
 LIMIT 50;
```
- [ ] Run conservation and hash-chain checks before resuming traffic.

### 4. Settle-parity mismatch (ADR-001)

**Trigger**: client-side recomputation or SQL tests show that stored casino
outcome does not match the revealed seed/nonce/game algorithm.

**Auto-response**:
- Disable the affected game immediately.
- Preserve all rows; do not patch historical outcomes in place.

**Recovery checklist**:
- [ ] Capture the bet id, game, server seed hash, revealed seed, client seed,
      nonce, stored outcome, and recomputed outcome.
- [ ] Confirm whether the mismatch is display-only or settlement-affecting.
- [ ] If settlement-affecting, set `system_halt = true`.
- [ ] Review ADR-001 and the game engine parity tests before any code change.
- [ ] After the fix, run casino unit tests, SQL conservation tests, and casino
      Playwright E2E before re-enabling.

### 5. Solvency violation (ADR-005) and deposit reconciliation mismatch

**Trigger**: user wallets plus locked balances exceed reserves, or deposit
reconciliation cannot match incoming funds to expected references.

**Auto-response**:
- Deposit reconciliation mismatch must enter `system_readonly` rather than
  silently crediting user balances.
- Withdrawals stay disabled until reserves and ledger sums are reconciled.

**Recovery checklist**:
- [ ] Confirm global conservation:
```sql
SELECT
  'PHON' AS ccy,
  (SELECT COALESCE(SUM(phon_available::NUMERIC + phon_locked::NUMERIC), 0) FROM wallets)
  + (SELECT COALESCE(SUM(balance::NUMERIC), 0) FROM system_accounts WHERE currency = 'PHON') AS total
UNION ALL
SELECT
  'USDT',
  (SELECT COALESCE(SUM(usdt_available::NUMERIC + usdt_locked::NUMERIC), 0) FROM wallets)
  + (SELECT COALESCE(SUM(balance::NUMERIC), 0) FROM system_accounts WHERE currency = 'USDT');
```
- [ ] Confirm reserve coverage:
```sql
SELECT currency, real_balance, buffer_pct, updated_at FROM treasury_reserves;
```
- [ ] Inspect unmatched deposits and reference codes.
- [ ] Keep `system_readonly = true` until the unmatched deposit is resolved or
      explicitly rejected through an audited admin action.
- [ ] Record the incident, root cause, and final recovery state in the Build Log.

### 6. Remote config drift

**Trigger**: local migrations and remote `app_config` disagree after a batch
push or launch-prep audit. The concrete Wave 10 discovery was remote
`feature_withdrawal_enabled=true` from the `000019` default while local `000035`
intentionally sets the same key to `false` until the withdrawal lock lifecycle
and operator launch decision are complete.

**Auto-response**:
- Do not assume migrations fixed the flag because the file exists locally.
- If withdrawal RPCs exist remotely while `feature_withdrawal_enabled=true`,
  treat it as §STOP until the operator confirms withdrawal launch intent.
- Remote apply remains an operator-facing Wave 12 action; do not patch config as
  an ad hoc remote change during prep.

**Detection checklist**:
- [ ] Confirm remote migration state:
```sql
SELECT version, name
  FROM supabase_migrations.schema_migrations
 ORDER BY version;
```
- [ ] Confirm critical remote config values:
```sql
SELECT key, value
  FROM app_config
 WHERE key IN (
   'system_halt',
   'system_readonly',
   'feature_deposit_enabled',
   'feature_withdrawal_enabled',
   'feature_spot_enabled',
   'feature_futures_enabled',
   'feature_staking_enabled',
   'feature_game_enabled'
 )
 ORDER BY key;
```
- [ ] Confirm whether withdrawal RPCs exist:
```sql
SELECT p.proname
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN (
     'rpc_request_withdrawal',
     'rpc_approve_withdrawal',
     'rpc_reject_withdrawal',
     'rpc_mark_withdrawal_sent'
   )
 ORDER BY p.proname;
```
- [ ] After Wave 12 push only: directly query remote
      `feature_withdrawal_enabled` and require `false`. If it is not `false`,
      stop before user traffic.

**Recovery checklist**:
- [ ] Classify the drift: expected pending migration diff, stale config value, or
      unexplained remote DDL/data drift.
- [ ] If unexplained, stop and compare `supabase db diff --linked` output before
      taking action.
- [ ] If the only issue is a stale feature flag after an approved push, set the
      intended value through the audited admin path or a reviewed migration, then
      record the reason in the Build Log.
- [ ] Re-run advisor, SQL tests where applicable, and live config queries before
      resuming launch.

### 7. Leverage increase gate

**Trigger**: operator wants to raise `futures_markets.max_leverage` above the
conservative launch defaults (`PHONUSDT-PERP=10`, `BTCUSDT-SIM=20`,
`ETHUSDT-SIM=20`, new markets default `10`).

**Hard rule**: never raise leverage directly with ad hoc SQL. Use the audited
`rpc_set_market_limits` path with a clear reason, and only after every checklist
item below is green.

**Current limits and caps**:
```sql
SELECT symbol, is_active, max_leverage, max_user_positions, max_open_interest
  FROM futures_markets
 ORDER BY sort_order, symbol;
```

**Checklist before any leverage increase**:
- [ ] External feed is stable for the target market. Confirm the concrete
      oracle config values that govern this market:
```sql
SELECT key, value
  FROM app_config
 WHERE key IN ('oracle_staleness_seconds', 'oracle_outlier_pct', 'oracle_min_sources')
 ORDER BY key;

SELECT symbol, staleness_seconds, max_tick_pct, is_halted
  FROM market_circuit_breakers
 WHERE symbol = '<market>';
```
- [ ] For leverage above launch defaults, the market must run with at least two
      non-stale sources (`oracle_min_sources >= 2` or documented equivalent for
      the market), 0 unresolved staleness incidents, outlier rejection tested,
      and no unexpected circuit-breaker halts.
- [ ] `max_open_interest` is finite and sized for the proposed leverage. Do not
      increase leverage while `max_open_interest` is NULL or near saturation.
- [ ] Liquidation engine is verified: `phonara_auto_liquidations` cron is active,
      liquidation parity SQL tests are green, and an underwater-position dry run
      liquidates at the expected price.
- [ ] Insurance/reserve coverage is adequate for the proposed market exposure.
      Do not assume the insurance fund is complete until its own build and tests
      are recorded in the Build Log.
- [ ] Apply the change through the audited RPC:
```sql
SELECT rpc_set_market_limits(
  '<market>',
  <max_user_positions>,
  '<max_open_interest>',
  '<new_max_leverage>',
  '<operator reason>'
);
```
- [ ] After the change, run SQL trading tests, focused trading E2E, and record
      the before/after values plus the reason in the Build Log.

### 8. Wave 12 post-push security advisor gate (mandatory)

**Trigger**: operator applies local migrations `000025`–`000044` to the locked
remote project (`yocjhjsdwoijfdrehzoq`) as part of Wave 12 batch push.

**Critical distinction**:
- Pre-push `bun run check:advisors` with `SUPABASE_ACCESS_TOKEN` queries the
  **current remote** schema (historically through `000024`). A **0 ERROR** result
  there does **not** validate new local-only security code such as
  `rpc_get_candles` SECURITY DEFINER, treasury grant alignment (`000044`), or OI
  advisory locks.
- The **authoritative** advisor pass for new code happens **only after** the
  Wave 12 push when remote DDL matches local head (`000044`).

**Mandatory checklist (Wave 12 push completion gate)**:
- [ ] Confirm remote migration head includes `000044`:
```sql
SELECT version, name
  FROM supabase_migrations.schema_migrations
 ORDER BY version DESC
 LIMIT 5;
```
- [ ] Run `bun run check:advisors` (or CI `advisors` job) against the linked
      project with `SUPABASE_ACCESS_TOKEN` set. **Require 0 ERROR** on security
      advisor. Record WARN/INFO breakdown in the Build Log.
- [ ] If security ERROR appears on new definer functions (`rpc_get_candles`,
      `_assert_position_limits`, treasury admin RPCs), stop launch prep until
      resolved — do not treat pre-push 0 ERROR as proof.
- [ ] Re-run `bun run test:sql` against local stack and focused E2E
      (`group-d-hardening.spec.ts` includes OI race + candle volume) before
      resuming user traffic.

**WARN interpretation (baseline at remote `000024`, pre-push)**:
- `authenticated_security_definer_function_executable` (lint 0029): expected
  for guarded `rpc_*` definer wrappers; internal auth checks are the control.
- Performance WARNs (`auth_rls_initplan`, `multiple_permissive_policies`) are
  scale/perf hints, not launch blockers, but should be tracked if counts spike
  after push.

---

## 빠른 참조 SQL

```sql
-- 전체 PHON/USDT 보존 확인 (Σ = 상수)
SELECT
  'PHON' AS ccy,
  (SELECT COALESCE(SUM(phon_available::NUMERIC + phon_locked::NUMERIC), 0) FROM wallets)
  + (SELECT COALESCE(SUM(balance::NUMERIC), 0) FROM system_accounts WHERE currency = 'PHON') AS total
UNION ALL
SELECT
  'USDT',
  (SELECT COALESCE(SUM(usdt_available::NUMERIC + usdt_locked::NUMERIC), 0) FROM wallets)
  + (SELECT COALESCE(SUM(balance::NUMERIC), 0) FROM system_accounts WHERE currency = 'USDT');

-- 시스템 계정 현황 (인슈어런스펀드 음수 확인)
SELECT code, currency, balance FROM system_accounts ORDER BY currency, code;

-- 최근 audit_log (고위험 관리자 액션)
SELECT performed_at, admin_id, action, target_type, target_id, reason
  FROM audit_log ORDER BY performed_at DESC LIMIT 20;
```
