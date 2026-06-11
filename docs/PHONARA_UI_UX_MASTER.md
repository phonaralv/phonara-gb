# PHONARA UI/UX 마스터 — docs 확정본 v1.1

> **문서 위치와 권위**: 통합 실행 계약 v1.1의 PART 4 확장판이자 진실 공급원 **#4**.
> 우선순위: ① `.cursor/rules/*.mdc` ② `docs/PHONARA_V2_MASTER_PLAN.md` ③ 통합 실행 계약 v1.1 ④ **이 문서** ⑤ HANDOVER_PHASE4_CASINO. 충돌 시 위가 이긴다.
> 계약 v1.1의 PART 4는 라우팅 인덱스이고, 상세 명세의 권위는 이 문서다. UI 작업 전 필독, 위반 산출물은 "완료"가 아니다.

---

## 1. 역할 선언

너는 PHONARA의 리드 프로덕트 디자이너 겸 프론트엔드 엔지니어다. 산출물의 비교 대상은 lovable/v0.dev가 아니라 **stake.com, Rollbit, Binance, Bybit의 실서비스 화면**이다. lovable/v0는 "이기는 대상"이 아니라 "절대 닮지 말아야 할 하한선"이다.

AI 생성 UI의 3대 패배 패턴을 절대 재현하지 않는다:
1. **죽은 화면** — 실데이터 없이 정적 목업처럼 보이는 UI. PHONARA의 모든 화면은 가격 틱, 잔액 변동, 라운드 진행이 실시간으로 살아 움직여야 한다.
2. **누더기 일관성** — 페이지마다 미묘하게 다른 간격/색/컴포넌트. 모든 시각 결정은 `theme.css @theme` 토큰과 `@phonara/ui` 단일 배럴에서만 나온다.
3. **happy path only** — 로딩/빈/에러/권한거부 상태가 없는 UI. 4종 상태는 모든 화면의 의무 산출물이다.

---

## 2. 절대 제약 (위반 시 즉시 중단 — 규칙 85 연동)

- **컴포넌트 소유권**: 재사용 가능한 UI는 무조건 `@phonara/ui`에 생성. 앱 내부 생성은 라우트 전용·비재사용임을 증명할 수 있을 때만(예: 룰렛 `.btn-spin`). forwardRef + displayName + cva + VariantProps + named export + 단일 배럴 import. 딥임포트 금지.
- **토큰 단일 소스**: 하드코딩 hex 금지. 신규 색/반경/간격은 `apps/web/src/theme.css`의 `@theme`에 먼저 등록 후 사용.
- **i18n 0 예외**: JSX 내 한국어 문자열 금지. 모든 문구는 `@phonara/i18n` 키(ko/en 동시 등록). 영어 모드에서 한국어 0자. `@phonara/ui` 컴포넌트는 i18n에 의존하지 않고 문구를 props로 주입받는다.
- **금액 표시**: `Number()`/`toLocaleString()` 금지. `Money`/`formatMoney`(Decimal 기반)만 사용. 모든 숫자 표시 영역(잔액, 가격, PnL, 배율)은 `tabular-nums` 적용 — 틱마다 너비가 출렁이는 숫자는 즉시 결함이다.
- **고위험 액션 확인**: 베팅, 포지션 진입/청산, 매수/매도, 스테이크/언스테이크, 출금, Admin 액션은 예외 없이 `ConfirmDialog` 경유. 다이얼로그에는 통화, 수량, 적용 환율/가격, 수수료, 예상 결과를 표시한다.
- **테스트 식별자**: 머니/고위험 인터랙션 요소는 `data-testid` 필수(E2E 게이트의 전제 조건).
- **클라이언트 권위 금지**: UI는 검증된 엔진의 얇은 표현층이다. 결과 계산은 `packages/*` 순수함수를 import해서 쓰고, UI 안에 정산/공정성 로직을 재구현하지 않는다.
- **신규 의존성 금지**: 확정 스택(framer-motion, lucide-react, sonner, cva, TanStack Query/Router, zustand, zod) 밖의 UI 라이브러리 추가는 마스터플랜에 사유 기록 후에만.

---

## 3. 디자인 언어 스펙

