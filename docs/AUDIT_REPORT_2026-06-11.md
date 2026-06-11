# PHONARA 전수 감사 보고서 — 2026-06-11

> 읽기 전용 감사(수정 0 / 리모트 변경 0). 발견만 기록한다. 수정은 9영역 종료 후
> 우선순위를 정해 별도 진행한다. 근거는 모두 실제 코드 인용(파일:라인)으로 뒷받침한다.
>
> **감사 목적**: Group A~D 종료 확인 후, Group E(보험기금) 진입 전 토대 검증.
> E는 `system_accounts`(insurance_fund / house_fee), `system_account_ledger`,
> `treasury_reserves`, Σ=0 정산, 솔벤시 게이트 위에 쌓이므로 이 토대의 결함을 특히
> 주의 깊게 본다.

## 감사 환경 메모

- **Supabase MCP** : Cursor 3.7.27에서 `Loading tools` / MessagePort 고장 지속(MCP
  미사용). **영역 9는 MCP 없이 CLI로 실측 완료**: `supabase migration list --linked`,
  `supabase db query --linked`, `.env`의 `SUPABASE_ACCESS_TOKEN` + `bun run
  check:advisors`(셸에서 env 로드). `supabase login` + link `yocjhjsdwoijfdrehzoq` 정상.
- 영역 1~8 중 MCP 의존 "리모트 확인 필요" 항목은 영역 9 CLI 실측으로 대부분 해소(아래 §9).
- 감사 명령 문서(`PHONARA_FULL_AUDIT_COMMAND.md`)는 `docs/`에도 첨부에도 없었다.
  사용자 메시지에 명시된 9영역 정의를 기준으로 진행한다.

---

# ★ 수정 우선순위 — 3개 목록 (섞지 말 것)

> 감사 발견을 **우선순위가 흐려지지 않도록 3개 목록으로 분리**한다.
> ① E 선결 토대(E 착수 전 必) · ② 출시 전 정리/모니터링(E 무관) · ③ 스케일/리모트 대조.
> 모두 읽기 전용 감사 결과이며 이번 패스에서 **미수정**(수정은 9영역 종료 후 별도).
> E가 따를 **모범 답안**은 별도 「★ E 구현 가이드」 섹션 참조(코드에 이미 검증된 템플릿 존재).

## ① E 선결 토대 (E 착수 = 이 5종 정리 후 시작)

> Group E(보험기금)는 머니 최고위험이며, 발견들이 "지금 실위험 0이나 **E가 직접 의존하는
> 토대의 2차 방어선 공백**"으로 수렴한다. E가 이 위에 쌓이면 단일 방어선 의존이 위험으로
> 전환된다.

| # | ID | 토대 | 공백(2차 방어선) | 현재 실위험 | E 영향 | 상세 |
|---|----|------|------------------|-------------|--------|------|
| 1 | **A1-1** | `system_account_ledger` | append-only RULE 부재(다른 원장엔 있음) | 0 (RLS 차단) | 보험기금 원장 사후 변조 가능 | §A1-1 |
| 2 | **A2-1** | `system_accounts`/`_ledger` | authenticated INSERT/UPDATE GRANT 잔존(REVOKE 벨트 없음) | 0 (RLS 한 겹) | 정책 1개 실수 시 house/보험 직접 변조 | §A2-1 |
| 3 | **A2-3/A8-3** | 일일 정산 크론 | 시스템계정·전체 Σ=0·hash-chain 미검증(런타임 크론/함수로 재확정) | 0 (유저지갑은 검증) | 보험기금 이동이 자동정산 사각 | §A2-3, §A8-3 |
| 3b | **A8-2** | `system_account_ledger`(보험 원장) | append-only RULE·hash-chain·자동검증 **3무**(가장 무방비 원장) | 0 (anon 차단·읽기잠금) | E 보험기금 원장 = 변조 자동탐지 0 | §A8-2 |
| 4 | **A1-4/A2-6** | 솔벤시 게이트 | 게이트 2개 공존(의미도 다름) | 0 (권위 게이트만 호출) | E가 죽은 게이트 참조/혼란 위험 | §A1-4, §A2-6 |
| 5 | **A3-3** | `treasury_reserves` | authed-read 전 컬럼 노출(`notes`/`updated_by` 포함) | 0 (anon 차단) | E 솔벤시 토대 — 노출 컬럼 스코프 미정의 | §A3-3 |

**권장 정리 순서(제안만, 이번엔 미수정)**:
1. `REVOKE INSERT,UPDATE,DELETE,TRUNCATE ON system_accounts, system_account_ledger FROM anon, authenticated` (A2-1) + `system_account_ledger` append-only RULE 추가 (A1-1) — 같은 마이그레이션에 묶음.
2. 정산 RPC에 시스템계정 보존 + `verify_ledger_hash_chain` 호출 추가, 또는 시스템계정 전용 정산 (A2-3).
3. 고아 `_assert_withdrawal_gate` + 전용 테스트 제거, 솔벤시 게이트 단일화 (A1-4/A2-6).
4. `treasury_reserves` authed-read를 컬럼 제한 뷰(`currency/real_balance/buffer_pct/payout_cap_pct`)로 좁히고 `notes`/`updated_by`는 admin-only (A3-3).
5. (E 통화 범위에 KRW 포함 시) `insurance_fund_krw` 등 시드 추가 (A2-5).

> 각 항목은 high-risk 머니 마이그레이션이므로 적용 시 로컬 `supabase db reset` + 보존(Σ=0)/
> hash-chain SQL 테스트 + 보안 advisor 0 ERROR 게이트 필수(00-core/20-supabase-safety).

## ② 출시 전 정리/모니터링 (E와 무관, 출시 전 처리)

| ID | 심각도 | 무엇 | 수정방향(제안) |
|----|--------|------|----------------|
| **A5-1** ⚠️ | **중간 · 출금 개통 선결** | **웹 출금에 ConfirmDialog 누락** — 가장 비가역적 액션인데 유일하게 확인 없음(`wallet.tsx:463` 즉시 실행). 현재 `feature_withdrawal_enabled=false`로 막혀 무사고이나 **출금 여는 순간 살아 있어야 함** | `@phonara/ui` `ConfirmDialog` 적용 + **금액·수수료·실수령액·통화 표시**(거래소 표준). 출금 개통 전 必 |
| **A3-1** | 중간 | `app_config` 전면 공개 → **anon이 AML/구조화방지 임계값 + 하우스 한도 평문 조회**(컴플라이언스 회피선 공개) | **전체 차단 아님**: `is_public` 플래그 / 공개 화이트리스트 뷰로 민감 키(`screening_*`/`str_*`/`casino_house_exposure_*`)만 admin-only 분리, 클라 필요 키(`feature_*`/`casino_min,max_stake_*`/`synthetic_book_*`/`system_halt,readonly`)는 공개 유지 |
| **A3-4** | 낮음 | `price_change_audit` 공개 읽기 → 관리자 uuid·변경 사유 anon 노출 | admin-only 전환 또는 actor/사유 제외 뷰만 공개 |
| **A3-5** | 낮음 | `market_sources` authed-read → 오라클 provider 구성·weight 노출(자격증명 없음) | 클라 불필요 시 admin-only 회수 |
| **A5-3** | 낮음(a11y) | 하드코딩 영어 `aria-label`(Loading×4·Admin nav) | i18n 키화 |
| **A5-4** | 낮음 | 룰렛 프라이즈 코드 하드코딩(DB-driven 아님) | DB/app_config 기반 + `formatMoney` |
| **A5-2** | 낮음 | read-only 화면 error 상태 미분리(에러→empty 혼동) | `error` 노출 + 재시도 CTA |
| **A7-5** | 낮음~중간 | **E2E teardown 부재** — 테스트 유저 생성 후 정리 0(`afterAll`/`deleteUser` 없음), 영속 잔여(이전 db reset 실패 후보) | `test.afterAll`로 `deleteUser` 정리 |
| **A7-3** | 낮음 | 솔벤시 테스트 일부가 **고아 게이트** 검증(죽은 함수) | A1-4/A2-6 정리 시 고아 함수+Test5/6 동시 삭제 |
| **A7-2** | 낮음 | SQL "race" 테스트 단일 세션(청산-마감 진짜 동시성 미검증). OI는 E2E 병렬로 커버 | 청산-마감 병렬 E2E 추가 or 테스트명 정정 |
| **A7-4** | 낮음 | 추천 보상 테스트 절대값(2000/6000) + Σ=0 미단언 | 보존 단언 추가 + config 비교 |
| **A6-3** | 낮음 | 미사용 루트 deps(`framer-motion`/`lucide-react`) + **`check:deps` knip이 `--workspace "@phonara/*"`라 루트 미검사** | deps 제거 **+ 게이트 스코프를 루트(`.`)까지 확장**(D1 구멍 메움) |
| **A6-1** | 낮음(재현성) | `@phonara/ui` devDeps `typescript:"latest"`·`vitest:"latest"` | 루트와 동일 버전 핀 |
| **A6-2** | 낮음(재현성) | 워크스페이스 버전 드리프트(admin `zod 3` vs web `zod 4` 등) | 버전 정렬(zod 4 통일) |

## ④ ADR 불변식 배선 결함 (영역 8 최우선 정밀 — 단순 정리 아님)

> "있다고 믿은 안전망이 실배선 안 된" 케이스(출금 escrow 사건과 동류). 별도 표시.

| ID | 심각도 | 무엇 | 영역 8 확인 사항 |
|----|--------|------|------------------|
| **A8-2** | **배선 결함** | **hash-chain 자동검증 휴면** — 라이브 크론 3개 중 누구도 `verify_ledger_hash_chain` 미호출(런타임 확정), 수동 RUNBOOK/테스트만. 일일 정산도 hash-chain 미검증 → 원장 변조 자동 탐지망 휴면. 완화: `wallet_ledger` append-only RULE+RLS. **E선결 토대 중복**(보험 원장은 3무) | `rpc_run_reconciliation`에 `verify_ledger_hash_chain` 호출 추가(비0→halt) 또는 전용 검증 크론 |
| **A4-3 / A7-1 / A8-1** | **배선 결함** | **ADR-001 parity mismatch auto-kill이 웹 베팅 경로에서 휴면** — 클라(`casino.tsx`)가 `p_expected_result` 미전송 → SQL parity 체크(`...000029:735`) 스킵. 근인은 카지노 RNG 도메인 불일치(SQL `NUMERIC[]` vs TS double). **영역 7에서 테스트 코드로 재확정**: `casino_schema_test.sql:264-272`가 parity_hold를 **오직 테스트 전용 6번째 인자**로만 트리거 | ① Wave 2 Build Log "parity_hold 동작 증명"이 테스트의 명시적 `p_expected_result` 주입에 의존했나, 실유저 경로 반영했나? ② 설계 의도가 "모든 베팅 parity 검증"이었나 "테스트만"이었나? ③ 수정 = **(a) SQL float double 통일(근본원인=도메인 차이 제거) 선호** — (b) 도메인 불일치 채 안전망만 켜면 양성 오탐↑. 단 게임엔진 머니 경로라 강한 모델+패리티 테스트 必 |

## ③ 스케일/리모트 대조

| ID | 심각도 | 무엇 | 처리 |
|----|--------|------|------|
| **A3-2** | 중간(스케일) | `auth_rls_initplan` — 로컬 **31** / 리모트 **20**(§A9-3 실측). unpushed `000025`–`000044`가 +11 정책 | push 후 `(select auth.uid())` 일괄 치환 + post-push advisor |
| (영역 1) | 낮음(스케일) | `unused_index **37**` / `unindexed_foreign_keys **14**` (§A9-4 리모트 advisor 실측) | Wave 12 post-push 성능 정리 |

---

# ★ E 구현 가이드 (코드에 이미 있는 모범 답안 — trading-engine 패턴 복제)

> **영역 4의 핵심 성과**: E(보험기금·청산·bad_debt)가 따를 **검증된 TS↔SQL 패턴이 이미
> 코드에 존재**한다(`@phonara/trading-engine` + 선물 정산 RPC + 전용 패리티 테스트). E는 이를
> 새로 설계하지 말고 **복제**한다. 아래는 그 모범 답안의 구성요소와 적용 규칙.

## E가 복제할 5요소

| 요소 | 모범 답안(위치) | E 적용 |
|------|------------------|--------|
| 1. Decimal 단일설정 | `@phonara/money` `configure-decimal.ts`(precision 28, ROUND_HALF_UP) + 호출(`trading-engine/shared.ts:4`) | E 계산 모듈은 `@phonara/money` 경유로만 Decimal 사용(직접 `decimal.js` import 금지 — A4-1 함정 회피) |
| 2. SQL 미러 양자화 | `fmt6`(`trading-engine/shared.ts:61-72`)가 SQL `_fmt6`(`to_char(trunc(v,6),'FM…0.000000')`)와 byte 일치 | 보험/청산 레그도 `_fmt6` 6dp `trunc`로 양자화 → TS·SQL 동일 값 |
| 3. Σ=0 레그 분해 | `_settle_futures_position`(`...000009:161-215`)·casino(`...000029:712-759`): 6dp trunc 레그 + dust 레그로 정확히 0, 단일 `transfer_id` 짝, bad debt는 **메트릭만**(라이브니스) | 보험기금 이동도 `_credit/_debit_system_account` 짝 + dust 레그로 Σ=0, bad_debt는 기록만(불균형 원장 금지) |
| 4. 멱등 | 상위 RPC 상태 게이트 + `FOR UPDATE` + keyed wallet 레그(`...000029:669-700`) | E RPC는 상태머신 게이트 + `FOR UPDATE` 필수(시스템 레그는 A2-4대로 독립 멱등 아님) |
| 5. **전용 byte-패리티 테스트** | `sql-parity.test.ts` ↔ `futures_parity_test.sql`(open/close 상수 byte 일치) | E 계산은 TS 단위 + SQL 통합 **양쪽**에 같은 입력/상수 패리티 테스트를 **기능 완료 전** 작성(40-testing) |

## E 추가 필수 게이트 (선결 토대 정리와 연동)

- **권위는 SQL**(클라 미신뢰) — trading/casino처럼 E도 SQL RPC가 정산 권위, TS는 미리보기/검증.
- **솔벤시**: 권위 게이트 `_assert_solvency_withdrawal_gate` 단일화(A1-4/A2-6) 후 그 위에 쌓기.
- **감사무결성**: `system_account_ledger` append-only RULE(A1-1) + REVOKE 벨트(A2-1) 정리 후 E
  보험기금 원장 기록.
- **자동정산 포함**: 정산 크론에 시스템계정·전체 Σ=0·hash-chain 추가(A2-3) — E 이동이 사각에
  안 들어가도록.

> 요약: **E = trading-engine 패턴(Decimal+fmt6+Σ=0레그+멱등+패리티테스트) × E 선결 토대 5종
> 정리.** 새 발명 불필요.

---

# 영역 1 — 스키마 / 테이블 / 인덱스

**범위**: 44개 로컬 마이그레이션(`supabase/migrations/2026060900000{1..44}`)의 전 테이블·
컬럼·인덱스·제약 정적 분석. 중복 테이블/컬럼, 머니 컬럼 CHECK 누락, 타입 불일치, 고아
객체, 그리고 advisor의 `unused_index 37` / `unindexed_foreign_keys 14` 분류.

## 요약

