# PHONARA v2 — Phase 4 Casino 인계문 (Provably Fair)

> 목적: 이 문서 하나만으로 새 세션이 **Phase 4(카지노/Provably Fair)** 를 즉시,
> 중단 없이, 세계 최고 수준(stake.com / Rollbit / Binance / Bybit 게임팀 대비
> 공정성·보존·감사 가능성에서 압도)으로 완주할 수 있게 한다.
> 단일 진실 공급원은 `docs/PHONARA_V2_MASTER_PLAN.md` 이며, 이 인계문은 그 실행
> 순서·방식·네이밍을 Phase 4에 맞춰 구체화한 **전술 문서**다. 충돌 시 마스터 플랜과
> `.cursor/rules/*` 가 우선한다.

---

## 0. 현재 상태 (2026-06-10 기준)

- **완료**: Phase 0~3 + P0/P1 하드닝 + Zero Tech Debt Closeout(S1~S10) + offline i18n 수정.
- **게이트 전부 green**: `typecheck` / `lint` / `check:i18n` / `check:release` /
  `test`(102/102) / `test:e2e`(12/12) / `build`.
- **마지막 커밋**: `9441d00 feat(app): close out zero tech debt delivery`
  (이후 offline.html i18n 수정은 working tree 상태 — 사용자가 커밋 요청 시에만 커밋).
- **6대 기준 감사 결과**: 보안/보존/패리티/확인UX/E2E 전부 통과. 유일 결함이던
  offline.html i18n 은 해결됨.

### 기존 자산 (재사용 — 중복 생성 금지)

| 자산 | 위치 | Phase 4에서의 역할 |
|------|------|--------------------|
| `@phonara/money` | `packages/money` | Decimal(ROUND_DOWN) 정산·표시. **신규 통화 연산은 전부 여기 경유** |
| `@phonara/trading-engine` | `packages/trading-engine` | 보존(Σ=0)·정산 패턴의 레퍼런스. 게임 정산도 동일 패턴 |
| `@phonara/game-engine` | `packages/game-engine/src/index.ts` | **현재 scaffold-only** (`GameCode`, `ProvablyFairDraft`). 여기에 구현 |
| `@phonara/ui` | `packages/ui` | 모든 재사용 UI. 게임 공통 UI도 여기에 |
| `@phonara/shared-types` | `packages/shared-types` | DB 타입. 마이그레이션 후 MCP로 재생성 |
| `@phonara/i18n` | `packages/i18n/src/index.ts` | 모든 사용자 문구(ko/en) 단일 카탈로그 |
| 보존 SQL 테스트 | `supabase/tests/conservation_test.sql` 등 | 게임 보존 테스트의 형식·헬퍼 재사용 |
| E2E 헬퍼 | `tests/e2e/_helpers.ts` (`currencyTotals` 등) | 게임 E2E 보존 단언에 재사용 |

> ⚠️ 시작 전 반드시 `game_rounds` / `game_bets` / `game_seed_reveals` / `rpc_*game*`
> 이 이미 존재하는지 검색해 **중복 구현을 방지**한다 (`.cursor/rules/70` 전역 preflight).

---

## 1. 절대 불변 규칙 (위반 시 즉시 중단)

1. **단일 Supabase 프로젝트 락**: `yocjhjsdwoijfdrehzoq` 외 어떤 프로젝트도 금지.
   모든 MCP 호출에 `project_id="yocjhjsdwoijfdrehzoq"`.
2. **클라이언트 RNG 절대 금지**. 결과를 결정하는 난수는 **서버 권위 seed** 에서만.
3. **server seed hash 선공개 → 베팅 → 라운드 종료 후 server seed reveal** 순서 불변.
4. **Decimal(ROUND_DOWN)** 만 사용. `Number()`/`parseFloat()`/부동소수 금지
   (금액·배당·확률·잔고·payout 전부).
5. **보존 불변식 Σ(deltas)=0** per currency: user wallets + system accounts.
   하우스 엣지/수수료도 시스템 계정 leg 으로 명시 — 절대 "사라지는 돈" 없음.
6. **원장은 append-only**, balance 변경은 **idempotency key** 필수.
7. **available / locked 잔액 명시 분리** (베팅 시 lock → 정산 시 unlock+정산).
8. 내부 헬퍼(`_*`)는 `REVOKE ALL ... FROM PUBLIC, anon, authenticated`.
   클라이언트 `rpc_*`만 노출하고 본문에서 `auth.uid()` 가드.