### 3-1. 테마 방향
- **다크 단일 테마.** 라이트모드는 만들지 않는다(타겟 유저층 사용률 ~0, 작업량 2배). 토큰 구조는 미래 리브랜딩이 토큰 교체로 끝나도록 유지한다.
- 배경 3단 위계: `--color-bg`(base) → `--color-surface`(카드) → elevated(모달/시트, surface 대비 한 단계 밝게). 깊이는 그림자보다 **배경 단차와 보더**로 표현한다(다크 테마에서 그림자는 거의 안 보인다).
- Auth/onboarding release tokens: `--color-surface-elevated`(auth card), `--color-border-subtle`
  (은은한 카드 border), `--color-primary-bright`(CTA/PHON gradient endpoint),
  `--rgb-primary`, `--rgb-primary-bright`, `--rgb-accent-secondary`(radial glow/CTA shadow),
  `--shadow-auth-card`, `--shadow-auth-cta`. 이 값들은 AuthShell 재작업의 명시 스펙을
  토큰화한 것이며, route JSX에서 hex/rgba를 직접 쓰지 않는다.
- 시맨틱 컬러 고정: `--color-up`(long/매수/승리=green), `--color-down`(short/매도/패배/청산=red), `--color-warning`(경고/잠금), `--color-primary`(브랜드 액션), `--color-accent`(리워드/하이라이트). **보라 그라데이션 히어로 금지** — v0 시그니처다.
- 색은 의미를 운반한다: green/red는 오직 방향성·승패에만. 장식 목적으로 시맨틱 컬러를 쓰지 않는다.

### 3-2. 타이포그래피
- 본문: Pretendard(한국어 우선). 숫자/데이터: `font-variant-numeric: tabular-nums` + 모노스페이스 계열(신규 폰트는 토큰 등록 후).
- 타입 스케일을 토큰으로 고정. 임의 px 금지.
- 큰 숫자 + 작은 라벨 패턴은 금융 데이터에 한해 사용(총자산, 현재 배율, 청산가). 모든 카드에 남발하면 템플릿 냄새가 난다.
- 50~70대 가독성: 본문 최소 15~16px 상당, 보조 텍스트도 12px 미만 금지.

### 3-3. 모션 (framer-motion, 60fps 원칙)
- **목적 있는 모션만**: (a) 돈의 변화 — 잔액 카운트업, PnL 트윈(200ms) + 틱 방향 플래시(배경 100ms), (b) 결과의 순간 — Crash 버스트 셰이크 1회, 보상 지급 팝, (c) 상태 전환 — 시트/모달 spring. 그 외 장식 모션은 기본 금지.
- 게임 루프 렌더링은 `requestAnimationFrame` + canvas. 60fps를 깨는 효과는 즉시 제거.
- `prefers-reduced-motion` 존중 필수.
- 스켈레톤은 스피너보다 우선. 레이아웃 시프트(CLS) 유발 금지.

### 3-4. 밀도 원칙 (화면 감정 매핑)
- **트레이딩/게임 = 고밀도**(정보가 곧 신뢰), **입출금/KYC = 저밀도 + 여백**(차분함이 곧 신뢰), **온보딩/미션 = 중밀도 + 보상 강조**. 전 화면을 같은 밀도로 만들면 안 된다.

---

## 4. 정보 구조 (IA — 확정)

### 모바일 하단 탭 (5개 고정, 추가 금지)
| 탭 | 핵심 CTA |
|---|---|
| 홈 | 오늘 PHON 받기 |
| 미션 | 일일 퀘스트 진행 |
| 거래 | 현물/선물/스테이킹 진입 |
| 게임 | 6종 게임 로비 |
| 지갑 | 입금하기 |

### 데스크톱
좌측 사이드바(홈 / 미션 / 거래[현물·선물·스테이킹] / 게임[6종] / 지갑[입금·출금·환전·원장] / 리더보드 / 내정보) + 상단 상태바(잔액 상시 노출).

### Admin
대시보드 → 예외 큐 중심. "지금 사람이 봐야 하는 것"만 첫 화면에. 필터 프리셋(오늘/대기/고위험/불일치/자동화실패), 모든 행에 추천 액션 표시, 고위험 액션 2단계 확인 + reason 필수. Kill switch는 모바일에서도 접근 가능.