| ID | 심각도 | 한 줄 |
|----|--------|-------|
| A1-1 | **중간** | `system_account_ledger`에 append-only RULE 없음 (E 보험기금 기록 경로) |
| A1-2 | **중간** | 다수 머니/가격 컬럼에 포맷 CHECK 누락 (특히 `futures_positions`, `spot_trades`, 원장 스냅샷) |
| A1-3 | ~~높음~~ → **낮음(런타임 강등)** | `game_rounds.server_seed` 노출 — **런타임 검증 결과 차단됨**(Wave 2 방어 유효). 잔여: 오픈 시 평문 저장 + 死객체 뷰 |
| A1-9 | 낮음 | `v_game_rounds_public`가 死객체 + 비기능(`security_invoker` 뷰인데 grantee가 하위 테이블 SELECT 불가) — 런타임 검증 중 발견 |
| A1-4 | 낮음 | 고아 함수 `_assert_withdrawal_gate` — `_assert_solvency_withdrawal_gate`로 대체됐으나 미삭제 (솔벤시 게이트 2개 공존) |
| A1-5 | 낮음 | `wallet_ledger.rate_snapshot_id`가 FK 미선언 (`krw_deposit_requests`와 불일치) |
| A1-6 | 낮음/스케일 | 미인덱스 FK 다수 (advisor 14건과 정합) — 스케일 이슈, launch blocker 아님 |
| A1-7 | 스케일 | `unused_index 37` — 리모트 pg_stat 실측 필요(MCP 다운), 분류만 |
| A1-8 | 낮음 | `profiles` 자식 테이블 ON DELETE 정책 불일치(CASCADE/RESTRICT 혼재, 사실상 무효) |

> 참고(중복 방지): `auth_rls_initplan 20`은 영역 3(RLS)에서 분류 예정. `verify_ledger_hash_chain`이
> 크론에 연결 안 된 점은 영역 8(불변식)에서 본다. 여기서는 포인터만 남긴다.

---

## A1-1 [중간] `system_account_ledger`에 append-only RULE 부재 — E 보험기금 기록 경로

**위치**: `supabase/migrations/20260609000008_p0_hardening_schema.sql:45-61`
(`system_account_ledger` 정의), 쓰기 경로 `supabase/migrations/20260609000009_p0_auto_liquidation.sql:44-50, 80-86`.

**무엇**: 모든 다른 원장 테이블은 `DO INSTEAD NOTHING` append-only RULE을 가진다 —
`wallet_ledger`(`...000001:125-129`), `position_ledger`(`...000006:125-128`),
`spot_trades`(`...000006:150-153`), `staking_rewards`(`...000006:205-208`),
`audit_logs`(`...000001:196-200`). 그러나 `system_account_ledger`에는 no_update /
no_delete RULE이 **없다**(grep 결과 0건).

**왜 문제**: 30-money-ledger 규칙("Ledger entries are append-only")의 핵심 불변식이
시스템 계정 원장에는 DB 레벨로 강제되지 않는다. `_credit_system_account` /
`_debit_system_account`(=E 보험기금이 그대로 사용할 경로)가 기록하는 원장이 바로 이
테이블이다. RLS가 클라이언트 직접 쓰기는 막지만, SECURITY DEFINER 코드 버그/관리자
경로에서의 사후 변조를 막는 2차 방어선(다른 원장에는 있는)이 여기엔 없다. E가
insurance_fund 정산 감사 추적을 이 테이블에 의존하므로, 토대 비대칭은 쌓기 전에
정리해야 할 후보다.

**근거**:
```45:61:supabase/migrations/20260609000008_p0_hardening_schema.sql
CREATE TABLE system_account_ledger (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_code     TEXT NOT NULL REFERENCES system_accounts(code),
  direction        TEXT NOT NULL CHECK (direction IN ('credit','debit')),
  ...
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX sal_account_idx ON system_account_ledger (account_code, created_at DESC);
CREATE INDEX sal_transfer_idx ON system_account_ledger (transfer_id) WHERE transfer_id IS NOT NULL;
```
(이 블록 이후 RULE 정의 없음 — 다른 원장 테이블과 대조.)

**수정방향(제안만)**: `system_account_ledger`에 `wallet_ledger`와 동일한
`ON UPDATE/DELETE TO ... DO INSTEAD NOTHING` RULE 추가. E 진입 전 별도 마이그레이션으로
처리 권장(토대 일관성).

---

## A1-2 [중간] 머니/가격 컬럼 포맷 CHECK 누락 (방어선 비대칭)

**무엇**: 1차 금액 컬럼(`amount`, `stake`, `margin_amount` 등)은 정규식 CHECK가 붙어
있으나, 다수의 파생/스냅샷/이력 머니·가격 컬럼에는 포맷 CHECK가 없다.

**대표 누락 목록(근거 라인)**:
- `futures_positions`: `notional`, `open_fee`, `liquidation_price`, `close_fee`,
  `equity_returned`(양수형), `realized_pnl`/`exit_price`/`stop_loss`/`take_profit` —
  `...000006:82-92` (CHECK 없음). `margin_amount`/`entry_price`/`quantity`/`leverage`는
  있음(`...000006:78-81`).
- `spot_trades`: `price`, `phon_amount`, `usdt_amount`, `fee_amount` 전부 CHECK 없음
  (`...000006:137-143`).
- `position_ledger`: `price`, `realized_pnl`, `fee` CHECK 없음 (`...000006:115-117`).
- 원장 스냅샷: `wallet_ledger.available_before/locked_before/available_after/locked_after`
  (`...000001:107-110`), `system_account_ledger.balance_before/balance_after`
  (`...000008:51-52`) — 머니 텍스트인데 CHECK 없음.
- 리워드/보너스: `daily_claims.phon_awarded`, `roulette_spins.phon_awarded`,
  `referrals.referrer_phon/referred_phon`, `welcome_bonuses.*`, `missions.phon_awarded`,
  `staking_rewards.reward_amount`, `staking_positions.apr_snapshot/reward_claimed`,
  `game_bets.payout`, `krw_deposit_requests.expected_phon` — CHECK 없음.

**왜 문제**: 30-money-ledger / 25-postgres 규칙은 머니 컬럼에 DB CHECK를 권한다. 쓰기가
RPC를 통하므로 현재 실손 위험은 낮지만(그래서 중간), 버그/직접 변조 시 비정형 머니
문자열이 영속될 수 있는 2차 방어선 공백이다. E의 정산이 `futures_positions`·시스템
원장 스냅샷을 신뢰하므로 `notional`/`liquidation_price`/`balance_after` 등 양수형
컬럼은 우선 보강 후보.

**수정방향(제안만)**: 양수형 머니 컬럼에 `~ '^\d+(\.\d+)?$'`, 부호형(PnL/delta/equity)에
`~ '^-?\d+(\.\d+)?$'` CHECK 일괄 추가. 데이터 적재 후이므로 `NOT VALID` → `VALIDATE`
2단계 적용 검토.

---

## A1-3 [낮음 — 런타임 강등] `game_rounds.server_seed` 노출 — **차단 확인됨**

> **2026-06-11 런타임 재검증 완료(흑백 판정).** 영역 1 초안은 `000028`의 `FOR SELECT
> USING (TRUE)` 정책만 인용해 "높음(노출 가능)"으로 봤으나, **후속 마이그레이션
> `000029`(Wave 2)가 이 정책을 폐기하고 컬럼/테이블 권한을 회수**하는 것을 누락했다.
> `supabase db reset`(44개 전 마이그레이션 클린 적용) 후 실제 쿼리로 검증한 결과,
> authenticated 유저는 베팅 전 시드를 읽을 수 **없다**. → **출시 차단 결함 아님.**

**Wave 2 방어 코드(`...000029:27-47`)**:
```27:47:supabase/migrations/20260609000029_s3_casino_atomic_settlement.sql
DROP POLICY IF EXISTS "public read open rounds" ON game_rounds;
CREATE POLICY "admin read game_rounds" ON game_rounds
  FOR SELECT USING (_is_admin());

REVOKE SELECT ON game_rounds FROM anon, authenticated;
REVOKE SELECT (server_seed) ON game_rounds FROM anon, authenticated;

CREATE OR REPLACE VIEW v_game_rounds_public
WITH (security_invoker = true)
AS
SELECT id, game, server_seed_hash, status, result_payload, created_at, settled_at
FROM game_rounds;

GRANT SELECT ON v_game_rounds_public TO anon, authenticated;
```

**런타임 증거 1 — 권한/뷰 컬럼**:
```
 auth_tbl_select | auth_col_seed | anon_tbl_select | auth_view_select
       f         |       f       |        f        |        t
v_game_rounds_public 컬럼: id, game, server_seed_hash, status, result_payload, created_at, settled_at
(server_seed 컬럼 없음)
```

**런타임 증거 2 — 실제 SELECT 시도(서버 시드 채워진 행 대상)**:
```
SET ROLE authenticated;  set request.jwt.claims = {"sub": <uuid>};
SELECT server_seed FROM game_rounds LIMIT 1;
→ ERROR:  permission denied for table game_rounds
```

**판정**: PF 커밋-리빌 불변식은 런타임에서 유지된다. 클라이언트는 시드 해시를 **RPC
반환값**으로 받으며(`apps/web/src/routes/casino.tsx:280,334,494,539`), 테이블/뷰를
직접 읽지 않는다. → **실위험 없음. "스키마 의미 vs 실제 정책 불일치"로 강등.**

**잔여 권고(수정방향, 제안만)**:
1. `rpc_open_game_round`(`...000031:36-37`)가 오픈 시점에 `server_seed` 평문을 저장하는
   것은 방어선이 회수 권한 1개에 의존하게 만든다(미래 마이그레이션이 SELECT를 재부여하면
   노출 부활). 리빌 시점에만 기록하는 모델이 belt-and-suspenders로 더 안전.
2. 영역 1 초안의 교차영역 우려(영역 3/8 최우선)는 **해소** — 영역 8에서는 "코드 정리
   권고" 수준으로만 다룬다.

---

## A1-9 [낮음] `v_game_rounds_public` — 死객체 + 비기능 (런타임 발견)

**위치**: `supabase/migrations/20260609000029_s3_casino_atomic_settlement.sql:34-47`.

**무엇**: 위 검증 중 발견. `v_game_rounds_public`는 `security_invoker = true`로 생성돼
호출자 권한으로 하위 테이블을 읽는다. 그런데 `authenticated`/`anon`은 `game_rounds`
테이블 SELECT가 전부 REVOKE된 상태라, **뷰를 읽어도 `permission denied for table
game_rounds`가 난다**(런타임 확인). 즉 뷰는 의도된 사용자에게 동작하지 않는다.

**런타임 증거**:
```
SET ROLE authenticated;
SELECT id, game, server_seed_hash, status FROM v_game_rounds_public LIMIT 1;
→ ERROR:  permission denied for table game_rounds
```

**왜 문제(낮음)**: 보안 위험은 없다(오히려 "안전하게 고장"). 그러나 (a) 어떤 클라이언트
코드·SQL도 이 뷰를 참조하지 않으며(grep: 생성·GRANT 외 0건), (b) 동작하지도 않으므로
순수 死객체다. 의도가 "공개 라운드 뷰 제공"이었다면 미충족(클라이언트는 RPC 반환값
사용). 영역 4/5 정리 후보.

**수정방향(제안만)**: 뷰 제거하거나, 공개 라운드 노출이 실제 필요하면 `security_definer`
뷰 + 안전 컬럼만 + 적절한 GRANT로 재설계. 이번엔 수정하지 않음.

---

## A1-4 [낮음] 고아/중복 솔벤시 게이트 — `_assert_withdrawal_gate`

**위치**: `supabase/migrations/20260609000026_s1_solvency_reconciliation.sql:138-184`.

**무엇**: `_assert_withdrawal_gate(currency, TEXT)`는 정의·REVOKE 되어 있으나, 어떤
RPC에서도 호출되지 않는다. 실제 출금 경로(`rpc_request_withdrawal`,
`...000033`/`...000035`)는 `_assert_solvency_withdrawal_gate(currency)`를 호출한다.
grep 결과 `_assert_withdrawal_gate` 호출처는 `supabase/tests/solvency_reconciliation_test.sql`
(라인 167, 205)뿐 — 즉 테스트만 살아있는 고아 함수.

**왜 문제**: 동일 목적(출금 솔벤시 가드)의 함수가 2개 공존한다. E가 솔벤시 게이트 위에
쌓이므로, 어느 게이트가 권위인지 모호하면 후속 작업이 죽은 함수를 확장/참조할 위험.
보안 위험은 낮음(REVOKE 됨). 죽은 코드 + 테스트가 죽은 코드를 검증.

**근거**: `_assert_withdrawal_gate` 본문은 `v_required = user_total × (1 + buffer/100)`
(공급 ≥ 수요×(1+buffer)) 모델인 반면, 권위 게이트 `_assert_solvency_withdrawal_gate`는
`user_total ≤ real × (1 − buffer/100)` + fresh-recon 모델(`...000033:442-457`)로 **의미도
다르다**. 두 모델 공존은 혼란 요인.

**수정방향(제안만)**: `_assert_withdrawal_gate` 및 그 전용 테스트 케이스 제거(또는
명시적으로 superseded 주석). E 착수 전 솔벤시 게이트 단일화 권장.

---

## A1-5 [낮음] `wallet_ledger.rate_snapshot_id` FK 미선언 (일관성)

**위치**: `supabase/migrations/20260609000001_phase1_auth_wallet_ledger.sql:114`.

**무엇**: `wallet_ledger.rate_snapshot_id UUID`는 `REFERENCES exchange_rate_snapshots(id)`가
없는 순수 UUID 컬럼이다. 반면 `krw_deposit_requests.rate_snapshot_id`는 FK로 선언됨
(`...000001:157`). 30-money-ledger는 "환율 스냅샷 저장"을 요구하며 무결성 참조가 일관돼야
한다.

**왜 문제**: 환율 스냅샷 참조가 고아가 될 수 있고(존재하지 않는 id 저장 가능),
스키마 일관성/감사 추적 약화. 실손 낮음.

**수정방향(제안만)**: FK 추가 검토(데이터 정합 확인 후 `NOT VALID`→`VALIDATE`).

---

## A1-6 [낮음/스케일] 미인덱스 외래키 — advisor 14건과 정합

**무엇**: 정적 분석으로 커버링 인덱스(선행 컬럼=FK)가 없는 FK 후보를 다수 발견. advisor의
`unindexed_foreign_keys 14`와 방향 일치(정확한 14건 집합은 리모트 `pg_indexes` 대조 필요 —
MCP 다운). 대표 후보:

- `exchange_rate_snapshots.created_by` → profiles (인덱스 없음, `...000001:141`)
- `krw_deposit_requests.wallet_id`, `.rate_snapshot_id` → (인덱스 없음, `...000001:152,157`)
- `system_account_ledger.related_user_id` → profiles (`...000008:54`)
- `price_change_audit.actor_id` → profiles (`...000008:100`)
- `staking_positions.pool_id` → staking_pools (`...000006:171`)
- `withdrawal_requests`의 원장 FK 4종(`ledger_debit_id`,`ledger_lock_id`,
  `ledger_approve_debit_id`,`ledger_reject_unlock_id`)·관리자 FK 3종
  (`approved_by`/`rejected_by`/`sent_by`)·`wallet_id` (`...000033:175,183`, `...000035:22-31`)
- `treasury_reserves.updated_by`, `kyc_submissions.reviewed_by`,
  `admin_review_queue.user_id/resolved_by`, `str_cases.user_id`,
  `deposit_reconciliation_jobs.operator_id`, `risk_flags.cleared_by`, 리워드 테이블의
  `ledger_entry_id` 다수.