9. **로컬 apply 게이트**: 마이그레이션은 `supabase db reset` 클린 통과 + SQL 통합
   테스트(보존 Σ=0 + 해시체인) green + 보안 어드바이저 0 ERROR 전까지 "완료" 아님.
10. **E2E 없으면 미완료**: 카지노 E2E는 베팅·정산·보존·seed hash 선공개·reveal·
    클라이언트 recompute 일치·변조/중복 요청 거부까지 전부 포함.

---

## 2. Provably Fair 설계 (PHONARA 표준 — 6종 공통)

> 레퍼런스(stake/Rollbit 계열)의 검증 모델을 따르되, **server seed는 절대 사전 노출
> 금지**, 모든 결과는 클라이언트가 독립 재계산 가능해야 한다.

### 2.1 시드 수명주기

```
1) 라운드 생성 시:
   server_seed        = 서버 생성 난수 (비공개)
   server_seed_hash   = SHA-256(server_seed)   ← 베팅 전 사용자에게 공개
   client_seed        = 사용자 제공(또는 기본값) — 사용자가 변경 가능
   nonce              = (server_seed 당) 증가 카운터

2) 베팅 시:
   사용자는 server_seed_hash + client_seed + nonce 를 본 상태로 베팅.

3) 결과 산출 (서버):
   hmac = HMAC_SHA256(key = server_seed, message = `${client_seed}:${nonce}`)
   → hmac 바이트 → 게임별 float/정수 변환 → 결과(배당/위치/카드 등)

4) 라운드 종료 후:
   server_seed 공개(reveal) → game_seed_reveals 에 기록.
   사용자/클라이언트가 SHA-256(server_seed) == server_seed_hash 확인 +
   동일 HMAC 재계산으로 결과 검증.
```

### 2.2 공통 fairness 모듈 (먼저 구현)

```
packages/game-engine/src/fairness/
├── seed.ts       // generateServerSeed(), hashServerSeed(seed): sha256 hex
├── hmac.ts       // hmacSha256(serverSeed, `${clientSeed}:${nonce}`): hex
├── float.ts      // bytesToFloat(hmacHex, cursor): [0,1) — bias 없는 변환
└── verifier.ts   // verifyRound({serverSeed, serverSeedHash, clientSeed, nonce, game}): 결과 재계산
```

- **암호화는 Web Crypto / Node `crypto` 동형 API** 사용(브라우저 검증 UI 와 서버가 동일
  결과를 내야 하므로 의존성 없는 순수 함수로). 클라이언트 검증 UI 도 같은 모듈을 import.
- `bytesToFloat`: stake 표준(4바이트씩 256진법 누적, 다중 바이트 소진)으로 bias 제거.

### 2.3 게임별 결과 함수 (deterministic, 순수 함수)

| 게임 | 입력 → 출력 | RTP/하우스엣지 |
|------|-------------|----------------|
| Crash | float → crashMultiplier (99/(1-f) 류, 1% 엣지) | RTP 99%, auto-cashout |
| Limbo | float → multiplier(target payout 역산) | double-house-edge 금지 |
| Dice | float → roll[0,99.99], over/under | 확률·배당 정확도 |
| Mines | float 스트림 → 지뢰 위치 set (Fisher–Yates) | grid/bomb proof |
| HiLo | float 스트림 → 카드 시퀀스 | deck/nonce 공정성 |
| Plinko | float 스트림 → L/R 경로 → bucket | 물리·확률 모델 |

> 각 함수는 **DB 불필요**한 순수 함수 → Vitest deterministic 테스트로 고정값 검증.
> SQL 정산 RPC와 **TS↔SQL 패리티 락** (futures 패턴 동일): 같은 입력 상수로 양쪽 ASSERT.

---

## 3. 데이터 모델 (마이그레이션 초안 — draft-first)

> 마이그레이션 번호는 현재 최신 `20260609000024` 다음 순번부터. 시작 전
> `supabase migration list` 로 로컬↔리모트 동기화 확인.

### 3.1 스키마