### 공통 네비 원칙
- 어디서든 2탭 이내에 지갑과 홈으로 복귀 가능.
- 고위험 기능은 직행하지 않고 확인 화면을 거친다.
- 지갑 진입점에는 PHON_real / PHON_free / USDT 상태가 항상 보인다.

---

## 5. @phonara/ui 컴포넌트 현황과 빌드 로드맵 (델타 ① 반영)

### 5-1. 검증된 기존 (Build Log + Wave 0.7 승인)
Button, Badge, Card, ConfirmDialog, Input, Modal, Money, SegmentedControl, Spinner, Stat (+ cn / mergeRefs).

**Wave 0.7 승격 (2026-06-10)**: Sheet, Slider, Tabs, DataTable, Tooltip — git `f1f2d55` 존재 확인. 규칙 85·게이트 통과(코드 승인). 출처 부분 확인: Zero Tech Debt S2 “Sheet 제외”와 s1-design-foundation 추가가 Build Log에서 미화해 — 상세는 마스터플랜 Wave 0.7 화해 항목.

**조건부 (Wave 6 이연)**: Slider thumb `border-white`, Sheet backdrop `bg-black/60` — 토큰 정리 예정(즉시 교정 대상 아님: hex/i18n/딥임포트/배럴 누락 해당 없음).

### 5-2. (없음 — 0.7 완료)

### 5-3. 신규 빌드 순서 (preflight로 중복 확인 후)
1. **Toast** — sonner 래핑 + 토큰 스타일 통일(성공/진행중/경고/실패/보안 5 tone).
2. **Skeleton** — 카드/행/차트 3변형.
3. **BetPanel** — 게임 공통 베팅 셸(금액 입력, 1/2·x2·MAX, 통화 선택, 자동베팅 설정 슬롯). *Wave 6 산출물명 동일 — 별칭 BetConfirmDialog는 BetPanel + ConfirmDialog 조합을 의미하며 별도 컴포넌트가 아니다.* (델타 ②)
4. **FairnessVerifier** — seed hash/reveal/nonce 표시 + "브라우저에서 재계산" 버튼(verifier.ts 동일 모듈 import). *Wave 6의 FairnessPanel과 동일 컴포넌트 — 정식 명칭은 FairnessVerifier로 통일.* (델타 ②)
5. **GameStakeInput** — BetPanel 내부 금액 입력 프리미티브(Input 확장, 통화별 min/max 검증 연동). (델타 ②)
6. **MultiplierDisplay** — 대형 배율 숫자(tabular-nums, 트윈/플래시 내장). (델타 ②)
7. **ProvablyFairBadge** — 라운드 결과 옆 검증 진입 아이콘. (델타 ②)
8. **EmptyState / ErrorState** — 아이콘 + 설명 + 복구 CTA 표준형.
9. **StatusTimeline** — 입출금 상태(요청→심사→전송→완료) 단계 표시.

규칙: **페이지를 먼저 그리지 않는다.** 토큰 확정 → 프리미티브 → 페이지 조립 순서. styles.css 잔여 줄수를 매 슬라이스마다 Build Log에 기록(단조 감소).

---

## 6. 페이지별 명세 (계약 PART 4.6의 권위 본문)

### 6-1. 로그인 / 회원가입
- 단일 컬럼, 필드 최소(이메일+비밀번호, 가입 시 +추천코드 자동주입). 목표: 가입 30초.
- 에러는 필드 인라인(토스트 금지), 제출 버튼은 유효성 통과 전 disabled, 비밀번호 강도 인라인 표시.
- **가입 직후가 승부처**: 빈 대시보드에 떨구지 말 것. 동의 게이트(버전드 동의 체크박스 — 약관/개인정보/리스크/연령 4종) → 웰컴 모달에서 10,000P 지급 카운트업 애니메이션 → 단일 CTA "첫 미션 하러 가기".
- 화려함 금지 구간. 신뢰 = 단순함.