**왜 문제**: 부모 행 삭제/조인 시 순차 스캔 → 스케일에서 성능 저하. ON DELETE RESTRICT
부모(profiles/wallets)는 사실상 삭제 불가라 현재 실손 미미. **Launch blocker 아님 —
스케일 이슈로 기록.**

**수정방향(제안만)**: 실제 쿼리 패턴 기준으로 선택적 인덱스 추가(무분별 추가는 A1-7
unused_index 악화). E 관련 `system_account_ledger.related_user_id`는 보험기금 사용자별
조회가 생기면 추가 검토.

---

## A1-7 [스케일] `unused_index 37` — 리모트 실측 필요

**무엇**: advisor가 미사용 인덱스 37건 보고(사용자 제공). 이는 런타임 통계
(`pg_stat_user_indexes.idx_scan = 0`)에 의존하므로 정적 분석으로 정확 집합을 산출할 수
없다. MCP 다운으로 이번 패스 실측 불가.

**왜 문제**: 트래픽 전 단계라 다수 방어적 인덱스(상태별 partial, `created_at DESC` 등)가
아직 미사용일 개연성이 높다(예: `fp_open_status_idx`, `recon_log_mismatch_idx`,
`wr_pending_idx` 등 partial 인덱스). 미사용 인덱스는 쓰기 비용·스토리지만 증가.
**Launch blocker 아님 — 스케일 이슈, Wave 12 advisor 이월과 동일 성격(기진단).**

**수정방향(제안만)**: MCP 복구 후 `pg_stat_user_indexes`로 실측 → 트래픽 누적 후
재평가하여 진짜 미사용만 제거. 지금 제거 금지(트래픽 데이터 없음).

---

## A1-8 [낮음] `profiles` 자식 테이블 ON DELETE 정책 불일치

**무엇**: profiles를 참조하는 자식 테이블의 ON DELETE가 혼재한다 — CASCADE(`user_streaks`,
`welcome_bonuses`, `user_consents`, `sanctions_screenings`, `risk_flags`,
`push_subscriptions`, `rpc_request_idem`, `rpc_rate_limit_buckets`, `kyc_submissions`) vs
RESTRICT(`wallet_ledger`, `futures_positions`, `daily_claims`, `roulette_spins`,
`referrals`, `missions`, `spot_trades`, `staking_*` 등).

**왜 문제**: `wallets.user_id`가 ON DELETE RESTRICT(`...000001:65`)이고 profiles↔wallet이
1:1이므로 사실상 profiles 삭제는 항상 차단된다 → CASCADE 선언들은 죽은 의미. 정합성
혼란 요인일 뿐 실손 없음.

**수정방향(제안만)**: 정책 일원화(전부 RESTRICT 권장, 삭제는 익명화 절차로). 낮은
우선순위.

---

## 영역 1 긍정 확인 (E 토대 건전 항목)

- E가 의존하는 시스템 계정이 모두 시드됨: `insurance_fund_phon/usdt`,
  `house_fee_phon/usdt`, `house_liquidity_*`, `dust_*`, `reward_issuance_phon`
  (`...000008:33-42`), `deposit_conversion_phon`(`...000033:12-15`),
  `withdrawal_payout_*`(`...000035:15-19`). 시스템 계정은 음수 허용 설계 명시(라이브니스).
- `treasury_reserves`: `currency UNIQUE`, `real_balance` 포맷 CHECK,
  `buffer_pct`/`payout_cap_pct` 범위 CHECK 정상(`...000026:27-39`). 통화별 1행 시드.
- 사용자 지갑은 포맷 CHECK + 비음수 CHECK 이중 가드(`...000001:67-80`, `...000008:81-87`).
- `wallet_ledger` 해시체인 컬럼·트리거·`transfer_id` 페어링 존재(`...000008:142-187`).

## 영역 1 미해결/리모트 확인 필요

1. `unused_index 37` 정확 집합 — `pg_stat_user_indexes` 실측(MCP 복구 후).
2. `unindexed_foreign_keys 14` 정확 집합 — 로컬↔리모트 `pg_indexes` 대조.
3. 로컬 스키마와 리모트 실제 스키마 drift(컬럼/제약 적용 여부)는 영역 9에서 본다.

---

**영역 1 종료.**

---

# 영역 2 — RPC 함수 (E 토대 집중)

**범위**: `public` 스키마 전 함수의 definer+search_path, 권한(GRANT/REVOKE) 데드락(A7류),
Σ=0 짝 맞춤, 멱등, 가드 누락, 롤백 보장. **E 토대 함수 집중 정밀**:
`_credit_system_account`/`_debit_system_account`(보험기금 경로),
`_assert_solvency_withdrawal_gate`(권위 게이트), Σ=0 정산 함수들. A1-1·A1-4가 RPC
레벨에서 어떻게 쓰이는지 교차 확인.

**검증 방식**: 로컬 Supabase에 `supabase db reset`(44개 마이그레이션 클린 적용) 후, 카탈로그
(`pg_proc`/`pg_rules`/`has_function_privilege`)와 역할 전환 실쿼리로 **런타임 권위 확인**.
(MCP 다운으로 리모트는 영역 9에서.) 읽기 전용 — 모든 쓰기 시도는 트랜잭션 ROLLBACK.

## 요약

| ID | 심각도 | 한 줄 |
|----|--------|-------|
| A2-1 | **중간** | E 토대 테이블(`system_accounts`/`system_account_ledger`)에 authenticated가 INSERT/UPDATE **테이블 GRANT 보유** — RLS deny-by-default 단일 레이어로만 차단(REVOKE 벨트 없음). A1-1과 결합 시 감사무결성 단일 의존 |
| A2-2 | 중간 | SECURITY DEFINER 함수 3개 search_path 미고정(`rpc_lock_wallet`/`rpc_unlock_wallet`/`rpc_complete_mission`) — advisor `function_search_path_mutable` |
| A2-3 | 중간 (영역8 포인터) | 일일 정산 크론이 **유저 지갑만** 검증 — 시스템계정 원장↔잔액, 전체 Σ=0, hash-chain 미검증. E 보험기금 이동이 자동 정산 사각 |
| A2-4 | 낮음 | `_credit/_debit_system_account`는 **독립 멱등 아님**(키/transfer_id 중복차단 없음) — 호출자 상태 게이트에 전적 의존. E RPC가 따라야 할 규율 |
| A2-5 | 낮음 | `insurance_fund_krw`/`house_fee_krw`/`game_house_krw` 미시드(현재 무해, KRW 보험 포함 시 추가 필요) |
| A2-6 | 낮음 | A1-4 런타임 확인 — 솔벤시 게이트 2개 공존(권위 `_assert_solvency_withdrawal_gate` STABLE vs 고아 `_assert_withdrawal_gate` VOLATILE) |

> **E 토대 긍정 확인(런타임)**: 아래 "영역 2 긍정 확인" 참조 — 가장 중요한 안전 결과들이
> 깨끗하다.

---

## A2-1 [중간] E 토대 테이블 쓰기 표면 — RLS 단일 의존 (REVOKE 벨트 부재)

**위치**: `system_accounts`/`system_account_ledger` 권한(`...000008:520-532` RLS, 테이블
GRANT는 Supabase 기본값), 대조 모범 `...000021:47`.

**무엇(런타임 확인)**: `authenticated` 역할이 다음 테이블 GRANT를 **보유**한다:
```
has_table_privilege('authenticated','system_account_ledger','INSERT') = t
has_table_privilege('authenticated','system_account_ledger','UPDATE') = t
has_table_privilege('authenticated','system_accounts','UPDATE')        = t
```
이 테이블들의 RLS 정책은 `admin read ...`(SELECT)뿐이고 INSERT/UPDATE permissive 정책이
없어 **RLS deny-by-default로 차단**된다. 실쿼리로 검증:
```
SET ROLE authenticated; UPDATE system_accounts SET balance='999999' WHERE code='insurance_fund_phon';
→ UPDATE 0   (RLS가 전 행 필터 → 0행, 인플레 불가)

SET ROLE authenticated; INSERT INTO system_account_ledger(...) VALUES('insurance_fund_phon','credit',...);
→ ERROR: new row violates row-level security policy for table "system_account_ledger"
```

**왜 문제(중간, 실위험 현재 0)**: 차단은 **오직 RLS 한 겹**에 의존한다. 25-postgres 규칙은
내부 테이블에 GRANT 자체를 REVOKE하는 벨트-앤-서스펜더를 권하며, `rpc_request_idem`는
실제로 그렇게 한다:
```47:47:supabase/migrations/20260609000021_p0_request_idempotency.sql
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON rpc_request_idem FROM anon, authenticated;
```
그러나 `system_accounts`/`system_account_ledger`에는 이 REVOKE가 없다. 미래에 누가
permissive write 정책을 잘못 추가하거나 RLS가 실수로 비활성화되면 즉시 house/보험기금
직접 변조 경로가 열린다. **A1-1(append-only RULE 부재)와 결합하면** E의 보험기금 감사
추적이 단일 RLS 레이어에만 의존한다 — E 쌓기 전 정리 후보.

**수정방향(제안만)**: `REVOKE INSERT,UPDATE,DELETE,TRUNCATE ON system_accounts,
system_account_ledger FROM anon, authenticated` + A1-1 append-only RULE 추가.

---

## A2-2 [중간] SECURITY DEFINER 함수 3개 search_path 미고정

**위치**: `rpc_lock_wallet`/`rpc_unlock_wallet`(`...000003:181-325`),
`rpc_complete_mission`(`...000005:412`).

**무엇(런타임 확인)**: `proconfig`에 `search_path`가 없는 SECURITY DEFINER 함수는 정확히 이
3개:
```
pg_proc 조회 결과: rpc_complete_mission, rpc_lock_wallet, rpc_unlock_wallet (proconfig=NULL)
```
`rpc_lock_wallet`/`rpc_unlock_wallet`은 본문에 `SET search_path`조차 없다(`...000003:189-251`).
대다수 머니 함수는 헤더 `SET search_path = public, pg_temp`를 갖는데(예 `...000033`,
`...000044:139-146`), 이 3개는 누락. `...000044`의 search_path 핀 대상에 이들이 빠졌다.

**왜 문제(중간, 실위험 낮음)**: advisor `function_search_path_mutable` 대상. SECURITY DEFINER +
가변 search_path는 이론상 search_path 조작 시 객체 해석 하이재킹 위험. **단, 3개 모두
클라이언트에서 REVOKE됨**(런타임 `auth_exec=f`, `rpc_complete_mission`은 `...000025:34`
REVOKE) — 내부 definer RPC에서만 호출되므로 실위험은 낮다. 규칙 25는 모든 definer에
헤더 SET을 요구하므로 코드품질/advisor 정리 항목.

**수정방향(제안만)**: 3개 함수 헤더에 `SET search_path = public, pg_temp` 추가
(`...000044` 패턴의 `ALTER FUNCTION ... SET search_path`로 가능).

---

## A2-3 [중간 · 영역 8 포인터] 자동 정산이 시스템계정·Σ전체·hash-chain 미포함

**위치**: `rpc_run_reconciliation`(`...000026:200-290`), 크론 등록 `...000044:222-226`.

**무엇**: 일일 크론(`phonara_daily_reconciliation`)이 부르는 `rpc_run_reconciliation`은
통화별 `wallet_sum`(유저 지갑 합) vs `ledger_net`(wallet_ledger credit−debit)만 비교한다
(`...000026:220-242`). 다음을 **검증하지 않는다**:
1. `system_account_ledger` 합 ↔ `system_accounts.balance` 일치.
2. 전체 보존 `Σ(유저지갑) + Σ(시스템계정) = 0` (통화별).
3. hash-chain 무결성 — `verify_ledger_hash_chain`은 존재하나 어떤 크론/RPC도 호출 안 함
   (영역 1에서 포착, 테스트/RUNBOOK 수동 절차로만 사용).

**왜 문제**: E의 보험기금 이동은 `system_account_ledger`에만 기록되는데, 그 무결성을
검증하는 자동 절차가 없다. 시스템계정 측 버그(짝 누락/이중 기입)는 유저지갑 정산을
통과할 수 있다(유저 레그만 보므로). E는 "정산 사각"인 테이블 위에 쌓이게 된다.

**범위**: 정밀 분석은 영역 8(불변식: Σ=0/hash-chain 깨질 경로)에서. 여기서는 RPC 동작으로
교차 확인만.

**수정방향(제안만)**: 정산 RPC에 시스템계정 보존 검증 + hash-chain 호출 추가, 또는 별도
시스템계정 정산 크론. E 착수 전 권장.

---

## A2-4 [낮음] `_credit/_debit_system_account`는 독립 멱등 아님 — E 규율 노트

**위치**: `...000009:22-88`.

**무엇**: 두 헬퍼는 `system_accounts.balance`를 UPDATE하고 `system_account_ledger`에
INSERT만 한다. **멱등 키도, `transfer_id` 중복 차단도 없다**(wallet 측
`_*_wallet_internal`은 `idempotency_key`로 선조회해 중복 차단하는 것과 대조 —
`...000003:197-198`). 정산 함수들은 호출 전 상태 게이트로 보호된다:
`_settle_futures_position`은 `status<>'open' → RAISE`(`...000009:130`),
casino `rpc_place_game_bet`은 진입부 `idempotency_key` 선조회 + `FOR UPDATE`
(`...000029:669-700`). 즉 멱등은 **상위 RPC의 상태 게이트 + FOR UPDATE**가 보장하고,
시스템 레그는 그 우산 안에서만 안전하다.

**왜 문제(낮음, 설계 노트)**: 현재 호출자들은 규율을 지켜 안전하다. 그러나 E의 보험기금
RPC가 (예: house_fee→insurance_fund 시스템간 이체처럼) **선행 keyed wallet 레그 없이**
`_credit/_debit_system_account`만 호출하면 재시도 시 이중 기입 위험. E는 반드시
상태/상태머신 게이트 + `FOR UPDATE`로 멱등을 보장하거나, `system_account_ledger`에
`(transfer_id, account_code)`/`related_tx_id` 유니크를 도입해야 한다.

**수정방향(제안만)**: E RPC에 상태 게이트 강제 + (선택) 시스템 원장 멱등 유니크 도입.

---

## A2-5 [낮음] KRW 시스템계정 미시드

**무엇(런타임 확인)**: `system_accounts` 15행 시드 확인 — `insurance_fund_phon/usdt`,
`house_fee_phon/usdt`, `game_house_phon/usdt`, `house_liquidity_*`, `dust_*`,
`reward_issuance_phon`, `deposit_conversion_phon`, `withdrawal_payout_phon/usdt/krw`.
**KRW 보험/수수료/게임하우스 계정은 없다**(`insurance_fund_krw` 등 부재).

**왜 문제(낮음)**: 현재 마진/게임 통화는 PHON/USDT뿐이라 무해. 단 E의 보험기금 적용
범위에 KRW가 포함되면 `_credit_system_account('insurance_fund_krw', ...)`가
`system_account_not_found`로 RAISE한다. E 설계 시 통화 범위 결정 필요.

**수정방향(제안만)**: E가 KRW 보험을 다루면 해당 계정 시드 추가.

---

## A2-6 [낮음] A1-4 런타임 확인 — 솔벤시 게이트 2개 공존

**무엇(런타임 확인)**:
```
_assert_solvency_withdrawal_gate(currency)          provolatile=s (STABLE)  ← 권위(출금 RPC가 호출)
_assert_withdrawal_gate(currency, text)             provolatile=v (VOLATILE) ← 고아(테스트만 호출)
```
영역 1 A1-4 정적 발견을 런타임으로 확정. 두 함수 모두 존재하며 의미 모델이 다르다
(`user ≤ real×(1−buffer)` + fresh-recon vs `real ≥ user×(1+buffer)`). 출금 경로
(`rpc_request_withdrawal`)는 권위 게이트만 호출(`...000035:163`).