```sql
-- game_rounds: 라운드 단위 시드/상태 (server_seed 는 reveal 전 NULL 노출 금지)
game_rounds(
  id uuid pk, game game_code, status round_status,    -- open|settling|revealed
  server_seed_hash text not null,                      -- 선공개
  server_seed text,                                    -- reveal 후에만 채움
  client_seed text not null, nonce bigint not null,
  created_at, revealed_at)

-- game_bets: 베팅·정산 (append-only, idempotency)
game_bets(
  id uuid pk, round_id fk, user_id fk,
  currency currency, stake numeric not null,           -- Decimal 문자열 입력
  selection jsonb,                                     -- 게임별 베팅 파라미터
  result jsonb, payout numeric, house_fee numeric,
  status bet_status, idem_key text unique,             -- 중복 요청 거부
  placed_at, settled_at)

-- game_seed_reveals: 공개 감사 로그 (검증 UI 의 신뢰 근거)
game_seed_reveals(
  id uuid pk, round_id fk, server_seed text not null,
  server_seed_hash text not null, revealed_at)
```

### 3.2 RPC (클라이언트 노출은 `rpc_*` 만, 내부는 `_*`)

| RPC | 역할 | 가드/보존 |
|-----|------|-----------|
| `rpc_place_game_bet(p_game, p_currency, p_stake, p_selection, p_client_seed, p_idem_key)` | 라운드 확보 + stake **lock** + 베팅 기록 | `auth.uid()`, `_assert_system_live`, `_assert_feature_enabled('game')`, idempotency, Σ=0(available→locked) |
| `rpc_settle_game_bet(p_bet_id)` | 결과 산출 + payout 정산 + house_fee leg | Σ=0 (locked → user payout + system house), append-only ledger, 해시체인 |
| `rpc_reveal_round(p_round_id)` | server_seed reveal + 기록 | reveal 후 재베팅 불가, 감사 로그 |
| `_game_result(...)` | HMAC→결과 (내부) | REVOKE from PUBLIC/anon/authenticated |

> **정산 분해(Σ=0 예시, Crash 승리)**: `locked(stake)` 해제 →
> `user += stake*multiplier` + `system_house += stake - stake*multiplier`(엣지) +
> `dust` 보정. 모든 leg quantize 후 합이 정확히 0.

---

## 4. 작업 순서 (S-step, 순차 — 각 단계 게이트 green + Build Log 기록)

> 출시 위험 최소화를 위해 **Crash → Limbo** 먼저 엔진·E2E 검증 후 Dice/Mines/HiLo/Plinko 확장.

| 단계 | 내용 | 완료 기준(게이트) |
|------|------|-------------------|
| **C0** | `docs/REFERENCE_REPOS.md` 갱신 + 라이선스 확인. 기존 game 스키마/RPC 중복 검색 | preflight 완료 |
| **C1** | `fairness/` 공통 모듈(seed/hmac/float/verifier) + Vitest deterministic | `test` green, 고정 벡터 일치 |
| **C2** | Crash 결과 함수 + Limbo 결과 함수(순수) + Vitest(RTP/엣지/경계) | `test` green |
| **C3** | 마이그레이션 초안: `game_rounds/bets/seed_reveals` + enum + RLS | `db reset` 클린 |
| **C4** | `rpc_place_game_bet` / `rpc_settle_game_bet` / `rpc_reveal_round` + 내부 `_game_result` | `db reset`, 어드바이저 0 ERROR |
| **C5** | SQL 통합 테스트: 보존 Σ=0 + 해시체인 + idempotency + 변조 거부 (`supabase/tests/game_*_test.sql`) | `test:sql` green |
| **C6** | TS↔SQL 패리티 락 (Crash/Limbo 동일 상수 양쪽 ASSERT) | `test` + `test:sql` green |
| **C7** | shared-types 재생성(MCP) + `@phonara/ui` 게임 공통 UI + 라우트 `apps/web/src/routes/casino.*` | `typecheck`/`build` green |
| **C8** | Provably Fair 검증 UI(seed hash 선공개·reveal·클라 recompute) + 베팅 확인 UX(ConfirmDialog) | `check:i18n` green |
| **C9** | Playwright E2E: Crash·Limbo 베팅→정산→보존(Σ=0)→PF 검증→변조/중복 거부(pos+neg) | `test:e2e` green |
| **C10** | Dice/Mines/HiLo/Plinko 동일 패턴 확장(엔진→RPC→SQL테스트→UI→E2E 반복) | 각 게임별 전 게이트 green |
| **C11** | Phase 4 최종 게이트 + Build Log 정리 | `bun run check` 전체 green |