### 6-2. 홈 대시보드
- 구조: ① 총자산(KRW 환산 병기) 크게 ② PHON_real / PHON_free 명확 분리 — free에는 "출금 불가" Badge 상시(UX이자 분쟁 예방 장치) ③ 오늘 할 일 3개 이내(일일퀘스트 진행도 + 받기 CTA) ④ 활성 포지션 요약 ⑤ 최근 게임/원장 미리보기.
- 원칙: 대시보드는 보고서가 아니라 **다음 행동 라우터**. 모든 카드에 CTA 정확히 1개.
- 잔액 변동은 Realtime 구독으로 즉시 반영 + 카운트업 트윈.

### 6-3. 미션/리워드 (사이드인컴 메인 노출면)
- 오늘 받을 수 있는 PHON 총액을 최상단에. 출석/룰렛/스트릭/추천을 카드로, 완료 즉시 보상 토스트 + 잔액 트윈.
- 연령대별 훅 반영: 큰 글씨 모드 무리 없이 동작. 보상·미션·친구초대 카피는 적극 사용 가능하되, 수익 보장처럼 오해될 표현은 실제 확정 근거가 있을 때만 사용.
- 추천 대시보드: 내 코드, 초대 현황(pending→approved→paid 상태별), 공유 버튼(Web Share API).
- FOMO는 가능: 초기 출시 구간에는 운영자가 설정한 캠페인 기준값으로 숫자/순위/활동자 수/지급 완료 수/마감 수량/카운트다운형 카피를 사용할 수 있다. 실제 데이터 소스 연결 전에는 라이브 실측값처럼 표현하지 않고 "캠페인 기준", "시즌 목표", "한정 슬롯" 성격을 명확히 한다.

### 6-4. 트레이딩 (난이도 최상)
- **레이아웃은 표준 준수** — Binance/Bybit 근육기억을 거스르지 않는다. PC: 차트(좌, ~70%) + 주문패널(우 고정) + 하단 포지션/주문 DataTable. 모바일: 차트 위, 주문은 Sheet.
- 차트: TradingView Lightweight Charts. 오라클 가격 라인 + **청산가 라인을 차트에 직접 렌더**(가격 접근 시 점멸) — 차별화 포인트.
- 주문패널: 레버리지 Slider 조작 **즉시** 청산가/필요증거금/최대수익 0ms 재계산 — `futures.ts` 순수함수를 클라에서 직접 호출(엔진-우선 아키텍처의 UI 배당금). 격리/크로스 모드 SegmentedControl(Phase 3.5 연동), 티어드 MMR 적용 시 구간 표시.
- 포지션 행: PnL 실시간 트윈 + 방향 플래시, 청산 근접 시 행 자체에 위험 표시. TP/SL 설정은 인라인.
- B-book 정직성: "오라클 가격 기준 정산" 고지를 마켓 정보 영역에 명시.

### 6-5. 게임 (셸 1개 + 캔버스 교체 = 플러그인 레지스트리와 대칭)
- 공통 셸: 좌 BetPanel + 우 게임 캔버스(모바일: 캔버스 위, BetPanel 하단 고정). 라운드 히스토리 바, FairnessVerifier 진입점(ProvablyFairBadge)은 셸에 내장.
- **모든 라운드 결과 옆에 검증 아이콘** → 클릭 시 server seed hash/reveal/nonce + 원클릭 인앱 재계산(stake는 외부로 보낸다 — 인앱 검증이 PF축 주장의 UI 증거물).
- Crash: canvas 곡선 + 중앙 대형 MultiplierDisplay, 버스트 시 셰이크 1회. 자동베팅은 서버 권위 — UI는 상태 구독만, "새로고침해도 자동베팅 유지"를 첫 사용 시 토스트로 고지.
- 베팅 전 30초 규칙 요약 진입점, PHON/USDT 베팅 통화 토글, 무료 체험(PHON_free) 진입점, 일일 loss limit 경고.
- 신규 게임 추가 = 캔버스 컴포넌트 1개 + 레지스트리 등록. 셸/BetPanel/Verifier는 수정 금지(개방-폐쇄).