**수정방향(제안만)**: 고아 `_assert_withdrawal_gate`와 전용 테스트 제거(E 솔벤시 게이트
단일화).

---

## 영역 2 긍정 확인 (E 토대 — 가장 중요한 안전 결과, 런타임 검증)

1. **내부 머니 뮤테이터 전부 클라이언트 비노출**: `^_` 함수 중 authenticated/anon EXECUTE
   가능한 것은 `_fmt6`(순수 포맷)·`_is_admin`(불리언 조회) **2개뿐**.
   `_credit/_debit_system_account`, `_*_wallet_internal`, `_debit_locked_wallet_internal`,
   `_settle_futures_position`, 전 `_assert_*` 게이트는 모두 비노출 → **Σ=0/잔액 변조 표면
   잠김**.
2. **A7류 권한 데드락 없음**: `_is_admin` 가드 RPC 23개 중 UI 필요한 admin RPC는 전부
   `authenticated`에 GRANT(treasury/reserve 포함 — A7 수정 `...000044:236-242` 유효).
   svc 전용 5개(`rpc_create_game_round`/`rpc_run_liquidations`/`rpc_settle_game_bet`/
   `rpc_submit_oracle_source_price`/`rpc_sweep_stale_game_bets`)는 설계상 서비스/크론 경로.
3. **Σ=0 정산 템플릿 건전**: `_settle_futures_position`(`...000009:161-215`)·casino
   `rpc_place_game_bet`(`...000029:712-759`) 모두 6dp `trunc` 레그 분해 +
   dust 레그로 정확히 0, 단일 `transfer_id` 짝, bad debt는 **메트릭만**(라이브니스 보존),
   멱등은 상태 게이트 + keyed wallet 레그. E가 따를 검증된 패턴.
4. **시스템계정 직접 변조 차단(실쿼리)**: A2-1 참조 — UPDATE 0행 / INSERT RLS 거부.
5. **E 계정 전부 시드**: `insurance_fund_phon/usdt`, `game_house_*`, `house_fee_*` 등 15행.
6. `rpc_lock_wallet`/`rpc_unlock_wallet` 클라이언트 REVOKE 확인(초기 `...000003:331-332`
   GRANT는 후속 락다운으로 무효화) → 유저가 마진/출금잠금 자금을 우회 언락 불가.

## 영역 2 미해결/리모트 확인 필요

- 리모트 함수 정의가 로컬과 동일한지(특히 search_path 핀 3개, 솔벤시 게이트 2개,
  treasury RPC 단일화)는 영역 9에서 리모트 `pg_proc` 대조 필요(MCP 복구 후).

---

**영역 2 종료. 영역 3(RLS) 진행은 사용자 확인 후.**

---

# 영역 3 — RLS 정책 (민감데이터 노출 · deny-by-default · E 토대 잠금)

**범위**: `public` 48개 테이블 전 RLS 정책의 런타임 전수 — 과개방(`USING(true)`) ↔ 민감컬럼
교차, `auth_rls_initplan`(행마다 `auth.uid()` 재평가) 분류, deny-by-default(RLS on/정책 유무),
E 토대 테이블(`system_accounts`/`_ledger`/`treasury_reserves`/`insurance_fund`) 잠금. **A1-3
방식 계승**: "정적으론 열렸는데 후속이 막은" vs "진짜 열린"을 역할 전환 실쿼리로 흑백 판정.

**검증 방식**: `supabase db reset`된 로컬에 `pg_class`/`pg_policies` 카탈로그 전수 + `SET ROLE
authenticated`(랜덤 sub) / `SET ROLE anon` 실 SELECT. 읽기 전용, 전부 `ROLLBACK`.

## 요약

| ID | 심각도 | 한 줄 |
|----|--------|-------|
| A3-1 | **중간** | `app_config` 전체 공개 읽기(`USING(true)`, `{public}`) — **anon(비인증)이 AML/구조화방지 임계값 평문 조회**(런타임 확인). 단일 5,000,000 / 롤링 10,000,000 KRW·7일·5회·STR 5,000,000 노출 → 구조화 회피 정보 제공 |
| A3-2 | 중간(스케일) | `auth_rls_initplan` — bare `auth.uid()` 정책 **31개**(qual+check, 런타임 카운트; advisor 리모트 20과 영역 9 대조). 행마다 재평가, 스케일 성능. launch blocker 아님 |
| A3-3 | 낮음 (E 교차) | `treasury_reserves` authed-read가 **전 컬럼** 노출 — `real_balance`(PoR 방어가능)뿐 아니라 `notes`(관리자 자유기입)·`updated_by`(관리자 uuid)까지. E 솔벤시 토대 |
| A3-4 | 낮음 | `price_change_audit` 공개 읽기(`USING(true)`) — `actor`(관리자 uuid)+변경 사유가 anon 노출 |
| A3-5 | 낮음/정보 | `market_sources` authed-read — 오라클 provider 구성+weight 노출(자격증명·URL 없음). 경미 |

> **E 토대 긍정 확인(런타임)** : `system_accounts`/`system_account_ledger`/`insurance_fund`는
> 비관리자 authenticated·anon 모두 **0행**(admin-only SELECT, write 정책 부재 → deny-by-default).
> A2-1과 교차: **읽기 표면 잠김 확인**. 쓰기는 RLS로 차단되나 GRANT 벨트는 A2-1대로 부재.

---

## A3-1 [중간] `app_config` 전체 공개 읽기 — AML/구조화방지 임계값 anon 노출

**위치**: `public read app_config` 정책(`...000008` 계열, RLS 정의), 런타임 `pg_policies`:
`app_config | public read app_config | SELECT | USING(true) | roles={public}`.

**무엇(런타임 흑백 — "진짜 열림")** : A1-3(게임 시드)는 후속 마이그레이션이 막은 "거짓 열림"
이었으나, `app_config`는 **후속 차단이 없는 진짜 공개**다. `SET ROLE anon`(비인증) 실쿼리로
확인:
```
SET ROLE anon; set request.jwt.claims = '{}';
SELECT value FROM app_config WHERE key='screening_deposit_single_krw_threshold';   → 5000000
SELECT value FROM app_config WHERE key='screening_deposit_rolling_krw_threshold';  → 10000000
```
공개 노출되는 43개 키 중 **민감 운영/AML 파라미터** :
```
screening_deposit_single_krw_threshold   = 5000000     (단일 입금 강화심사 임계)
screening_deposit_rolling_krw_threshold  = 10000000    (롤링 합산 임계)
screening_deposit_rolling_days           = 7
screening_deposit_count_threshold        = 5
screening_withdrawal_max_age_hours       = 24
str_withdrawal_krw_threshold             = 5000000     (의심거래보고 임계)
casino_house_exposure_cap_phon/usdt      = 5000000 / 500000   (하우스 리스크 한도)
casino_max_payout_phon/usdt              = 1000000 / 100000
system_halt / system_readonly            = false       (운영 상태)
```

**왜 문제(중간)** : 비인증 외부인이 **정확한 구조화(structuring) 회피 경계를 알 수 있다** —
단일 5M·롤링 7일 10M·5회 미만으로 입금을 쪼개면 강화심사/STR을 피한다는 청사진을 그대로
제공한다. AML 통제의 실효성을 직접 약화시킨다(컴플라이언스 리스크). 또 하우스 노출 한도
공개는 정교한 플레이어가 하우스 한계를 역추적하게 한다. 머니 직접 손실은 아니나 **통제
우회 경로**이며, "진짜 열림"으로 런타임 확정된 영역 3 최우선 항목.

**왜 전면 차단은 아닌가** : 다수 키는 **클라이언트가 실제로 필요** — `feature_*`(킬스위치),
`casino_min/max_stake_*`(베팅 UI), `synthetic_book_*`(호가 표시), `system_halt`/`system_readonly`
(UX), `oracle_staleness_seconds`. 즉 문제는 정책 존재가 아니라 **all-or-nothing 전행 공개**다.

**수정방향(제안만)** : `app_config`에 `is_public boolean` 플래그 추가 → 공개 정책을
`USING (is_public = true)`로 축소하고 `screening_*`/`str_*`/`casino_house_exposure_*`/
`updated_by` 등은 `is_public=false`(admin/서버 전용). 또는 클라이언트 필요 키만 노출하는
화이트리스트 뷰(`security_invoker`) + 테이블 직접 SELECT는 admin-only로 회수.

---

## A3-2 [중간 · 스케일] `auth_rls_initplan` — bare `auth.uid()` 정책 31개

**위치**: 런타임 `pg_policies` 전수 — `qual`/`with_check`에 `auth.uid()`가 `(select auth.uid())`
래핑 없이 직접 쓰인 정책 **31개**(영역 1에서 이월된 advisor `auth_rls_initplan`의 런타임 실측).

**무엇** : 정책식이 `auth.uid()`를 직접 호출하면 플래너가 **행마다 재평가**한다(InitPlan 미적용).
`(select auth.uid())`로 감싸면 1회 평가 후 상수화돼 대량 행에서 유의미하게 빠르다. 해당 31개:
```
daily_claims, futures_positions, game_bets, krw_deposit_requests(SELECT+INSERT),
kyc_submissions, market_sources, missions, oracle_source_prices, position_ledger,
profiles(SELECT+UPDATE), push_subscriptions(4종), referrals, roulette_spins,
rpc_rate_limit_buckets, rpc_request_idem, sanctions_screenings, spot_trades,
staking_positions, staking_rewards, treasury_reserves, user_consents, user_streaks,
wallet_ledger, wallets, welcome_bonuses, withdrawal_requests  (= 31, qual+check 합산)
```

**왜 문제(중간·스케일, launch blocker 아님)** : 정확성·보안엔 영향 없음. 대량 행 테이블
(`wallet_ledger`, `position_ledger`, `spot_trades`, `game_bets`)에서 스캔 비용이 행수에 비례
증가. 사용자 지시대로 **기록만**, 출시 차단 아님.

**카운트 불일치 메모** : 런타임 31 vs advisor 리모트 보고 20. 차이는 (a) 런타임은 `qual`과
`with_check`(INSERT/UPDATE)를 둘 다 셈, (b) advisor가 테이블/명령 단위로 묶거나 일부만 플래그
가능성. **영역 9에서 리모트 `pg_policies` 실측으로 정합 확인**(MCP 복구 후).

**수정방향(제안만)** : 각 정책의 `auth.uid()` → `(select auth.uid())`로 일괄 치환(의미 동일,
플래너 최적화). 단일 정리 마이그레이션 권장.

---

## A3-3 [낮음 · E 교차] `treasury_reserves` authed-read 전 컬럼 노출

**위치**: 런타임 `pg_policies`:
```
treasury_reserves | admin rw treasury_reserves | ALL    | _is_admin()
treasury_reserves | authed read treasury_reserves | SELECT | (auth.uid() IS NOT NULL)
```
컬럼: `currency, real_balance, buffer_pct, payout_cap_pct, updated_at, updated_by, notes`.

**무엇(런타임 확인)** : 임의 authenticated(비관리자)가 3행 전부 + `real_balance` 조회 성공
(anon은 0행 → 비공개). 즉 **모든 로그인 유저가 전 컬럼**을 본다:
```
SET ROLE authenticated(random sub);
SELECT count(*) FROM treasury_reserves;            → 3
SELECT real_balance FROM treasury_reserves ...;    → 0.000000 (조회 성공)
```

**왜 문제(낮음, E 토대 교차)** : `real_balance`(실 보유고) 노출은 proof-of-reserves 투명성으로
방어 가능하나, `notes`(**관리자 자유기입 텍스트** — 내부 메모 유출 가능)와 `updated_by`(관리자
uuid)까지 전 로그인 유저에게 열린다. E(보험기금)의 솔벤시 토대가 `treasury_reserves` 위에
쌓이므로, E 착수 전 노출 컬럼 범위를 의도적으로 정해야 한다.

**수정방향(제안만)** : authed-read를 컬럼 제한 뷰(`security_invoker`, `currency/real_balance/
buffer_pct/payout_cap_pct`만)로 대체하고 테이블 직접 SELECT는 admin-only. 또는 `notes`/
`updated_by`를 authed 노출에서 제외.

---

## A3-4 [낮음] `price_change_audit` 공개 읽기 — 관리자 uuid·사유 anon 노출

**위치**: `price_change_audit | public read price_change_audit | SELECT | USING(true) | {public}`.

**무엇** : 가격 변경 감사 로그가 anon에 전면 공개. 행에는 변경 actor(관리자 uuid)와 사유가
포함될 수 있어 **내부 운영 행위자/근거가 외부 노출**된다. 가격 투명성 의도라면 가격 변화만
공개하면 충분하다.

**왜 문제(낮음)** : 머니/보안 직접 위험은 아니나 내부 운영 메타데이터(누가·왜) 노출.

**수정방향(제안만)** : admin-only로 전환하거나, 공개가 필요하면 actor/사유를 제외한 뷰만 공개.

---

## A3-5 [낮음/정보] `market_sources` authed-read — 오라클 구성 노출

**위치**: `market_sources | authenticated read | SELECT | (auth.uid() IS NOT NULL)` (+ admin write).
컬럼: `internal_symbol, provider, provider_symbol, weight, enabled`.

**무엇(런타임 확인)** : 로그인 유저가 오라클 소스 구성(provider 명·심볼·가중치)을 조회 가능.
**자격증명·엔드포인트 URL은 없음**(그건 엣지펑션 env). 경미한 내부 구성 노출.

**왜 문제(낮음/정보)** : 오라클 가중치 구성이 노출되면 가격 조작 모델링에 약간의 정보가 되나,
소스 가격 자체가 공개 시장가라 실질 위험은 미미.

**수정방향(제안만)** : 클라이언트가 불필요하면 admin-only로 회수(선택).

---

## 영역 3 긍정 확인 (런타임 검증)

1. **E 읽기 토대 완전 잠금** : `system_accounts`/`system_account_ledger`/`insurance_fund_*`은
   비관리자 authenticated·anon 모두 **0행**(admin-only SELECT + write 정책 부재 → deny-by-default).
   A2-1 교차 — 읽기 표면 잠김 확인(쓰기 GRANT 벨트만 A2-1 권고로 잔존).
2. **PII/KYC/회계 테이블 적정 스코프(own + admin)** : `profiles`(own read/update),
   `kyc_submissions`(own read + admin rw), `sanctions_screenings`(own + admin rw),
   `withdrawal_requests`(own read + admin rw), `wallets`/`wallet_ledger`(own read),
   `krw_deposit_requests`(own). `bank_incoming_transfers`·`str_cases`는 **admin-only**
   (입금자명/STR 케이스 비노출). PII 과개방 없음.
3. **deny-by-default 무결** : 48개 테이블 전부 RLS on, **정책 0개 테이블 없음**(실수 전면
   차단 없음) + **RLS off 공개 테이블 없음**. write 정책 없는 테이블은 write가 자동 거부됨
   (system_accounts UPDATE 0행으로 A2-1에서 실증).
4. **`USING(true)` 10개 전수 분류** : 8개는 의도된 공개 시장/PF 데이터
   (`futures_markets`/`spot_markets`/`oracle_prices`/`price_ticks`/`market_circuit_breakers`/
   `staking_pools`/`rpc_rate_limit_configs`/`game_seed_reveals`=PF 사후공개). 문제는 `app_config`
   (A3-1)·`price_change_audit`(A3-4) 2개뿐.
