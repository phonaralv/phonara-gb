# PHONARA v2 — 빌드 진행 로그

> 최종 업데이트: 2026-06-09
> 모든 작업은 `C:/Users/PC/Desktop/phonara-gb` (monorepo) 기준

---

## 목차

- [Phase 0 — 프로젝트 골격](#phase-0--프로젝트-골격)
- [Phase 1 — Auth / 지갑 / 원장](#phase-1--auth--지갑--원장)
- [Step 5 — 웹 앱 초기 UI](#step-5--웹-앱-초기-ui)
- [Phase 2 — 보상 리텐션 시스템](#phase-2--보상-리텐션-시스템)
- [미완료 (대기 중)](#미완료-대기-중)

---

## Phase 0 — 프로젝트 골격

**상태: ✅ 완료**

### 구현 내용

**모노레포 구조 설정**

```
phonara-gb/
├── apps/
│   └── web/          ← TanStack Start + Vite (React)
├── packages/
│   ├── money/        ← 금융 연산 엔진
│   ├── wallet-ledger/← 지갑 원장 엔진
│   ├── shared-types/ ← Supabase DB 타입 + 공용 타입
│   ├── trading-engine/
│   ├── game-engine/
│   └── i18n/
├── supabase/
│   └── migrations/   ← SQL 마이그레이션 파일
└── tsconfig.json     ← 프로젝트 레퍼런스 기반 타입체크
```

**패키지 설정**
- 런타임: Bun
- 프레임워크: TanStack Start (TanStack Router v1 + Vite)
- 언어: TypeScript strict mode
- 테스트: Vitest (유닛), Playwright (E2E)
- 린팅: ESLint + Prettier
- DB: Supabase (PostgreSQL)

**해결한 주요 이슈**
- TypeScript `baseUrl` 지원 중단 → `paths`를 상대경로 `./packages/...` 로 전환
- Vitest SSR에서 `decimal.js` import 오류 → `server.deps.inline: ['decimal.js']` 추가
- Vitest `@phonara/*` 모듈 해석 오류 → `resolve.alias` 매핑 추가
- 스테일 `.js` 컴파일 파일이 `.ts` 소스를 가리는 현상 → 수동 삭제

**관련 파일**
- `package.json` — 워크스페이스 + 스크립트
- `tsconfig.base.json` — 공용 TS 설정
- `tsconfig.json` — 프로젝트 레퍼런스 (packages → apps 순서)
- `vitest.config.ts` — alias + decimal.js 인라인 처리

---

## Phase 1 — Auth / 지갑 / 원장

**상태: ✅ 완료**

### 1-A. Money Engine (`packages/money`)

**파일:** `packages/money/src/index.ts`

**핵심 설계:**
- `Decimal.js` 기반 (부동소수점 오류 완전 차단)
- 통화별 소수점 자릿수: `PHON/USDT: 6자리`, `KRW: 0자리`
- `Decimal.set({ precision: 28, rounding: ROUND_HALF_UP })`

**주요 함수:**
| 함수 | 설명 |
|------|------|
| `money(amount, currency)` | MoneyAmount 생성자 |
| `add / subtract / multiply` | 정밀 연산 |
| `applyFeeRate(amount, rate)` | 수수료 계산 |
| `convert(amount, rate, target)` | FX 환전 |
| `convertWithFee(...)` | 환전 + 수수료 동시 적용 |
| `format(amount)` | 통화별 포맷팅 (KRW: 원, USDT: $) |
| `isGreaterThan / isZero / isPositive` | 비교 유틸 |

**테스트:** `packages/money/src/index.test.ts` — 26개 테스트 전부 통과

---

### 1-B. Wallet Ledger Engine (`packages/wallet-ledger`)

**파일:** `packages/wallet-ledger/src/index.ts`

**핵심 설계:**
- 순수 함수 (side-effect 없음)
- 모든 잔고 변경은 `LedgerEntry`를 통해서만 가능
- `credit / debit / lock / unlock / reverse` 5가지 방향

**주요 타입:**
```typescript
interface WalletBalance   { available: string; locked: string }
interface WalletSnapshot  { phon: WalletBalance; usdt: WalletBalance; krw: WalletBalance }
interface LedgerEntry     { direction, currency, amount, ... }
```

**에러 타입 (`LedgerError`):**
- `insufficient_available` — 잔고 부족
- `insufficient_locked` — 잠금 잔고 부족
- `invalid_amount` — 0 이하 금액
- `invalid_direction` — 미지원 방향

**테스트:** `packages/wallet-ledger/src/index.test.ts` — 17개 테스트 전부 통과 (베팅 정산 시퀀스 포함)

---

### 1-C. Supabase 스키마 (Phase 1)

**파일:** `supabase/migrations/20260609000001_phase1_auth_wallet_ledger.sql`

**생성된 테이블:**
| 테이블 | 역할 |
|--------|------|
| `profiles` | 유저 프로필 (`kyc_tier`, `user_role`, `referrer_id`) |
| `wallets` | 유저별 지갑 (`phon_available/locked`, `usdt_available/locked`, `krw_available/locked`) — 모두 TEXT 타입 |
| `wallet_ledger` | 불변 원장 (모든 잔고 변경 기록) |
| `exchange_rate_snapshots` | FX 환율 스냅샷 |
| `krw_deposit_requests` | KRW 입금 요청 |
| `audit_logs` | 관리자 액션 로그 |

**중요 설계 결정:**
- 잔고 컬럼을 **TEXT 타입**으로 저장 (Decimal 정밀도 보존, `NUMERIC`으로 연산)
- `wallet_ledger`는 `DELETE/UPDATE` 금지 (RLS + policy로 강제)
- 트리거: `auto_create_wallet` (프로필 생성 시 지갑 자동 생성), `handle_new_user` (auth.users 가입 시 프로필 자동 생성)

---

### 1-D. RLS 정책 (Phase 1)

**파일:** `supabase/migrations/20260609000002_phase1_rls_policies.sql`

- 모든 핵심 테이블에 RLS 활성화
- 기본: 전체 차단 (deny all)
- 유저는 자신의 데이터만 읽기/쓰기 가능
- `wallet_ledger`는 INSERT만 가능 (RPC 통해서만)

---

### 1-E. Atomic RPCs (Phase 1)

**파일:** `supabase/migrations/20260609000003_phase1_atomic_rpc.sql`

**생성된 함수:**
| 함수 | 역할 |
|------|------|
| `_get_wallet_for_user(uuid)` | 지갑 조회 + FOR UPDATE 락 |
| `rpc_credit_wallet(currency, amount, reason, idempotency_key)` | 잔고 증가 + 원장 기록 |
| `rpc_debit_wallet(currency, amount, reason, idempotency_key)` | 잔고 감소 + 원장 기록 |
| `rpc_lock_wallet(currency, amount, reason, idempotency_key)` | available→locked 이동 |
| `rpc_unlock_wallet(currency, amount, reason, idempotency_key)` | locked→available 이동 |

**모든 RPC 공통 보장:**
- `SECURITY DEFINER` — RLS 우회 가능
- 멱등성 보장 — 동일 `idempotency_key` 재호출 시 기존 결과 반환
- 원자성 — 잔고 업데이트 + 원장 기록이 단일 트랜잭션
- 잔고 검증 — debit/lock 전 충분한 잔고 확인

---

### 1-F. TypeScript DB 타입

**파일:** `packages/shared-types/src/database.types.ts`

Supabase 스키마 기반으로 수동 작성된 전체 타입 정의.
전체 스택에서 타입 안전성 보장.

---

## Step 5 — 웹 앱 초기 UI

**상태: ✅ 완료**

**파일 목록:**

| 파일 | 역할 |
|------|------|
| `apps/web/src/lib/supabase.ts` | Supabase 클라이언트 초기화 (`Database` 타입 포함) |
| `apps/web/src/lib/auth.ts` | `sendMagicLink`, `signOut`, `getSession` |
| `apps/web/src/contexts/auth-context.tsx` | React Context (`AuthProvider`, `useAuth`) — 세션 상태 관리 |
| `apps/web/src/routes/__root.tsx` | TanStack Router 루트 (AuthProvider wrapping) |
| `apps/web/src/routes/index.tsx` | 로그인 여부에 따라 `/login` 또는 `/dashboard` 리다이렉트 |
| `apps/web/src/routes/login.tsx` | 이메일 매직링크 로그인 페이지 |
| `apps/web/src/routes/dashboard.tsx` | 대시보드 (지갑 잔고 표시) |
| `apps/web/src/routes/ledger.tsx` | 원장 내역 테이블 |
| `apps/web/src/hooks/use-wallet.ts` | `useWallet`, `useLedger` 훅 |
| `apps/web/src/styles.css` | 전체 UI 스타일 (CSS 변수, 카드, 스켈레톤) |

**인증 플로우:**
1. 유저가 이메일 입력
2. Supabase OTP 매직링크 발송
3. 링크 클릭 시 `/dashboard` 자동 리다이렉트
4. `AuthContext`가 실시간 세션 상태 구독 (`onAuthStateChange`)

---

## Phase 2 — 보상 리텐션 시스템

**상태: ✅ 완료**
**커밋:** `f9bb646`

### 보상 구조 설계

**1 PHON = 1 KRW 체감 기준** (한국 앱테크 "고수익" 수준)

| 항목 | 지급량 | 비고 |
|------|--------|------|
| 첫 가입 보너스 | **5,000 PHON** | 1회 지급 |
| 추천 코드 입력 시 추가 | **+1,000 PHON** | 가입 시 코드 입력 |
| 추천인 보상 | **+2,000 PHON** | 피추천인 첫 가입 시 자동 지급 |
| 매일 출석 (Day 1) | **50 PHON** | 기본 |
| 매일 출석 (Day 30 연속) | **최대 340 PHON** | 스트릭 보너스 |
| 일일 룰렛 (평균) | **~56 PHON** | 기대값 |
| 일일 룰렛 (최대) | **1,000 PHON** | 1% 확률 |
| 미션 (총합) | **최대 11,900 PHON** | 8개 미션 합산 |

**월 최대 잠재 수익 (헌신 유저):** ~15,000+ PHON

---

### 2-A. 스키마 (Phase 2)

**파일:** `supabase/migrations/20260609000004_phase2_retention_schema.sql`

**생성된 테이블:**
| 테이블 | 역할 |
|--------|------|
| `user_streaks` | 유저별 스트릭 상태 (비정규화, 빠른 조회용) |
| `daily_claims` | 매일 출석 기록 (user_id + date UNIQUE) |
| `roulette_spins` | 룰렛 스핀 기록 (user_id + date UNIQUE) |
| `referrals` | 추천 관계 (referred_id UNIQUE — 1인 1추천) |
| `welcome_bonuses` | 가입 보너스 수령 기록 (user_id PRIMARY KEY) |
| `missions` | 미션 완료 기록 (user_id + mission_code UNIQUE) |

**생성된 Enum:**
```sql
mission_code: complete_profile | first_trade | first_game | first_deposit
            | kyc_verified | invite_3_friends | streak_7_days | streak_30_days
```

**트리거:** `auto_init_streak` — 프로필 생성 시 `user_streaks` 자동 초기화

---

### 2-B. Atomic RPCs (Phase 2)

**파일:** `supabase/migrations/20260609000005_phase2_retention_rpcs.sql`

| 함수 | 역할 |
|------|------|
| `_credit_wallet_internal(user_id, currency, amount, reason, idempotency)` | 내부용 — 타 유저 지갑 직접 크레딧 (추천인 보상용) |
| `rpc_claim_welcome_bonus(idempotency_key?)` | 5,000 PHON 지급, 추천 코드 처리, 추천인 2,000 PHON 지급 |
| `rpc_claim_daily_reward()` | 스트릭 계산 + 보상 지급 + 마일스톤 미션 자동 트리거 |
| `rpc_spin_roulette()` | 서버 시드 기반 룰렛 (Provably Fair 기초), 1일 1회 |
| `rpc_register_referral(code)` | 추천 코드 등록 (자기 추천 방지, 중복 방지) |
| `_grant_mission(user_id, mission)` | 내부용 미션 보상 지급 (멱등성 보장) |
| `rpc_complete_mission(mission)` | 공개 미션 완료 처리 |

**보상 공식:**
```
일일 출석 = 50 + (min(streak_day - 1, 29) × 10)
  Day 1:  50 PHON
  Day 7:  110 PHON
  Day 30: 340 PHON (최대)

룰렛 확률:
  10 PHON: 30%  |  20 PHON: 25%  |  30 PHON: 20%
  50 PHON: 12%  | 100 PHON: 7%   | 300 PHON: 3%
  500 PHON: 2%  |1000 PHON: 1%
```

---

### 2-C. 프론트엔드 컴포넌트

**훅:** `apps/web/src/hooks/use-retention.ts`
- `useWelcomeBonus()` — 보너스 청구 + 수령 여부 확인
- `useDailyClaim()` — 출석 + 스트릭 상태
- `useRoulette()` — 스핀 + 스핀 가능 여부 확인
- `useMissions()` — 미션 목록 + 완료 처리
- `useReferral()` — 추천 코드 등록

**컴포넌트:**
| 파일 | 역할 |
|------|------|
| `WelcomeModal.tsx` | 신규 가입자 환영 모달 (추천 코드 입력 → 보너스 수령) |
| `DailyClaimCard.tsx` | 7일 스트릭 바 시각화, 내일 예상 보상 표시 |
| `RouletteCard.tsx` | 스핀 애니메이션, 당첨 등급 하이라이트 |
| `MissionsCard.tsx` | 8개 미션 진행 상황 + 획득 가능 PHON 합계 |

**대시보드 통합:** `apps/web/src/routes/dashboard.tsx`에 보상 섹션 추가
- 신규 유저 감지 (잔고 = 0) → `WelcomeModal` 자동 표시
- 보상 섹션: `DailyClaimCard` + `RouletteCard` 그리드 + `MissionsCard`

---

## 미완료 (대기 중)

| Phase | 내용 | 비고 |
|-------|------|------|
| **Phase 3** | PHON/USDT 트레이딩, Long/Short, Spot, Staking, 차트, PnL, Atomic 정산 | ⚠️ **핵심 엔진 — AI 모델 전환 필요** |
| **Phase 4** | Casino PHON/USDT, 6종 게임 엔진, Provably Fair, 서버 권위 RNG, RTP | ⚠️ **핵심 엔진 — AI 모델 전환 필요** |
| **Phase 5** | 코인/원화 입출금, PHON 환전, 99% 자동화 Admin, 고객센터 실시간 상담 | |
| **Phase 6** | PWA, 모바일OS급 UX, i18n, 성능, 리더보드, 보안, 감사 로그, 운영 고도화 | |

---

## 기술 부채 / 참고 사항

- `database.types.ts`는 수동 관리 중 → Phase 3 완료 후 Supabase CLI `gen types` 로 재생성 권장
- `rpc_credit_wallet`은 `auth.uid()` 기반 → 타 유저 크레딧이 필요한 경우 반드시 `_credit_wallet_internal` 사용
- 룰렛 RNG는 현재 `random()` 기반 → Phase 4에서 Provably Fair 완전 구현 예정
- 미션 `invite_3_friends`는 트리거 미구현 → Phase 2 후속 작업 필요

---

## 환경 설정

```bash
# 로컬 개발
bun install
bun run dev            # apps/web 개발 서버

# 테스트
bun run test           # Vitest 유닛 테스트
bun run test:e2e       # Playwright E2E

# 타입 체크
bun run typecheck      # tsc -b --force tsconfig.json

# Supabase 프로젝트
# Project ID: yocjhjsdwoijfdrehzoq
# URL: https://yocjhjsdwoijfdrehzoq.supabase.co
```