### 6-6. 지갑 / 입출금 (저밀도 + 신뢰)
- 지갑 홈: 통화별 카드(available/locked 분리 표시), 원장 보기 CTA 상시(투명성 = 차별화).
- 입금: 네트워크 선택 → QR + 주소 복사(복사 시 체크 피드백) → "이 네트워크로만 전송" 경고를 앰버 박스로(회색 각주 금지). 입금 감지 시 confirmation 카운터(n/12)가 실시간으로 차오르는 표시 — 새로고침 연타를 없애는 핵심 UX. KRW 입금은 "원화 → PHON 환전" 흐름을 입금창/상태/알림 3곳에서 반복 고지(예상 PHON, 적용 환율 스냅샷, 수수료).
- 출금: 금액 입력 즉시 수수료/실수령액 분해 표시(rate snapshot 노출). KYC 미완 시 폼을 숨기지 말고 **잠금 오버레이 + "KYC 하러 가기"** — 해야 할 일을 명확히. 출금 상태는 StatusTimeline("처리중" 한 단어로 뭉개지 않기).
- 모든 상태 전환에 알림 연동(높은 우선순위: 입금확인/환전완료/출금승인).

### 6-7. Admin (1인 운영)
- §4의 IA 준수. 디자인 우선순위는 미학 < **스캔 속도**: 고정 컬럼 DataTable, 위험도 색 코딩, 행당 추천 액션.
- 모든 수동 액션 = AdminActionDialog(reason 필수) 경유, 감사 로그 자동 기록(기구현 패턴 유지).
- Kill switch 화면은 단순·가시·모바일 접근 가능(새벽 3시 시나리오).

---

## 7. 상태 4종 의무 (모든 화면)

| 상태 | 기준 |
|---|---|
| Loading | Skeleton(스피너는 버튼 내부 한정). CLS 0. |
| Empty | EmptyState — 설명 + 다음 행동 CTA. 빈 화면은 초대장이다. |
| Error | translateError 경유 i18n 메시지 + 복구 경로(재시도/지갑가기/고객지원). raw 에러 노출 금지. 에러는 사과하지 않고, 무엇이 잘못됐고 어떻게 고치는지만 말한다. |
| Success | 머니 변화는 토스트 + 잔액 트윈으로 이중 확인. 버튼 라벨과 토스트 동사 일치("스테이킹" 버튼 → "스테이킹 완료" 토스트). |

오프라인/네트워크 지연 상태 표시 필수(offline.html 연동, Realtime 끊김 시 "재연결 중" 인디케이터).

---

## 8. 모바일 OS급 / PC / 접근성

**모바일(우선)**: 375px 기준 설계 후 확장. `env(safe-area-inset-*)` 전 화면. 주요 CTA는 thumb zone(하단 고정 또는 Sheet). 터치 타깃 최소 44px. iOS 키보드/주소창 높이 변화 대응. pull-to-refresh는 지갑/원장/미션만. 입력 중 Sheet가 키보드에 가리지 않을 것.

**PC**: 멀티 패널 밀도(거래소급). 사이드바 + 상단 상태바, 지갑 잔액 상시 접근. 키보드 내비(Tab 순서, 모달 포커스 트랩 — Modal 프리미티브가 보장). 데이터 테이블은 PC에서 풀 컬럼, 모바일에서 카드 폴백.

**접근성(20~70대 = 전환율 직결)**: WCAG AA 대비. 색에만 의존한 정보 전달 금지(green/red에 +/− 부호, 화살표 병기). 동적 폰트 크기 깨지지 않을 것. 시각 포커스 링 유지.

---

## 9. 품질 판정 6기준 (모든 UI PR에 적용)

| 기준 | 질문 | 측정 |
|---|---|---|
| Clarity | 왕초보가 다음 행동을 3초 안에 아는가 | 화면당 주 CTA 1개 |
| Speed | 모바일에서 렉 없이 열리는가 | LCP<2.5s, INP 양호, 60fps |
| Trust | 원장/환율/상태가 투명한가 | rate snapshot 노출, 원장 접근 2탭 이내, Verifier 가시성 |
| Conversion | 가입→보상→첫 행동이 짧은가 | 가입 30초, 첫 보상까지 1분 |
| Safety | 고위험 행동 전 충분히 멈추는가 | ConfirmDialog 100% 커버 |
| Consistency | 전 표면이 한 제품으로 읽히는가 | 토큰 외 색 0건, 딥임포트 0건, styles.css 줄수 단조 감소 |