5. **A1-3 재확인** : `game_rounds`는 정책 1개(`admin read`, `_is_admin()`)만 — 공개 정책 폐기
   런타임 유지. `game_seed_reveals` 공개는 정산 후 시드 공개(PF 의도된 투명성).

## 영역 3 미해결/리모트 확인 필요

- `auth_rls_initplan` 런타임 31 vs advisor 리모트 20 정합은 영역 9에서 리모트 `pg_policies`
  실측 후 확정(MCP 복구 후).
- 리모트 정책 정의가 로컬과 동일한지(특히 `app_config` 공개 정책, `treasury_reserves`
  authed-read)는 영역 9 drift 검증 대상.

---

**영역 3 종료. 영역 4(패키지/모듈) 진행은 사용자 확인 후.**

---

# 영역 4 — 패키지 / 모듈 (float 머니 · TS↔SQL 패리티 · Decimal 설정)

**범위**: `@phonara/money`·`trading-engine`·`game-engine`·`wallet-ledger` 전 소스의 (1) 머니
계산 float 사용(규칙 30: 머니·odds·rate·balance·PnL), (2) TS↔SQL 동일 계산의 byte 패리티,
(3) `configure-decimal` 단일화(C2) 적용 범위, (4) 데드코드(C3 외), (5) 클라이언트 권위 위반
(UI가 엔진 로직 재구현·권위 값 제출). E가 추가할 보험기금/청산 계산이 따를 토대 검증.

**검증 방식**: 패키지 소스 정적 분석 + 카탈로그/grep 교차(`Number(`/`parseFloat`/`Math.*` 전수,
패키지 간 import 그래프), 그리고 TS 테스트 벡터 ↔ SQL 테스트 벡터(`*_parity_test.sql`) 대조.

## 요약

| ID | 심각도 | 한 줄 |
|----|--------|-------|
| A4-1 | 낮음(현재 무해·기록만) | `game-engine`이 `configureDecimal()`/`@phonara/money` 미사용 — `decimal.js` 직접 import(7파일), C2 단일 설정 밖. 고립 실행 시 precision 기본 20(타 패키지 28). 웹 번들은 money 동반 로드로 현재 무해 |
| A4-2 | 낮음(현재 무해·기록만) | TS `game-engine`의 배당(odds) 계산이 JS float(`Math.floor`/`parseFloat`) — 규칙 30(odds). 단 **정산 권위는 SQL** `_game_result`이고 TS `settle()`는 앱 미사용(검증/테스트 전용) → 현재 무해 |
| A4-3 | 낮음(모니터링) | 카지노 RNG 도메인 불일치 — SQL `_game_float_stream` `NUMERIC[]` vs TS `floatStream` IEEE754 double. **패리티가 "동일 산술"이 아니라 "테스트 벡터"로 보장**됨. **ADR-001 parity_hold 안전망은 웹 경로에서 휴면**(p_expected_result 미전송) → 목록 ②로 분류 |

> **E 토대 긍정 확인(핵심)** : trading-engine 머니 계산은 **전부 Decimal + SQL 미러링 `fmt6`**
> 이며 **전용 byte-패리티 테스트**(`sql-parity.test.ts` ↔ `futures_parity_test.sql`)로 잠겨 있다.
> **E의 보험기금/청산 계산이 따라야 할 검증된 패턴.** 또한 **클라이언트 권위 위반 0**.

---

## A4-1 [낮음] `game-engine` Decimal 설정 미통합 (C2 범위 밖)

**위치**: `packages/game-engine/src/lib/quantize.ts:1`, `games/{dice,crash,limbo,hilo,mines,plinko}.ts:1`
— 전부 `import Decimal from 'decimal.js'`. `configureDecimal`/`@phonara/money` import **0건**
(grep 확인).

**무엇** : `@phonara/money`는 `configure-decimal.ts`에서 import 부수효과로
`Decimal.set({ precision: 28, rounding: ROUND_HALF_UP })`를 건다. `trading-engine`은
`shared.ts:4`에서 `configureDecimal()`를 명시 호출, `wallet-ledger`는 money 헬퍼 경유. 반면
`game-engine`은 `decimal.js`를 직접 들고 와 **설정을 전혀 걸지 않는다**. 웹 앱 번들에서는
`@phonara/money`가 함께 로드돼 공유 `decimal.js` 싱글톤이 precision 28로 설정되므로 현재는
무해하나, **game-engine 단독 실행(유닛 테스트)·import 순서 변동 시 기본 precision 20**으로
동작한다.

**왜 문제(낮음)** : 최종 출력은 `toDecimalPlaces(6, ROUND_DOWN)`/`toFixed(2)`로 양자화돼 28 vs
20 차이가 결과를 바꾸는 경우는 드물다(중간 곱셈에서 28자리 초과 시에만). 그러나 규칙 30/C2
"단일 Decimal 설정" 위반이며, 미래에 game-engine Decimal 경로가 앱 머니에 쓰이면 함정.

**수정방향(제안만)** : game-engine 진입점에서 `import '@phonara/money'`(또는 `configureDecimal()`
명시 호출)로 공유 설정을 보장.

---

## A4-2 [낮음] TS game-engine 배당(odds) 계산 float — 단 정산 권위는 SQL

**위치**: `dice.ts:35,46,49,63,71`(`Math.floor`/`parseFloat`), `crash.ts:19,39,47`,
`limbo.ts:27-28,41`, `hilo.ts:29,36,69`, `mines.ts:21,38`.

**무엇** : 배당 multiplier가 JS float로 계산된다(예 `diceMultiplier`:
`Math.floor(99 / prob) / 100`, prob는 number). `settle()`에서 `stake.mul(new Decimal(mult.toFixed(2)))`
로 Decimal 변환되나, multiplier(=odds) 자체는 float 산술. 규칙 30은 "odds"도 float 금지.

**왜 실위험 낮음(3중 완충)** :
1. **정산 권위는 SQL** `_game_result`/정산 RPC(`...000029`)이며 NUMERIC 산술. 클라가 보낸
   payout을 신뢰하지 않는다.
2. **TS `settle()`는 앱에서 미사용** : `apps` 전수 grep 결과 `.settle(` 호출 0건. 앱은
   `verifyRound`만 사용(`casino.tsx:331`) — `settle()`는 유닛 테스트(`games.test.ts`)·검증
   스캐폴딩 전용.
3. **결과 내장 multiplier**(limbo `resultMultiplier`/crash `crashMultiplier`/hilo round
   `multiplier`)는 `casino_parity_test.sql` ↔ `casino-parity.test.ts` **공유 벡터로 byte 잠금**
   (예 limbo 1.21, hilo 1.83/2.14).

**E 주의** : E의 보험기금·청산 계산은 이 float-multiplier 패턴을 **따르면 안 된다**.
trading-engine의 Decimal+`fmt6` 패턴(A4 긍정 확인)을 따라야 한다.

**수정방향(제안만)** : 장기적으로 game-engine multiplier도 Decimal화(현재는 SQL 권위라
실손 없음). 또는 `settle()`가 비권위임을 명시(이름/주석)해 오용 방지.

---

## A4-3 [낮음 · 주의] 카지노 RNG 도메인 불일치 — TS double vs SQL NUMERIC

**위치**: SQL `_game_float_stream`(`...000029:153-199`) `RETURNS NUMERIC[]`,
누산 `get_byte()::NUMERIC / 256 + .../65536 + .../16777216 + .../4294967296`. TS `floatStream`
(`fairness/float.ts:14-38`) `number[]`, 누산 `f += byte / 256**(j+1)`(IEEE754 double).

**무엇** : 같은 4바이트를 SQL은 **NUMERIC 나눗셈**(분할 스케일 ~16-20dp 반올림), TS는
**double**(값 `k/2^32`는 double에 정확 표현)로 만든다. 둘 다 `roll = floor(f*10000)/100` 등으로
양자화. `casino_parity_test.sql`(roll 18.37, 경로 등)과 `casino-parity.test.ts`(동일 상수)가
**같은 벡터에서 일치**함을 각각 단언 → 현재 일치.

**왜 문제(낮음, 주의)** : 패리티가 **"동일 산술 보장"이 아니라 "공유 테스트 벡터 일치"**로만
성립한다(게임당 2경로). `f*10000`이 정수 경계 ~10^-13 이내인 시드에서 NUMERIC floor와 double
floor가 갈리면, 클라 `verifyRound`(double)가 SQL 저장 결과(NUMERIC)와 **거짓 불일치**를 띄울
수 있다(머니 손실 아님 — SQL이 권위 — 이나 PF 신뢰 훼손). 실발생 확률 극저이나 "구성에 의한
패리티"가 아닌 점을 기록.

**ADR-001 parity_hold 안전망 확인(런타임/코드)** : 사용자 요청대로 "극저확률 불일치를 안전망이
실제로 잡는가"를 추적했다. **결론: 웹 실사용 경로에서 휴면(잡지 못함).**
1. parity_hold/auto-kill은 **`rpc_place_game_bet` 내부**에서만 동작한다 — 호출자가
   `p_expected_result`(TS 계산값)를 넘기면 SQL이 NUMERIC `v_result`와 비교해 다르면
   `parity_hold=TRUE` + 해당 게임 `feature_game_*_enabled=false`(킬스위치) + `parity_mismatch`
   감사행을 쓴다(`...000029:735-742`). 시그니처는 `p_expected_result JSONB DEFAULT NULL`(`:633`).
2. **그러나 웹 클라(`casino.tsx:322-329` `submitBet`)는 `p_expected_result`를 넘기지 않는다**
   → `p_expected_result IS NULL` → parity 블록 **스킵**. 즉 ADR-001 안전망이 실사용에서 비활성.
3. 클라는 베팅 **후** `verifyRound`로 `placed.result`를 자기 TS 재계산과 비교하고
   `setVerification`(`casino.tsx:331-342`)에 담아 **화면 표시만** 한다 — 서버 피드백/킬스위치
   트리거 없음. ⇒ **A4-3 극저확률 불일치는 화면 "검증 실패"로만 뜨고 끝**, parity_hold 미발동.

**수정방향(제안만)** : (a) SQL 플로트 스트림을 `double precision`으로 계산해 JS와 **bit 동일**
보장(4바이트 값은 double에 정확)해 불일치 자체를 제거, 또는 (b) 클라가 `p_expected_result`를
전송해 parity_hold를 **활성화**(단 양성 오탐 시 게임 자동중단 트레이드오프 — A4-3 도메인
불일치가 남아있으면 정상 베팅이 게임을 끌 수 있어 (a) 선행 권장), 또는 (c) 무작위 시드 대량
패리티(fuzz) 테스트. **영역 8 불변식에서 정밀**(parity_hold 설계 의도 vs 실배선). E와 무관(카지노
한정). → 목록 ②(출시 전 정리/모니터링)로 분류.

---

## 영역 4 긍정 확인 (E 토대 — 검증된 패턴)

1. **trading-engine = E가 따를 검증된 TS↔SQL 패턴** : 전 머니 계산 Decimal(`shared.ts`
   `dec`/`fmt6`), `fmt6`는 SQL `_fmt6`(trunc 6dp)를 byte 미러(`shared.ts:61-72`). 전용 패리티
   테스트 `sql-parity.test.ts`가 `futures_parity_test.sql`과 open/close 상수를 byte 일치로 잠금
   (quantity `70003.849574`, liqPrice `0.010643`, equity `161.767095` 등). spot/staking도 전부
   Decimal(`spot.ts`/`staking.ts`), staking 시간연산은 ms 기간(머니 아님).
2. **C2 단일 Decimal 설정(money/trading/wallet 통합)** : `configure-decimal.ts`(precision 28,
   ROUND_HALF_UP) 단일 소스, 절단은 `toDecimalPlaces(_, ROUND_DOWN)`. game-engine만 예외(A4-1).
3. **클라이언트 권위 위반 0** : `trade.tsx`는 `computeOpenPosition`(`:450`)/`computeSpotBuy`
   (`:683`)를 **미리보기(useMemo) 표시용**으로만 쓰고, 제출은 원시 입력만 보낸다 —
   `submitOpen`은 `{margin, leverage, ...}`만(`:443`), spot `submit`은 `amount`만(`:692`).
   계산된 notional/quantity/payout을 권위로 보내지 않음 → **SQL RPC가 권위**. `casino.tsx`는
   `verifyRound`(검증)만. staking은 `estimateStakingReward`(명시적 추정 표시).
4. **wallet-ledger `reverse` 거부는 의도된 가드(데드코드 아님)** : `applyLedgerEntry`가
   in-memory `reverse`를 `RAISE`(`index.ts:149-154`) — 짝 없는 Σ=0 위반 방지. money 헬퍼 경유로
   float 미사용.

## 영역 4 데드/정리 후보 (낮음)

- TS `game-engine.settle()` · `quantize6`/`quantize6String` export는 앱 소비처 없음(grep:
  `apps`에서 0건) — 검증/테스트 스캐폴딩. C3류 정리 검토 후보(제거 아님, 비권위 명시 권장).

## 영역 4 미해결/리모트 확인 필요

- 없음(패키지는 로컬 소스로 완결). SQL 측 패리티 함수 정의의 로컬↔리모트 동일성은 영역 9.

---

**영역 4 종료. 영역 5(프론트엔드) 진행은 사용자 확인 후.**

---

# 영역 5 — 프론트엔드 (머니 표시 · i18n/hex · DB-driven · ConfirmDialog · 상태 4종)

**범위**: `apps/web`·`apps/admin` 전 라우트·컴포넌트(31 tsx). (1) 머니 표시(formatMoney/
tabular-nums vs raw·`Number().toLocaleString()`), (2) i18n/hex 하드코딩, (3) DB-driven 아닌
하드코딩(마켓·설정), (4) 고위험 액션 ConfirmDialog 누락, (5) loading/empty/error/success
4종 누락. admin 포함.

**검증 방식**: 정적 분석 + grep 전수(`Number(`/`toLocaleString`/`tabular-nums`/`formatMoney`/
hex/Hangul/`aria-label`/`ConfirmDialog`/`AdminActionDialog`) + 핵심 화면 정독.

## 요약

| ID | 심각도 | 한 줄 |
|----|--------|-------|
| A5-1 | **중간** | **출금(withdrawal)에 ConfirmDialog 누락** — `wallet.tsx` 출금 버튼이 즉시 실행(`:463`). 규칙 60(고위험 머니·출금 = 확인 필수). trade/staking/casino·admin은 확인 보유, 웹 출금만 누락 |
| A5-2 | 낮음 | 화면 **error 상태 누락**(loading/empty/success는 있으나 쿼리 에러→empty로 합쳐짐) — `ledger.tsx` 등 read-only 화면. 9.5 잔재 |
| A5-3 | 낮음(a11y) | 하드코딩 영어 a11y 라벨 — `aria-label="Loading"`(wallet/login/index/dashboard 4곳)·`"Admin navigation"`(admin-layout). i18n 미적용 |
| A5-4 | 낮음 | 룰렛 프라이즈 코드 하드코딩(`use-retention.ts:46-49`) — DB-driven 아님, `ROULETTE_LABELS`는 `'10 PHON'` 문자열(formatMoney/i18n 미경유). 실보상은 서버라 표시 드리프트 한정 |

> **긍정 확인(핵심)** : 머니 표시는 **formatMoney + tabular-nums 전면 적용**(틱 너비 안정),
> **Hangul JSX 리터럴 0건**(완전 i18n), 클라 권위 위반 0(영역 4). 골격 양호.

---