---

## 5. 작업 방식 (월드클래스 표준)

1. **Preflight(중복 방지)**: 매 단계 전 `.cursor/rules/*`, 마스터 플랜 Build Log,
   `git status`, 관련 RPC/컴포넌트/마이그레이션 검색. 이미 있으면 확장, 새로 만들지 않음.
2. **Draft-first SQL**: 마이그레이션·RPC는 초안 작성 → 로컬 `supabase db reset` 적용 →
   SQL 통합 테스트로 **실제 변경 분기**를 실행하며 보존·해시체인 단언 → `ROLLBACK`(잔재 0).
3. **TDD + 패리티**: 순수 엔진 함수는 Vitest 고정 벡터로 먼저. 정산 RPC는 TS 엔진과
   **바이트 단위 동일 상수**로 양쪽 ASSERT(드리프트 즉시 실패).
4. **E2E는 설계 단계에서 함께**: 기능 구현 전에 시나리오 정의. 머니 흐름은 DB에서
   보존(Σ=0)·해시체인·idempotency·잔재 0 을 직접 단언(텍스트 가시성만으로 불충분).
5. **보안 게이트**: DDL 후 `supabase db lint`(0 ERROR) + MCP 보안 어드바이저
   (`get_advisors`, `project_id="yocjhjsdwoijfdrehzoq"`) 0 ERROR.
6. **출시 청결**: dev 전용 도구는 `import.meta.env.DEV` 게이팅. 모든 문구 i18n(ko/en).
   `console.*`/TODO/placeholder/mock·seed 데이터 금지(`check:release`).
7. **Build Log 즉시 기록**: 각 단계 완료마다 `docs/PHONARA_V2_MASTER_PLAN.md` Build Log 에
   무엇을/어떻게/에러→해결/검증 기록(세션 간 메모리).
8. **커밋**: 의미 있는 마일스톤(green 상태)에서만, 사용자가 요청할 때. 푸시 금지(요청 시만).

### PowerShell 명령 (Windows — `&&` 금지, `;` 또는 줄 단위)

```powershell
bun run typecheck; bun run lint; bun run check:i18n; bun run check:release
bun run test
bun run build
supabase db reset
bun run test:sql
$env:CI="1"; bunx playwright test; Remove-Item Env:\CI
$env:CI="1"; bunx playwright test tests/e2e/casino.spec.ts; Remove-Item Env:\CI
```

---

## 6. 네이밍 규칙 (전부 준수)

### TypeScript
- 변수/함수 `camelCase`, 타입/컴포넌트 `PascalCase`, 상수 `SCREAMING_SNAKE_CASE`.
- 파일 `kebab-case.ts(x)`, 훅 `use-*.ts`.
- 컴포넌트: `forwardRef` + `displayName` + `cva` + `VariantProps` + **named export**,
  공개 API 는 `@phonara/ui` 단일 배럴(`packages/ui/src/index.ts`)에서만.
- 앱 import 는 패키지 루트 named import (`import { X, type XProps } from '@phonara/ui'`),
  딥 임포트 금지.

### SQL / Supabase
- 클라이언트 RPC `rpc_*`, 내부 헬퍼 `_*`(anon/PUBLIC REVOKE).
- 에러 코드 안정적 `UPPER_SNAKE_CASE`(예: `SYSTEM_HALTED`, `BET_DUPLICATE`,
  `STALE_ROUND`, `SEED_TAMPERED`) → 클라이언트에서 i18n 번역.
- SECURITY DEFINER 함수는 헤더에 `SET search_path = public, pg_temp`.
- enum: `game_code`, `round_status`, `bet_status`.
- 마이그레이션 파일 `YYYYMMDDhhmmss_p4_<purpose>.sql` (현재 체계 연속).

### 게임 엔진 구조 (마스터 플랜 고정 — 변경 금지)
```
packages/game-engine/src/
├── fairness/{seed,hmac,float,verifier}.ts
├── crash/  limbo/  dice/  mines/  hilo/  plinko/
└── (각 게임: <game>.ts 순수 함수 + index re-export)
packages/game-engine/src/*.test.ts   // 게임별 deterministic
```