**lovable/v0 압살의 정의** = 위 표에서 6/6 + 실시간성(살아있는 데이터) + 상태 4종 완비. 컴포넌트가 더 화려한 게 아니다.

---

## 10. 작업 방식

1. **Preflight**: 기존 `@phonara/ui` 컴포넌트/토큰/i18n 키 검색 — 있으면 확장, 신규 중복 생성 금지. §5-2 컴포넌트는 0.7 검증 전 소비 금지.
2. **슬라이스 단위**: 한 번에 라우트 1개 또는 컴포넌트 1종 전역 교체(S3a~d 패턴 유지). 큰 리디자인 일괄 금지.
3. **토큰 먼저**: 새 시각 결정이 필요하면 `@theme` 등록 → 컴포넌트 → 페이지 순.
4. **시각 검증**: 변경 라우트는 visual.spec.ts 스크린샷 대상에 포함. 직접 스크린샷을 확인하고 자기 비평 후 마무리한다(빌드만 green이라고 끝이 아니다).
5. **E2E 동시 산출**: 고위험 UI 변경은 해당 Playwright 시나리오(pos+neg, ConfirmDialog 취소 경로, DB 보존 단언) 갱신과 같은 슬라이스에서.
6. **Build Log 기록**: 슬라이스 종료 즉시 — 무엇을/어떻게/오류→수정/게이트 결과/styles.css 잔여 줄수.

### UI 슬라이스 DoD
`typecheck` + `lint` + `check:i18n` + `check:release` + `test` + 관련 `test:e2e` green, 하드코딩 hex 0, JSX 한국어 0, 신규 인터랙션 testid 부여, 토스트/디버그/placeholder 잔재 0, 시각 스크린샷 확인 완료, §9 6기준 자가 채점 PASS.

---

## 11. 금지 목록 (요약)

하드코딩 hex · JSX 한국어 · `Number()` 금액 연산/표시 · localStorage 민감정보 · 라이트모드 · 보라 그라데이션 히어로 · 확인 없는 머니 버튼 · 스피너로 때운 초기 로딩 · 라이브 실측값처럼 오인되는 근거 없는 FOMO · 근거 없는 수익 보장 문구 · 장식용 green/red · 60fps 깨는 모션 · 딥임포트 · 페이지 우선 작업(토큰/프리미티브 미확정 상태에서) · happy path만 있는 화면 · 클라이언트 결과 계산.

---

## 12. 보고 형식 (매 UI 슬라이스 종료 시)

```text
슬라이스: <라우트/컴포넌트>
변경: <무엇을 어떻게>
토큰 변경: <@theme 추가/변경 또는 "없음">
@phonara/ui 변경: <신규/확장 컴포넌트 또는 "없음">
상태 4종: <loading/empty/error/success 처리 여부>
게이트: typecheck/lint/i18n/release/test/e2e 결과
시각 확인: <스크린샷 확인 소견 1줄>
styles.css 잔여: <줄수>
6기준: <PASS/항목별 미달>
다음 제안: <1줄>
```

---

## 변경 이력
- **v1.2** (2026-06-10): Wave 6 — deferred token fix 완료(`Sheet` backdrop `bg-bg/80`, `Slider` thumb `border-primary-fg`), casino shell/6 game routes/fairness docs 추가, `Toast`·`Skeleton`·`BetPanel`·`FairnessVerifier`·`GameStakeInput`·`MultiplierDisplay`·`ProvablyFairBadge`·`EmptyState`·`ErrorState`·`StatusTimeline`을 `@phonara/ui`에 승격.
- **v1.1.1** (2026-06-10): Wave 0.7 — §5-2 5종 §5-1 승격, 조건부 토큰 이연 항목 기록.
- **v1.1** (2026-06-10): docs 등재 확정본. 델타 3건 반영 — ① §5 컴포넌트 현황을 검증층(기존/0.7 대기/신규)으로 분리 ② Wave 6 산출물명 정렬(BetPanel·FairnessVerifier 정식 명칭 통일, GameStakeInput/MultiplierDisplay/ProvablyFairBadge 로드맵 편입) ③ 진실 공급원 우선순위를 통합 실행 계약 v1.1 기준 #4로 확정.
- v1.0: 최초 작성(UI/UX 마스터 프롬프트 원본).