## A5-1 [중간] 출금 ConfirmDialog 누락 — 최고위험 머니 액션

**위치**: `apps/web/src/routes/wallet.tsx:460-466`(출금 버튼 → `handleWithdraw` 즉시),
`handleWithdraw`(`:271-296`).

**무엇** : 출금 버튼이 `onClick={() => void handleWithdraw()}`로 **확인 단계 없이 즉시**
`rpc_request_withdrawal`을 호출한다(`:280`). 대조적으로 선물/스팟(`trade.tsx`)·스테이킹
(`staking.tsx`)·카지노(`casino.tsx`)는 `ConfirmDialog`+`confirmOpen`을 거치고, admin 큐
(`queues.tsx`)·운영 킬스위치(`operations.tsx`)는 `AdminActionDialog`+reason을 거친다.

**왜 문제(중간)** : 출금은 **비가역 자금 이동**으로 플랫폼 최고위험 액션이다. 규칙
60-i18n-ux: "고위험 머니·트레이딩·스테이킹·베팅·**출금** 액션은 확인 UX 필수." 입금
(`handleDeposit`)은 요청 생성(자금 미이동)이라 낮으나, 출금은 즉시 잠금/차감 경로다.
오클릭·중복클릭 방지·금액 재확인 부재.

**참고** : KYC 게이트(`:469` `!kycVerified` 오버레이)·기능 일시정지 가드(`withdrawalPaused`)·
서버 멱등키(`:279`)는 있으나, 이는 인가/중복 방지일 뿐 **사용자 확인 UX가 아니다**.

**수정방향(제안만)** : 기존 `@phonara/ui`의 `ConfirmDialog`를 출금에 적용(금액·통화·수령처
요약 표시). 부차 관찰: `p_destination: {}`(`:283`)로 수령처가 빈 객체 — 의도(PHON 내부?)인지
영역별 확인 권장(이번 감사 범위 밖, 기록만).

---

## A5-2 [낮음] error 상태 미분리 (error → empty 혼동)

**위치**: `apps/web/src/routes/ledger.tsx:34,89-96`(`useLedger`가 `{entries, loading}`만 반환),
유사 패턴 read-only 화면.

**무엇** : `ledger.tsx`는 `loading`(스켈레톤)·`empty`(빈 상태)·`success`(테이블) 3종은 갖추나
**쿼리 에러 전용 상태가 없다**. 에러 시 `loading=false`+`entries=[]` → "내역 없음" empty-state로
표시돼 **장애를 빈 데이터로 오인**시킨다. 규칙상 상태 4종 권장.

**왜 문제(낮음)** : 데이터 손실/오동작은 아니나, 네트워크·RLS 거부 등 실패를 사용자가 "정상
빈 화면"으로 오해. 9.5 polish 잔재.

**수정방향(제안만)** : `useLedger`에 `error` 노출 + 화면에 error 상태(재시도 CTA) 추가.

---

## A5-3 [낮음 · a11y] 하드코딩 영어 a11y 라벨

**위치**: `aria-label="Loading"` — `wallet.tsx:338`, `login.tsx:45`, `index.tsx:27`,
`dashboard.tsx:53`. `aria-label="Admin navigation"` — `admin-layout.tsx:40`.

**무엇** : 스피너/내비 `aria-label`이 i18n 미경유 영어 리터럴. 화면 표시 문구는 전부 i18n
키인데 a11y 라벨만 누락 → 한국어 스크린리더 사용자에 영어 노출.

**왜 문제(낮음/a11y)** : 시각 사용자엔 무영향, 보조기술 사용자에 일관성 저하.

**수정방향(제안만)** : `aria-label={t('common.loading')}` 등 i18n 키화.

---

## A5-4 [낮음] 룰렛 프라이즈 하드코딩 (DB-driven 아님)

**위치**: `apps/web/src/hooks/use-retention.ts:46-49` — `ROULETTE_PRIZES = [10,...,1000]`,
`ROULETTE_LABELS = ['10 PHON', ...]`.

**무엇** : 룰렛 프라이즈 휠이 코드 상수다. `ROULETTE_LABELS`는 `'10 PHON'`처럼 **숫자+통화를
문자열로 박아** formatMoney/i18n을 경유하지 않는다(타일 목록은 `roulette-card.tsx:56`에서
`formatMoney` 사용 — 불일치). 실제 보상은 서버 RPC(`result.phon_awarded`)이므로 정합성 위험은
표시 드리프트(서버 프라이즈 변경 시 휠과 불일치)에 한정.

**왜 문제(낮음)** : B10(spot 마켓 DB화) 후 잔재. 머니 손실 아님.

**수정방향(제안만)** : 프라이즈를 DB/app_config 기반으로, 라벨은 `formatMoney` 경유. 또는
표시 한정임을 명시.

---

## 영역 5 긍정 확인

1. **머니 표시 건전** : `formatMoney` 16개 파일 전면 사용, 머니/수치에 `tabular-nums`
   (ledger 등) → 틱마다 너비 안정. **`Number().toLocaleString()` 머니 표시 0건**
   (`toLocaleString`은 전부 날짜). 클라 머니 계산은 Decimal 엔진(영역 4).
2. **i18n 완전** : 전 `.tsx`에서 **Hangul 리터럴 0건**. 사용자 문구 전부 i18n 키, 날짜는
   locale-aware `Intl.DateTimeFormat`(`ledger.tsx:30`). 잔여는 a11y 라벨 5개(A5-3)뿐.
3. **hex 하드코딩 = error-boundary 1파일뿐(의도된 예외)** : `error-boundary.tsx`는 테마 불가용
   상황(렌더 크래시) 폴백이라 인라인 색상 자족(텍스트는 `t('error.boundary.*')` i18n, DEV만
   console.error 게이팅). 그 외 전부 테마 토큰.
4. **ConfirmDialog/확인 UX** : trade/staking/casino `ConfirmDialog`, admin 큐(`queues.tsx`
   approve/reject 등 전 액션)·운영 킬스위치(`operations.tsx`) `AdminActionDialog`+**reason+감사**.
   유일 누락 = 웹 출금(A5-1).
5. **DB-driven** : `app_config`(`useAppConfig`), 마켓(`trade.tsx` `marketsLoading`→DB), 출금
   기능 플래그(`feature_withdrawal_enabled` DB 조회) 모두 DB. 하드코딩은 룰렛(A5-4)뿐.
6. **상태 커버리지** : `ledger`(loading/empty/success), `wallet`(busy/timeline/paused/KYC락),
   `casino`(authLoading 스켈레톤/errorKey/toast) 대체로 양호(error 분리만 일부 누락 A5-2).
7. **admin** : 킬스위치 confirm+reason+i18n+DB config, 큐/감사 i18n+날짜. a11y 라벨만 잔재(A5-3).

## 영역 5 미해결/리모트 확인 필요

- 없음(프론트는 로컬 소스로 완결).

---

**영역 5 종료. 영역 6(의존성/빌드) 진행은 사용자 확인 후.**

---

# 영역 6 — 의존성 / 빌드

**범위**: 루트+9개 워크스페이스 `package.json`, `tsconfig*`, `vite.config`, `.gitignore`,
knip 게이트(`check:deps`). (1) 미사용 의존성, (2) 선언↔구현 불일치, (3) 버전 핀(재현성),
(4) config 모순, (5) 빌드 잔여물. 예상대로 비교적 가벼운 영역.

**검증 방식**: 매니페스트 정독 + import grep 전수 + `git check-ignore`/`git ls-files`(추적 산출물)
+ `@phonara/ui` export↔컴포넌트 파일 1:1 대조.

## 요약

| ID | 심각도 | 한 줄 |
|----|--------|-------|
| A6-1 | 낮음(재현성) | `@phonara/ui` devDeps `"typescript": "latest"` · `"vitest": "latest"` — 버전 핀 위반(비재현). 타 패키지는 정확/caret |
| A6-2 | 낮음(재현성) | 워크스페이스 버전 드리프트 — **admin `zod 3.25.67` vs web `zod 4.4.3`(메이저)**, react-query 5.80.7 vs 5.101.0, tailwind 4.1.10 vs 4.3.0 |
| A6-3 | 낮음 | 미사용 루트 의존성 `framer-motion`·`lucide-react`(import 0건) — `check:deps`가 `--workspace "@phonara/*"` 스코프라 **루트 deps 미검사**로 잔존 |

> **긍정 확인** : 선언↔구현 1:1(ui 27 export = 27 컴포넌트, Sheet 포함), 추적 빌드 잔여물 0,
> .gitignore 커버 정상. 가벼운 영역 — 결함 모두 낮음(재현성/위생).

---

## A6-1 [낮음 · 재현성] `@phonara/ui` devDeps가 `latest`

**위치**: `packages/ui/package.json:34-35` — `"typescript": "latest"`, `"vitest": "latest"`.

**무엇** : 두 devDep이 `latest`로 부동. 루트는 `typescript ^6.0.3`/`vitest ^4.1.8`, 앱은 정확 핀
(`typescript 6.0.3`). ui만 `latest`라 **재설치 시점에 따라 메이저가 바뀔 수 있다**(현재
`bun.lock`이 고정하나, 락 갱신/clean install 시 드리프트).

**왜 문제(낮음)** : 빌드 재현성 저하. 70-autonomy "version pin" 권고 위반.

**수정방향(제안만)** : 루트와 동일 버전으로 핀(`^6.0.3`/`^4.1.8`) 또는 루트 devDep 상속.

---

## A6-2 [낮음 · 재현성] 워크스페이스 간 버전 드리프트

**위치**: `apps/web/package.json` vs `apps/admin/package.json`.

**무엇** :
```
zod:                 web 4.4.3      vs  admin 3.25.67   ← 메이저 다름(3 vs 4)
@tanstack/react-query web 5.101.0   vs  admin 5.80.7
@tailwindcss/vite     web 4.3.0     vs  admin 4.1.10
tailwindcss           web 4.3.0     vs  admin 4.1.10
```

**왜 문제(낮음)** : 각 앱이 자체 번들이라 런타임 충돌은 아니나, 동일 의존의 다중 버전은
유지보수/재현성 부담이다. 특히 **zod 메이저 분기(3↔4)**는 스키마 API 표면이 달라 공통 패턴
공유 시 혼란. 보안 패치 적용도 두 번 해야 한다.

**수정방향(제안만)** : 버전 정렬(zod 4로 통일 권장), 가능하면 공통 deps를 루트로 호이스팅.

---

## A6-3 [낮음] 미사용 루트 의존성 (knip 스코프 사각)

**위치**: 루트 `package.json:65-66` — `"framer-motion": "^12.40.0"`, `"lucide-react": "^1.17.0"`.

**무엇(grep 확인)** : 두 패키지는 전 `.ts/.tsx`에서 **import 0건**(`framer-motion|lucide-react`
매치 없음). 루트 `dependencies`에만 선언돼 있다.

**왜 미검출되었나** : `check:deps`가 `knip --dependencies --workspace "@phonara/*"`로 **@phonara
워크스페이스만** 검사한다(루트 패키지 제외). 그래서 루트 deps의 미사용분은 D1 게이트를
빠져나간다.

**왜 문제(낮음)** : 설치 용량/공급망 표면 불필요 증가. 위생 항목.

**수정방향(제안만)** : 루트 `dependencies`에서 두 패키지 제거, 또는 `check:deps`에 루트
패키지(`.`)도 포함해 게이트 사각 해소.

---

## 영역 6 긍정 확인

1. **선언↔구현 1:1(0.7 Sheet류 불일치 없음)** : `@phonara/ui/src/index.ts` 27개 컴포넌트
   export ↔ `components/*.tsx` **27개 파일 정확 일치**(`sheet.tsx` 포함 — 선언+구현 양쪽 존재).
   팬텀 export(선언했는데 미구현)·고아 컴포넌트(구현했는데 미export) 0. typecheck/build 게이트가
   강제.
2. **추적 빌드 잔여물 0** : `git ls-files`로 `*dist/*`·`*.tsbuildinfo`·`node_modules/**`·
   `*.exe`·`*.bunx` 추적 0건. `.gitignore`가 `dist`/`.vite`/`node_modules`/`build`/`coverage`/
   `*.tsbuildinfo`/`.env`/E2E 인증 토큰 커버(`git check-ignore` 확인). 워킹트리 on-disk 산출물
   (시작 git status의 `??`)은 **gitignore됨**(커밋 안 됨) — `bun run clean:artifacts` 대상.
3. **버전 핀 대부분 건전** : 앱 deps 정확 핀(`@supabase 2.108.0` 등), 워크스페이스 내부
   `workspace:*`, 루트는 caret+`bun.lock`로 재현. 예외는 A6-1(ui latest)·A6-2(드리프트)뿐.
4. **config 정합** : 앱별 독립 `vite.config`/`tsconfig`, `tsconfig.base.json` paths가
   `@phonara/*`→`src`(typecheck), 런타임은 `exports`→`dist`(85-architecture 규칙대로). `check`
   체인(env/i18n/release/advisors/deps/typecheck/lint/test/build)이 단일 게이트로 묶임 — 모순
   없음.

## 영역 6 미해결/리모트 확인 필요

- 없음(로컬 매니페스트로 완결). `knip` 전체 실행(미사용 export/파일까지)은 영역 7(테스트)·
  코드 정리 시 보강 가능하나 본 영역 의존성 판정엔 grep로 충분.

---

**영역 6 종료.**

---

# 영역 7 — 테스트 진정성 (Test Authenticity)

> 목적: "테스트 green"이라는 모든 신뢰의 근거 자체를 검증. **가짜 RED**(통과하지만 방어
> 안 됨)·**실경로 vs 테스트경로 괴리**·절대값 assert·conservation 누락·커버리지 구멍·
> teardown 잔여를 전수. 핵심 검증법으로 **방어 코드를 (롤백 트랜잭션 안에서) 임시 제거 →
> 테스트가 진짜 RED가 되는가**를 실측했다. 읽기 전용·수정 0·전 실험 ROLLBACK.

## 영역 7 요약 표

| ID | 심각도 | 무엇 | 비고 |
|----|--------|------|------|
| **A7-1** | **배선 결함**(=A4-3 재확인) | **parity_hold 테스트가 실유저가 안 보내는 `p_expected_result`로만 트리거** — 코드로 확정 | 영역 8 입력 |
| **A7-2** | 낮음 | SQL `oi_cap_race`/`settlement_race`는 **단일 세션**(소스 텍스트 grep + 순차) — SQL층은 동시성 미검증 | OI 진짜 동시성은 **E2E가 커버**(완화). 청산-vs-마감 동시성은 상태게이트 의존 |
| **A7-3** | 낮음 | `solvency_reconciliation` Test5/6이 **고아 `_assert_withdrawal_gate`(prod 호출 0)** 테스트 | 권위 게이트는 `phase5_gates`가 커버 → 죽은-테스트(A1-4/A2-6과 함께 삭제) |
| **A7-4** | 낮음 | `reward_conservation` Test2(추천) — **절대값(2000/6000) assert + Σ=0 미단언** | 추천 민트 leg 보존 미검증 |
| **A7-5** | 낮음~중간 | **E2E가 테스트 유저 생성 후 teardown 0**(`afterAll`/`deleteUser` 없음) — 영속 잔여 | 이전 `db reset` 실패 원인 후보. SQL은 전부 ROLLBACK(청결) |

## ★ 핵심 성과 — 머니 보존 테스트는 진짜 RED (실험으로 증명)

사용자 요청대로 "방어 제거 → RED" 실험을 **롤백 트랜잭션 안에서** 실행했다(잔여 0):