### i18n 키
- `casino.<game>.<element>` (예: `casino.crash.cashout`, `casino.bet.confirm`,
  `casino.fairness.verify`, `casino.fairness.serverSeedHash`).
- 모든 키 ko/en 동시 추가, 영어 모드 한국어 노출 0.

### 테스트 / E2E
- SQL: `supabase/tests/game_<game>_test.sql` (보존 + 해시체인 + idempotency + 변조 거부).
- E2E: `tests/e2e/casino.spec.ts` (게임별 describe). 기존 spec 확장 우선, 중복 파일 금지.
- `data-testid`: `casino-<game>-bet`, `casino-<game>-cashout`, `casino-fairness-verify` 등.

---

## 7. Definition of Done (Phase 4 — 전부 충족해야 완료)

- [ ] `fairness` 모듈 + 6종 엔진 deterministic Vitest green.
- [ ] 마이그레이션 `supabase db reset` 클린 + 보안 어드바이저 0 ERROR.
- [ ] 게임 정산 RPC SQL 통합 테스트: 보존 Σ=0 + 해시체인 + idempotency + 변조 거부 green.
- [ ] TS↔SQL 패리티 락(최소 Crash/Limbo) green.
- [ ] Provably Fair 검증 UI: seed hash 선공개 → reveal → 클라 recompute 일치.
- [ ] 베팅·캐시아웃 등 고위험 액션 ConfirmDialog(우회 불가).
- [ ] Playwright E2E(게임별 pos+neg): 베팅→정산→보존→PF검증→변조/중복 거부 green.
- [ ] 모든 문구 i18n(ko/en), 영어 모드 한국어 0, dev 도구 DEV 게이팅.
- [ ] `bun run check` 전체 green + Build Log 기록 + 잔재 0.

---

## 8. 알려진 함정 (반복 디버깅 금지)

- E2E/visual 실행은 **`$env:CI="1"` 설정 후**, 종료 시 `Remove-Item Env:\CI`.
- `supabase db reset` 직후 로컬 realtime 컨테이너 지연 → REST 응답 대기 후 단언
  (잔액 비의존 랜드마크 사용). 지갑 미표시를 코드 회귀로 오해 금지.
- 브라우저 Chromium 에서 로컬 Supabase RPC 가 간헐적 blocking → 백엔드 단언은 Node.js
  `userClient.rpc()` 직접 호출이 안정적(E2E 헬퍼 패턴 재사용).
- 머니 흐름 후 잔액 절대값 단언 금지(펀딩 소진) → **delta/보존** 단언 사용.
- PowerShell 에서 git heredoc(`<<EOF`) 불가 → here-string(`@' ... '@`) 사용.
- 테스트 산출물(`test-results`, `dist`, `.vite`, `.auth.json`)은 잔재 → 정리 대상.

---

## 9. 핵심 경로 빠른 참조

```
마스터 플랜/Build Log : docs/PHONARA_V2_MASTER_PLAN.md
이 인계문            : docs/HANDOVER_PHASE4_CASINO.md
레퍼런스 레포        : docs/REFERENCE_REPOS.md
게임 엔진           : packages/game-engine/src/  (현재 scaffold-only)
머니/UI/i18n        : packages/{money,ui,i18n}/src
마이그레이션        : supabase/migrations/  (다음 번호: 20260609000025~)
SQL 통합 테스트     : supabase/tests/
E2E                 : tests/e2e/  (casino.spec.ts 신설), tests/e2e/_helpers.ts
웹 라우트           : apps/web/src/routes/  (casino 신설)
규칙               : .cursor/rules/*.mdc
Supabase 프로젝트   : yocjhjsdwoijfdrehzoq (유일 — 절대 변경 금지)
```

---

## 10. 시작 첫 행동 (새 세션)

1. `bun run typecheck; bun run lint` 로 baseline green 확인.
2. `supabase migration list` 로 로컬↔리모트 동기화 확인.
3. 기존 `game_*` 스키마/RPC/컴포넌트 중복 검색(없음 확인).
4. **C0 → C1(fairness)** 부터 순차 시작 → 단계별 게이트 green → Build Log 기록 → 다음.

> 한 줄 원칙: **공정성은 증명 가능해야 하고(Provably Fair), 돈은 1원도 사라지지 않으며
> (Σ=0), 모든 고위험 행동은 확인·감사된다.** 이 셋을 어기는 진행은 없다.