- **대상** : `reward_conservation_test.sql`의 핵심 단언
  `ASSERT v_grand_after = v_grand_before`(Σ wallets + Σ system_accounts, PHON).
- **방법** : 민트 분류기 `_is_reward_issuance_reason(text)`를 `SELECT false`로 임시 교체
  (= 보상 적립 시 `reward_issuance` 상쇄 차변 leg 제거 = "방어 제거") → `rpc_claim_welcome_bonus()` 실행.
- **결과(런타임 실측)** :
  - 대조군(방어 정상) : `grand_total delta = 0.000000` → **보존 성립**.
  - 실험군(민트 leg 제거) : `grand_total delta = 5000.000000` → **보존 붕괴**(웰컴 5000 PHON이
    상쇄 없이 순증). 즉 보존 단언이 **정확히 RED가 됨**.
- **결론** : 이 테스트는 **가짜 RED가 아니다**. 머니 누수(상쇄 leg 누락)를 실제로 잡는다.
  검증법이 작동함을 실증했고, 보존 테스트 패밀리(conservation/settlement_race/reward) 신뢰가
  경험적으로 확인됐다. (전 과정 ROLLBACK, 임시 SQL 파일 삭제 — 잔여 0.)

## A7-1 (배선 결함) parity_hold = 테스트 전용 인자로만 트리거 — 실유저 경로 휴면

**위치** : `supabase/tests/casino_schema_test.sql:264-272`(Test 5) · `supabase/tests/casino_parity_test.sql`
· 실경로 `apps/web/src/routes/casino.tsx`(`rpc_place_game_bet` 호출부, `p_expected_result` 미전송).

**무엇(코드 인용)** : parity_hold를 트리거하는 유일한 입력이 `rpc_place_game_bet`의 **6번째 인자**다.

```264:272:supabase/tests/casino_schema_test.sql
  v_bet := rpc_place_game_bet(
    v_round_id, 'PHON', '10.000000',
    '{"target":"50.00","direction":"over"}'::JSONB,
    'cs', 'parity_idem_' || v_uid::TEXT,
    '{"roll":0,"won":false}'::JSONB        -- ← p_expected_result: 테스트만 주입
  );
  ASSERT v_bet->>'status' = 'parity_hold', 'parity mismatch must return parity_hold';
```

**왜 문제** : 테스트는 `p_expected_result`에 일부러 틀린 결과를 넣어 SQL parity 체크를 깨우고
"CASINO PARITY HOLD OK"로 통과한다. 그러나 **실 웹 클라(`casino.tsx`)는 이 인자를 보내지 않는다**
→ 실유저 베팅 경로에서 parity 비교 분기가 스킵 → ADR-001의 "parity mismatch auto-kill" 안전망이
**프로덕션에서 휴면**. 출금 escrow 사건과 동류의 "있다고 믿은 안전망이 실배선 안 됨".

**근거** : 영역 4/5에서 정적·런타임 확인된 A4-3과 동일 사실을 **테스트 코드 레벨에서 재확정**.
근인은 카지노 RNG 도메인 불일치(SQL `NUMERIC[]` vs TS double)라 "동일 산술"이 아니라 "테스트
벡터"로만 패리티를 보장.

**심각도** : 배선 결함(영역 8 최우선 정밀 — 목록 ④). **수정방향(제안만)** : (a) SQL float double 통일로
근본원인 제거(선호) 후 실경로 parity 상시 검증, (b) 도메인 불일치 채 안전망만 켜면 양성 오탐↑.

## A7-2 (낮음) "race" SQL 테스트는 단일 세션 — SQL층 동시성 미검증

**위치** : `supabase/tests/oi_cap_race_test.sql:20-31` · `supabase/tests/settlement_race_test.sql`(전체).

**무엇(코드 인용)** : OI race 테스트의 "lock" 단언은 **함수 소스 텍스트 grep**이다.

```20:31:supabase/tests/oi_cap_race_test.sql
  ASSERT position(
    'pg_advisory_xact_lock'
    IN pg_get_functiondef('public._assert_position_limits(uuid,text,numeric)'::regprocedure)
  ) > 0, '_assert_position_limits must take an advisory transaction lock';
  ASSERT EXISTS ( ... AND p.provolatile = 'v' ),
    '_assert_position_limits must be VOLATILE because advisory locks are side effects';
```

이어지는 베팅도 **순차 2회 open**으로 OI cap을 친다(동시성 아님). 파일 주석도 명시:
"The local SQL runner executes one backend per file, so this file anchors the concurrency
invariant in pg_get_functiondef/provolatile". `settlement_race_test`도 close→sweep를 **한 세션에서
순차** 실행(진짜 동시 트랜잭션 경합 아님).

**왜 문제** : SQL층만 보면 "lock이 존재함"(텍스트)·"순차 cap이 막힘"만 증명하고 **lock이 동시성
하에서 실제로 이중 발행을 막는지**는 미검증. 사용자가 지적한 "lock 존재만 증명" 패턴.

**완화(긍정)** : **진짜 OI 동시성은 E2E가 커버**한다 — `tests/e2e/group-d-hardening.spec.ts:210-232`이
`Promise.all`로 두 open을 **병렬** 호출하고 "정확히 1건 성공/1건 거부 + Σ 보존(delta)"을 단언.

```210:232:tests/e2e/group-d-hardening.spec.ts
    return Promise.all([
      sb.rpc('rpc_open_futures_position', { ...base, p_client_request_id: `race-a-${stamp}` }),
      sb.rpc('rpc_open_futures_position', { ...base, p_client_request_id: `race-b-${stamp + 1}` }),
    ]);
  ...
  expect(successes.length, ...).toBe(1);
  expect(after.USDT, 'OI race conserves USDT Σ').toBe(before.USDT);
```

**잔여 구멍** : 마감-vs-자동청산의 **진짜 동시** 경합은 병렬 테스트가 없다(상태게이트
`status<>'open'` 멱등성에 의존, 순차로만 검증). **수정방향** : SQL "race" 테스트명을
"lock invariant anchor"로 정정하거나, 청산-마감 병렬 E2E 추가.

## A7-3 (낮음) 솔벤시 테스트 일부가 고아(死) 게이트를 검증 — 이중 커버 착시

**위치** : `supabase/tests/solvency_reconciliation_test.sql:167,205`(Test 5/6) — `_assert_withdrawal_gate(currency,text)`.

**무엇** : Test 5/6은 `_assert_withdrawal_gate`(2-arg)를 호출하지만, 이 함수는
`20260609000026`에 **정의만 있고 마이그레이션 호출자 0**(grep: 정의+REVOKE 외 무참조). 실 출금
경로 `rpc_request_withdrawal`은 **권위 게이트 `_assert_solvency_withdrawal_gate`(1-arg)**를 호출
(영역 2 확인). 즉 Test 5/6은 **prod에서 안 쓰이는 죽은 함수**를 검증한다.

**왜 문제** : "솔벤시가 이중으로 커버됨"이라는 착시. 의미도 다름(고아=`real ≥ user×(1+buffer)`,
권위=fresh-recon + attested 비교). 권위 게이트는 별도로 `phase5_gates_test.sql:286/327/363`이
block(stale)·block(부족)·pass 3분기 모두 정상 커버.

**심각도** : 낮음(권위 경로는 커버됨). **수정방향** : A1-4/A2-6 정리 시 고아 함수 + Test 5/6 동시 삭제.

## A7-4 (낮음) 추천 보상 테스트 — 절대값 assert + Σ=0 미단언

**위치** : `supabase/tests/reward_conservation_test.sql:104-105`.

**무엇(코드 인용)** :

```104:105:supabase/tests/reward_conservation_test.sql
  ASSERT v_referrer_phon = 2000, format('referrer should get 2000 PHON, got %s', v_referrer_phon);
  ASSERT v_referred_phon = 6000, format('referred should get 6000 PHON, got %s', v_referred_phon);
```

**왜 문제** : (1) **절대값 단언**(2000/6000) — 보상 금액 config가 바뀌면 깨짐(테스트가 값에 고착).
(2) Test 1(웰컴/데일리/룰렛)은 grand-total Σ=0를 단언하나 **Test 2(추천)는 보존 단언이 없다** —
추천 보너스의 민트 상쇄 leg가 보존되는지 미검증. **수정방향** : 추천 경로에도 grand-total
before==after 단언 추가, 금액은 config 조회로 비교(절대 리터럴 지양).

## A7-5 (낮음~중간) E2E teardown 부재 — 영속 테스트 유저 잔여

**위치** : `tests/e2e/group-d-hardening.spec.ts:35` · `casino.spec.ts:85` · `funnel.spec.ts:80` ·
`global-setup.ts:33,129`(모두 `admin.auth.admin.createUser`).

**무엇(grep 확인)** : E2E가 `auth.users`(+ 자동 생성 profiles/wallets/positions)를 만들지만
**`afterAll`/`afterEach`/`deleteUser`/cleanup이 전무**(매치 0). SQL 테스트는 전부 `BEGIN…ROLLBACK`
이라 잔여 0이지만, E2E는 실행마다 테스트 유저가 **누적**된다.

**왜 문제** : 40-testing/10-quality-gates "영속 테스트 계정/잔여 금지" 위반. 이전 `db reset` 실패의
유력 원인(누적 잔여 + FK). **수정방향** : E2E에 `test.afterAll`로 생성 유저
`admin.auth.admin.deleteUser` 정리, 또는 스위트 시작 시 네임스페이스 prune.

## 영역 7 긍정 확인 (핵심 — 신뢰 근거 검증됨)

1. **보존 테스트 = 진짜 RED(실측)** : 위 실험으로 민트 leg 제거 시 Σ가 +5000 어긋나 단언이
   RED 됨을 증명. conservation/settlement_race/reward 전부 **delta·before==after** 방식(절대잔액
   고착 아님) + `verify_ledger_hash_chain` 동반 + ROLLBACK.
2. **실 RPC 경로 사용** : conservation/settlement/withdrawal/reward 테스트가 `rpc_spot_*`,
   `rpc_open/close_futures_position`, `rpc_request/approve/reject/mark_withdrawal_*`,
   `rpc_claim_*` 등 **실유저/실관리자가 부르는 그대로** 호출(parity_hold만 예외 = A7-1).
3. **출금 P0 풀커버(사용자 우려 해소)** : `phase5_withdrawal_test.sql`가 request(lock)·reject(환불·
   상태·Σ보존·audit)·approve(payout 시스템 leg·Σ보존·audit)·mark_sent·KYC·kill-switch·GRANT
   순서를 **실 관리자 RPC**로 모두 검증.
4. **sanctions 6면 + 권위 솔벤시 3분기** : `phase5_gates_test.sql`가 sanctions hit/pending를
   spot/futures/staking/game/withdraw/deposit **6 표면** + 권위 솔벤시 게이트 block/block/pass.
5. **멱등성 다층 커버** : `hardening`(요청 멱등 A4f), `casino_schema`(user+key 스코프),
   `phase5_deposit`(중복 transfer id), `mission`(트리거 중복 무발행).
6. **E2E 머니 단언 = delta/보존(절대잔액 아님)** : `core-flow`/`group-d-hardening`이
   `after.USDT==before.USDT`·`delta.toBe('12.000000')` 식 — 절대 잔액 고착 위반 없음. OI race는
   진짜 병렬.
7. **모든 SQL 테스트가 게이트에 배선** : `scripts/run-sql-tests.ts`가 `supabase/tests/*.sql`
   **전 파일**을 실행(psql/docker fallback), 각 파일 ROLLBACK → 오펀 테스트·잔여 0.

## 영역 7 미해결/영역 8 입력

- **A7-1(parity_hold)** → 영역 8 최우선: Wave 2 Build Log의 "parity_hold 동작 증명"이 테스트
  `p_expected_result` 주입에 의존했음이 코드로 확정. 설계 의도(전수 검증 vs 테스트만) 판정 +
  근본수정(도메인 통일) 필요.
- A7-2 청산-마감 진짜 동시성, A7-5 E2E teardown은 "출시 전 정리"로.

---

**영역 7 종료.**

---

# 영역 8 — 불변식/ADR 일치 (실경로 작동 검증)

> 클라이맥스. 패턴(parity_hold): "있다고 믿는 안전망이 **실유저 경로에서 휴면**". 이를 모든
> 핵심 불변식에 적용 — 테스트가 아니라 **실유저/실관리자 경로 + 라이브 함수 본문**에서 진짜
> 작동하는가를 런타임으로 확정. 읽기 전용·수정 0·전 실험 ROLLBACK.

## ★ 영역 8 결론 — 핵심 안전망은 실경로에 **살아 있음**, 휴면은 2겹뿐

런타임 실측으로 **킬스위치·솔벤시 차단·Σ=0 기록면**이 실경로에 실배선됨을 확인했다. "출금 escrow"
류의 휴면은 **(a) parity_hold 벨트**(설계상 조건부)와 **(b) hash-chain 자동검증**(수동/테스트만)
**2겹으로 한정**된다. 1차 머니 방어선(킬스위치·솔벤시·보존)은 휴면이 아니다.

| 불변식 | 실경로 배선 | 판정 | 근거 |
|--------|-------------|------|------|
| **킬스위치** | 머니 RPC 10종 라이브 본문에 `_assert_feature_enabled`+`_assert_system_live` | ✅ 실작동 | 런타임 `pg_get_functiondef` 10/10 t |
| **솔벤시 게이트** | 실 출금이 권위 게이트 호출 + `real_balance≤0` **fail-closed** | ✅ 실작동 | 000035:163, 000033:426 |
| **Σ=0 기록면** | 보존 단언이 진짜 RED(영역 7 실측 +5000) | ✅ 실작동 | 영역 7 실험 |
| **ADR-002~007** | SQL 정산·edge워커 없음·하우스/보험 분리·노출캡·6게임 | ✅ 구현됨 | ADR-0002 ↔ 코드 |
| **parity_hold 벨트** | 웹이 `p_expected_result` 미전송 → 서버 auto-kill 휴면 | ⚠️ 휴면(설계상 조건부) | A8-1 |
| **hash-chain 자동검증** | 크론/RPC 0건 호출 — 수동 RUNBOOK/테스트만 | ⚠️ 휴면 | A8-2 |
| **정산 크론 범위** | 유저지갑만 — 시스템계정/전체 Σ=0/hash-chain 제외 | ⚠️ 사각 | A8-3(=A2-3) |

## A8-1 (④ 배선 결함) parity_hold 정밀 — 설계상 조건부, 웹 전 게임 휴면

**설계 의도 확정(ADR 원문)** : `docs/ADR/0002-casino-settlement.md:17` —
> "ADR-001: ... **If parity input is supplied** and mismatches SQL, the bet enters `parity_hold` ...
> **TypeScript remains the ... verification path.**"

즉 ADR-001의 설계는 "**모든 베팅이 parity 검증**"이 아니라 "**parity 입력이 주어지면**" 조건부 발동
이며, PF 검증의 1차 경로는 **클라 `verifyRound`(공개 후 재계산)**다. parity_hold는 클라가
expected_result를 보낼 때만 켜지는 **선택적 서버 벨트**다.

**실경로 배선(코드 인용)** : 웹은 베팅 시 expected_result를 안 보내고, 공개 후 클라에서 검증만 한다.

```322:339:apps/web/src/routes/casino.tsx
      const placed = await callRpc('rpc_place_game_bet', {
        p_round_id: commitment.round_id,
        p_currency: currency, p_stake: stake,
        p_selection: selection as Json, p_client_seed: clientSeed,
        p_idempotency_key: `casino:${crypto.randomUUID()}`,   // ← p_expected_result 없음
      }) as unknown as BetResponse;
      const revealed = await callRpc('rpc_reveal_game_round', { p_round_id: commitment.round_id }) ...;
      const verified = await verifyRound({ ... expectedResult: placed.result });  // 클라 PF 재계산
```

**범위** : `rpc_place_game_bet`는 **단일 호출부**(casino.tsx:322)로 카지노 **6종 one-shot 전부**가 이
경로다 → 6종 모두 서버 auto-kill 휴면. roulette(`rpc_spin_roulette`)은 PF parity 게임이 아니라 **별도
보상 발행 경로**라 해당 없음.

**실작동 판정** : PF 무결성 1차(SQL 권위 + 클라 `verifyRound` 증명 표시)는 **실배선**.
SQL↔TS 불일치가 나면 유저 화면엔 "검증 실패"가 뜨나(`setVerification`), **서버 auto-kill/게임
비활성/ops 알림은 발동 안 함** = 벨트 휴면. 따라서 "PF 붕괴"가 아니라 **방어심층 1겹 휴면**.

**수정방향(ADR 의도 정합, 제안만)** : (a) **SQL float double 통일로 RNG 도메인 일치**(SQL `NUMERIC[]`
↔ TS double) → parity가 "동일 산술"이 되어 **벨트를 상시(무조건) 켜도 양성오탐 0**. ADR-001이 말한
"TS=verification, SQL=authority"의 진짜 동치 달성 → **근본 수정·선호**. (b) 도메인 불일치 채 클라가
expected_result만 보내 벨트 활성 → 부동소수 미세차로 **양성 오탐 auto-kill 위험**. 게임엔진 머니
경로라 (a) + 강한 모델 + 패리티 테스트 必.

## A8-2 (E 선결 토대 + ④) hash-chain 자동검증 휴면 — "있는데 안 켜짐"

**무엇(런타임 확정)** : 라이브 크론 **3개**(`cron.job`) 중 **누구도** `verify_ledger_hash_chain`을
호출하지 않는다.

```
phonara_auto_liquidations            | * * * * * | SELECT public._run_liquidations_logged();
phonara_casino_stale_pending_sweep   | */5 * * * *| SELECT public.rpc_sweep_stale_game_bets();
phonara_daily_reconciliation         | 0 2 * * *  | SELECT public.rpc_run_reconciliation();
```

`verify_ledger_hash_chain`은 (1) 행 기록(트리거 `_wl_compute_hash`)·(2) **수동 RUNBOOK**
(`docs/RUNBOOK.md:44,56,218` — halt 발동 조건)·(3) SQL 테스트에서만 호출. **자동 주기 검증 0**.

**왜 문제** : RUNBOOK은 hash-chain 비0 결과를 **halt 발동 조건**으로 명시하나, 그걸 **자동으로
돌리는 주체가 없다** — 운영자가 수동 실행할 때만 작동. 일일 정산은 hash-chain을 **안 본다**(아래
A8-3). 즉 원장 행 변조(합계 보존되게 조작)는 자동 탐지망을 빠져나간다. 출금 escrow와 동류의
"있는데 안 켜진" 탐지층.

**완화(긍정)** : `wallet_ledger`는 append-only RULE(UPDATE/DELETE 차단) + RLS라 변조엔 권한 상승
필요 → 실익 낮음. 그러나 **탐지층 자체가 휴면**.

**E 영향(핵심)** : E 보험기금 원장 `system_account_ledger`는 **append-only RULE도 없고(A1-1)
hash-chain도 없고 자동검증도 없다** → 셋 다 없는 가장 무방비 원장. E가 이 위에 쌓이면 위험.
→ **E 선결 토대**.

**수정방향(제안만)** : `rpc_run_reconciliation`에 `verify_ledger_hash_chain` 호출 추가(비0 →
readonly/halt)하거나 전용 hash-chain 검증 크론 신설. E 착수 전 `system_account_ledger`에 append-only
+ (가능하면) hash-chain 토대 마련.

## A8-3 (E 선결 토대, =A2-3 재확인) 일일 정산 범위 사각

**무엇(코드 확정)** : `rpc_run_reconciliation`(000026:200-290, 일일 02:00 크론)은 통화별
**유저 지갑 합 vs `wallet_ledger` 순액**만 비교한다. **제외**: `system_accounts`/
`system_account_ledger`(하우스·보험·민트), **전체 Σ=0**(지갑+시스템), **hash-chain**.

```241:246:supabase/migrations/20260609000026_s1_solvency_reconciliation.sql
    v_delta    := v_wallet_sum - v_ledger_net;
    v_is_match := ABS(v_delta) <= v_tolerance;
    IF NOT v_is_match THEN v_any_mismatch := TRUE; END IF;
```

**왜 문제** : 보험기금/하우스 계정의 이동은 **자동 정산의 사각**. 균형 잡힌 시스템계정 변조나
시스템 leg 누락은 일일 크론이 못 잡는다. E(보험기금)는 시스템계정 이동이 본업이라 직격.
→ **E 선결 토대**(A2-3과 동일, 런타임 크론·함수로 재확정).

**수정방향(제안만)** : 정산에 시스템계정 보존(전체 Σ=0) + hash-chain 검증 추가(A8-2와 한 묶음).

## 영역 8 긍정 확인 (실경로 실작동 — 런타임 증명)

1. **킬스위치 = 실작동(휴면 아님)** : 머니 RPC 10종(`spot_buy/sell`, `open/close_futures`,
   `stake/unstake/claim_staking`, `spin_roulette`, `place_game_bet`, `register_referral`)
   **라이브 본문 전수에 `_assert_feature_enabled` + `_assert_system_live` 존재**(런타임
   `pg_get_functiondef` 10/10 = t). spot/futures는 000019 텍스트 주입이 **후속 마이그레이션에
   덮이지 않고 생존**(마지막 정의 000009 < 000019). parity_hold와 달리 **휴면 아님**.
2. **솔벤시 게이트 = 실경로 + fail-closed** : 실 출금 `rpc_request_withdrawal`이
   `_assert_solvency_withdrawal_gate(v_ccy)` 호출(000035:163). 권위 게이트는 `real_balance≤0`에
   **`withdrawal_solvency_hold`(treasury_unconfigured)로 차단**(000033:426-428) — "real_balance=0
   스킵" 위험은 **죽은 고아 `_assert_withdrawal_gate`에만** 남음(실경로 아님). 000033이 메웠다.
   가드 순서도 정상: system_live→feature(킬)→KYC→sanctions→solvency.
3. **Σ=0 기록면 진짜 작동** : 영역 7에서 민트 leg 제거 시 +5000 어긋남 실측 → 보존 단언이
   실제 누수를 잡음. 출금 approve/reject·정산도 보존 테스트(delta)로 커버.
4. **ADR-002~007 구현·유지** : ADR-002(라운드당 1베팅 Phase4)·ADR-003(6 one-shot)·**ADR-004(Edge
   정산 워커 없음 — 크론 3개에 카지노 정산 워커 부재 확인)**·**ADR-005(`game_house_*` 카운터파티,
   보험 분리, 솔벤시는 per-bet 아닌 출금 게이트)**·ADR-006(`_assert_game_exposure_cap`,
   casino_schema Test4 커버)·ADR-007(real user 0 → Wave 12 배치). 모두 코드 일치.
5. **ADR-001 SQL 권위 + 클라 verifyRound** : SQL이 정산 권위, 클라가 공개 후 재계산 증명 표시 —
   ADR 의도대로 실배선(휴면은 A8-1 벨트 한 겹뿐).

## 영역 8 분류 결과

- **④ ADR 배선 결함** : **A8-1**(parity_hold 벨트 휴면 — 최상단, =A4-3/A7-1) + **A8-2**(hash-chain
  자동검증 휴면).
- **E 선결 토대** : **A8-2**(E 보험기금 원장 무방비 — append-only/hash-chain/자동검증 3무) +
  **A8-3**(정산 시스템계정 사각, =A2-3).
- 그 외 핵심 불변식은 **실경로 실작동 확인**(휴면 아님) — 클라이맥스 안심 결론.

## 영역 8 미해결/리모트 확인 필요

- 라이브 함수 본문·크론은 **로컬 런타임으로 확정**. 리모트가 동일 정의인지(킬스위치 주입
  생존·크론 3개)는 **영역 9 리모트 실측**에서 대조 필요(MCP 재시작 후).

---

**영역 8 종료.**

---

# 영역 9 — 로컬↔리모트 / 마이그레이션 drift (CLI 실측, 2026-06-11)

> MCP 없이 수행. 명령: `supabase migration list --linked`, `supabase db query --linked`,
> `.env` PAT + `bun run check:advisors`. 로컬 DB는 Docker 미기동(54322 거부) — 로컬
> 런타임 카운트는 영역 3·7·8의 `supabase db reset` 결과에 의존.

## 9.1 마이그레이션 히스토리 (핵심 drift)

| 구분 | 최신 버전 | 개수 |
|------|-----------|------|
| **리모트** (`schema_migrations`) | `20260609000024` | **24** |
| **로컬** (`supabase/migrations/`) | `20260609000044` | **44** |
| **미적용(로컬 전용)** | `000025`–`000044` | **20건** |

`supabase migration list --linked` : `000001`–`000024`는 Local=Remote 일치, `000025`–`000044`는
Remote 열 **공백**.

**판정 (A9-1)** : 의도된 Wave 12 pre-push 상태이나 **드리프트 규모가 큼**. 리모트는 Phase 1~P0
admin-audit(000024)에서 멈춤; 로컬은 S1(출금·KYC·솔벤시)·S2·S3(카지노)·S4·Stage2(캔들·마켓)·
000044 hardening까지 앞서 있음. **E/출금/카지노/Stage2 UI는 리모트 DB에 존재하지 않음.**

### 미적용 20건 기능 묶음 (파일명 기준)

| 구간 | 마이그레이션 | 주요 내용 |
|------|-------------|-----------|
| S1 | 000025–000027, 000033–000037 | 미션 seal, 일일 정산·솔벤시, 멀티소스 오라클, 입출금·출금 kill/lock, admin queue, KYC |
| S2–S4 | 000028–000032, 000030–000031 | 카지노 스키마·원자 정산·game_rounds, live hardening, security triggers |
| Stage 2 | 000038–000043 | market metadata/sources, risk limits, candles, synthetic book, push subs |
| Hardening | 000044 | cron 3종 재등록, treasury grant, SQL hardening |

## 9.2 리모트 객체 존재 실측 (A9-2)

`supabase db query --linked` (`to_regclass` / `pg_proc`):

| 객체 | 리모트 | 로컬(000044 적용 시, 마이그레이션 기준) |
|------|--------|----------------------------------------|
| `treasury_reserves` | **없음** | 000026 |
| `game_rounds` / casino | **없음** | 000028–000029 |
| `market_sources` / candles RPC | **없음** | 000038–000042 |
| `push_subscriptions` | **없음** | 000043 |
| `rpc_request_withdrawal` 등 S1 RPC | **없음** | 000033–000035 |
| `rpc_get_candles` | **없음** | 000040 |

**판정** : 영역 8에서 로컬 런타임으로 확인한 크론 3종·킬스위치·솔벤시 게이트·카지노 정산은
**리모트에 미배포**. 프로덕션(리모트)은 **자동청산 1크론 + 000024 스키마** 수준.

## 9.3 pg_cron drift (A9-3)

| | 리모트 `cron.job` | 로컬(000044) |
|--|-------------------|--------------|
| 개수 | **1** | **3** |
| 이름 | `phonara_auto_liquidations` only | + `phonara_daily_reconciliation`, `phonara_casino_stale_pending_sweep` |

리모트에 `rpc_run_reconciliation` / `rpc_sweep_stale_game_bets` 부재와 일치(000026/000029
미적용). **A8-2/A8-3 휴면·사각은 리모트에서 더 심함**(정산 크론 자체 없음).

## 9.4 `auth_rls_initplan` 실측 (A9-4, = A3-2 해소)

리모트 `pg_policies` bare `auth.uid()` 카운트: **20** — `check:advisors` WARN
`auth_rls_initplan` **20건과 일치**. 영역 3 로컬 **31**과의 차 **+11**은 unpushed
`000025`–`000044`의 신규 RLS 정책으로 설명 가능(로컬 DB 미기동으로 이번 패스 재카운트 불가,
마이그레이션 SQL 정적 분석과 부합).

**판정** : advisor 숫자 vs 리모트 실측 **정합**. launch blocker 아님; push 후 로컬+리모트
합산 치환 필요.

## 9.5 리모트 advisor 게이트 (A9-5)

`bun run check:advisors` (PAT, project `yocjhjsdwoijfdrehzoq`):

- **0 ERROR** (000024 리모트 기준 green)
- **46 WARN** : `authenticated_security_definer_function_executable` 20,
  `auth_rls_initplan` 20, `multiple_permissive_policies` 6
- **51 INFO** : `unused_index` **37**, `unindexed_foreign_keys` **14**

스크립트 scope note와 동일: **000025–000044 미검증** — Wave 12 post-push에 0 ERROR 재확인 필수.

## 9.6 운영 메모

- **`bun run check:advisors`는 `.env`를 자동 로드하지 않음** — CI/PAT 셸 주입 또는 수동
  env 필요(이번 실측은 PowerShell에서 `.env` 로드 후 실행).
- **MCP `Loading tools`** : PHONARA 감사·advisor·drift에는 **차단 아님** — CLI로 대체 가능.
- **로컬 Supabase 미기동** : `supabase db query --local` 실패(54322). 로컬↔리모트 live diff는
  `supabase start` + reset 후 `db diff --linked`로 추가 가능(이번 패스 생략).

## 영역 9 분류 결과

| ID | 심각도 | 발견 |
|----|--------|------|
| **A9-1** | **높음(배포)** | 리모트 24 vs 로컬 44 — **20 마이그레이션 미적용** (Wave 12 전 필수 인지) |
| **A9-2** | **높음(기능)** | S1/S3/Stage2/E 토대 객체·RPC **리모트 전무** |
| **A9-3** | 중간(운영) | 리모트 cron **1/3** — 정산·카지노 sweep 없음 |
| **A9-4** | 중간(스케일) | `auth_rls_initplan` 리모트 **20** 실측 (= A3-2) |
| **A9-5** | 정보 | 리모트 advisor INFO unused_index 37 / unindexed_fk 14 실측 |
| **A9-6** | 낮음( DX ) | `check:advisors` `.env` 미자동로드 |

## 영역 9 → 우선순위 목록 반영

- **① E 선결 / ④ ADR 배선** : 로컬 SQL·테스트 기준 — **리모트에는 아직 해당 객체 없음**. E 착수 전
  **로컬 토대 정리(①)** 와 **Wave 12 push( A9-1 )** 순서를 분리해 착수할 것(E 구현 ≠ 리모트 apply).
- **③ 스케일** : A3-2/A9-4 리모트 20 확인 — push 후 치환.

---

# ★ 감사 종료 (9/9 영역 완료)

- **수정 0 / 리모트 apply 0** 유지. 발견은 본 문서 + §①②③④ 우선순위 표.
- **다음 액션(운영자 선택)** :
  1. **Group E** : §① E 선결 5종 + §E 구현 가이드, **로컬** 마이그레이션/테스트 green 후 진행.
  2. **Wave 12** : `000025`–`000044` push 전 SQL 테스트 + post-push `check:advisors` 0 ERROR.
  3. **MCP** : 선택 — Cursor 버그 우회는 CLI; 채팅 MCP 필요 시 Cursor 업데이트/재설치.
