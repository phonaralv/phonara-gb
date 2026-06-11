# PHONARA v2 — 수동 작업 목록

> AI가 자동으로 처리할 수 없는 작업만 모았습니다.
> 항목마다 완료 시 `[x]`로 체크하세요.

---

## 1. 로컬 개발 환경 (.env.local)

앱 루트(`c:\Users\PC\Desktop\phonara-gb`)에 `.env.local` 파일을 생성하세요.
`.env.example`을 복사한 뒤 아래 값을 채우면 됩니다.

```bash
cp .env.example .env.local
```

| 변수 | 설명 | 어디서 얻나 |
|------|------|------------|
| `VITE_SUPABASE_ANON_KEY` | 클라이언트용 공개 키 | Supabase Dashboard → Project Settings → API → `anon public` |
| `VITE_SUPABASE_URL` | 이미 `.env.example`에 있음 (`https://yocjhjsdwoijfdrehzoq.supabase.co`) | 그대로 사용 |

- [ ] `.env.local` 파일 생성 + `VITE_SUPABASE_ANON_KEY` 입력

---

## 2. 자동청산 러너 — ✅ 자동화 완료 (수동 작업 불필요)

> **상태: 완료.** 마이그레이션 `20260609000015_p0_liquidation_cron_runner`로
> pg_cron이 `rpc_run_liquidations()`를 **매 1분 자동 실행**하도록 원격(prod)에
> 등록·활성화했습니다. 엣지함수 배포나 별도 시크릿 없이 DB 안에서 동작합니다.
> 더 이상 수동 작업이 필요 없습니다.

확인 방법(원할 때):
```sql
-- Supabase Dashboard → SQL Editor에서 실행
SELECT jobname, schedule, active FROM cron.job WHERE jobname = 'phonara_auto_liquidations';
-- 실제 청산이 발생한 기록(활동 있을 때만 적재)
SELECT * FROM liquidation_run_log ORDER BY ran_at DESC LIMIT 20;
-- pg_cron 자체 실행 로그(매 분 실행 여부)
SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 20;
```

### Edge Function 이중화 — 제거됨 (S1 정리)

`supabase/functions/liquidation-worker`는 삭제됨 (S1 스케줄러 일원화).
pg_cron이 유일한 청산 실행 경로입니다. 이중 경로로 인한 동시 정산 리스크를
없애기 위해 edge function 코드를 제거했습니다.

청산이 동작하는지 확인하려면:
```sql
SELECT jobname, schedule, active FROM cron.job WHERE jobname = 'phonara_auto_liquidations';
SELECT * FROM liquidation_run_log ORDER BY ran_at DESC LIMIT 20;
```

---

## 3. Supabase Auth 설정

### 3-1. Admin MFA 강제 (`admin-mfa-hibp` 작업 시 필요)

앱은 프로덕션 Admin route에서 Supabase AAL2(MFA 완료 세션)를 요구합니다.
Dashboard에서 아래 설정이 끝나야 운영자가 접근할 수 있습니다.

Supabase Dashboard → Authentication → **MFA (Multi-Factor Auth)**:

- [ ] TOTP 활성화 (Google Authenticator / Authy 등)
- [ ] 관리자 계정에 MFA 등록
- [ ] 프로덕션 Admin 로그인 후 MFA challenge 완료 상태로 `/overview` 접근 확인

### 3-2. HIBP 비밀번호 유출 감지

Supabase Dashboard → Authentication → **Password Policies**:

- [ ] "Check for compromised passwords (HIBP)" 활성화
- [ ] Auth logs에서 유출 비밀번호 거부 이벤트가 기록되는지 확인

### 3-3. 프로덕션 사이트 URL 설정

Supabase Dashboard → Authentication → **URL Configuration**:

- [ ] `Site URL`을 실제 도메인으로 변경 (현재 `http://localhost:3000`)
- [ ] `Redirect URLs`에 프로덕션 도메인 추가

---

## 4. Supabase DB Extension 활성화

현재 자동청산에 필요한 `pg_cron` 경로는 마이그레이션 `000015`로 원격 등록 완료.

> Dashboard 방식 대신 AI가 마이그레이션으로 처리 가능하지만,
> 일부 Supabase tier에서 extension 활성화는 직접 필요합니다.

Supabase Dashboard → Database → **Extensions**:

| Extension | 용도 | 우선순위 |
|-----------|------|---------|
| `pg_cron` | SQL 레벨 주기적 실행 (청산 러너) | 완료 확인용/재설치 필요 시만 |
| `pg_net` | SQL에서 HTTP 요청 (Edge Function 백업 경로) | 선택사항 |

- [ ] (선택) `pg_cron` 활성화
- [ ] (선택) `pg_net` 활성화

---

## 5. 프로덕션 배포 환경 (호스팅 시)

Vercel / Netlify / 기타 배포 플랫폼에서 환경 변수 등록:

| 변수 | 값 |
|------|----|
| `VITE_SUPABASE_URL` | `https://yocjhjsdwoijfdrehzoq.supabase.co` |
| `VITE_SUPABASE_ANON_KEY` | Supabase Dashboard → API → anon public key |
| `VITE_APP_ENV` | `production` |
| `VITE_APP_URL` | `https://실제도메인.com` |
| `VITE_DEFAULT_LOCALE` | `ko` |

- [ ] 배포 플랫폼에 모든 환경 변수 등록

---

## 6. GitHub Secrets (CI/CD 구현 시)

`ci-pipeline` 작업이 시작될 때 GitHub Repo → Settings → **Secrets and variables → Actions**에 등록:

| 시크릿 이름 | 값 | 어디서 얻나 |
|------------|-----|------------|
| `SUPABASE_PROJECT_ID` | `yocjhjsdwoijfdrehzoq` | 고정값 |
| `SUPABASE_SERVICE_ROLE_KEY` | service_role 키 | Supabase Dashboard → Project Settings → API |
| `SUPABASE_ACCESS_TOKEN` | Personal Access Token | supabase.com → Account → Access Tokens |
| `SUPABASE_DB_PASSWORD` | DB 비밀번호 | Supabase Dashboard → Project Settings → Database |
| `VITE_SUPABASE_ANON_KEY` | anon 키 | Supabase Dashboard → API |

> **CI `advisors` 잡 필수**: `.github/workflows/ci.yml`의 `advisors` 잡은
> `SUPABASE_ACCESS_TOKEN` + `SUPABASE_PROJECT_ID` 시크릿으로 보안 advisor 0 ERROR를
> 강제합니다. 두 시크릿이 없으면 게이트가 SKIP(green)되어 강제력이 사라지므로, 메인
> 레포에는 반드시 등록하세요(포크 PR은 시크릿 미노출이라 자동 SKIP).

- [ ] GitHub Secrets 등록 (`SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_ID` 포함)

---

## 7. Web Push / VAPID 키 (PWA 구현 시)

`pwa-platform` 작업 시 필요. 지금은 준비만 해두세요.

```bash
# VAPID 키 생성 (Node.js 설치 필요)
npx web-push generate-vapid-keys
```

출력 예시:
```
Public Key:  BIu...
Private Key: WlJ...
```

| 환경 변수 | 위치 |
|----------|------|
| `VITE_VAPID_PUBLIC_KEY` | `.env.local` + 배포 플랫폼 |
| `VAPID_PRIVATE_KEY` | Supabase Edge Function Secret (서버 전용, 클라 번들 금지!) |

- [ ] (PWA 작업 전) VAPID 키 생성
- [ ] `VITE_VAPID_PUBLIC_KEY` → `.env.local` 등록
- [ ] `VAPID_PRIVATE_KEY` → Supabase Edge Function Secret 등록

---

## 8. 로컬 Supabase (Docker) 개발 환경

AI가 로컬 테스트 시 사용하는 Docker 기반 로컬 Supabase입니다.

```bash
# 사전 조건: Docker Desktop 실행 상태

# 로컬 스택 시작
supabase start

# 마이그레이션 초기화 (테스트 DB 초기화)
supabase db reset

# SQL 통합 테스트 실행
bun run test:sql
```

- [ ] Docker Desktop 설치 확인
- [ ] `supabase start` 최초 1회 실행 (첫 실행은 이미지 다운로드로 시간 소요)

---

## 9. Supabase Remote 마이그레이션 적용 현황

> AI가 마이그레이션 파일을 작성한 후 직접 MCP로 원격 적용합니다.
> 수동 확인용 레퍼런스.

| 마이그레이션 | 내용 | 원격 적용 |
|------------|------|---------|
| `000001` ~ `000010` | Phase1~P0 기초 스키마/RPC | ✅ 완료 |
| `000011` | 보상 보존 수정 | ✅ 완료 |
| `000012` | anon oracle/liquidate 차단 | ✅ 완료 |
| `000013` | advisor cleanup (anon REVOKE + search_path) | ✅ 완료 |
| `000014` | 보상 발행 명시 화이트리스트 (substring LIKE 제거) | ✅ 완료 |
| `000015` | 자동청산 pg_cron 러너 (매 1분) | ✅ 완료 |
| `000016` | SQL RPC 입력 정규식 가드 | ✅ 완료 |
| `000017` | 해시체인 페이로드 v2 | ✅ 완료 |
| `000018` | 전역 system-live / readonly 가드 | ✅ 완료 |
| `000019` | 기능별 kill switch | ✅ 완료 |
| `000020` | 포지션 수 상한 + 마켓 OI cap | ✅ 완료 |
| `000021` | 요청 단위 멱등(client_request_id) | ✅ 완료 |
| `000022` | 청산 가드 + 이력 closeout | ✅ 완료 |
| `000023` | 가입 트리거 search_path 버그 수정 | ✅ 완료 |
| `000024` | Admin 감사 RLS | ✅ 완료 |
| `000025` | rpc_complete_mission 무료머니 홀 봉인 (S1 Critical) | 🔲 원격 적용 필요 |

---

## 10. 빠른 확인 명령어 모음

```bash
# 로컬 Supabase 상태 확인
supabase status

# 원격 마이그레이션 목록 확인
supabase migration list --project-ref yocjhjsdwoijfdrehzoq

# liquidation-worker 수동 테스트 (SERVICE_ROLE_KEY 필요)
curl -X POST https://yocjhjsdwoijfdrehzoq.supabase.co/functions/v1/liquidation-worker \
  -H "Authorization: Bearer <SERVICE_ROLE_KEY>"

# 빌드/테스트 게이트 (AI가 자동 실행)
bun run typecheck
bun run check:i18n
bun run test
bun run build
```

---

## 우선순위 요약

```
지금 당장 필요한 것 (개발/테스트)
  1. [ ] .env.local → VITE_SUPABASE_ANON_KEY 입력
  2. [ ] Docker Desktop 설치 (로컬 테스트용)

청산 러너 활성화
  ✅ 완료 — pg_cron 마이그레이션으로 자동화됨 (수동 작업 없음)

나중에 (AI가 코드 완성 후 / 출시 직전)
  3. [ ] MFA + HIBP Auth 설정
  4. [ ] 프로덕션 배포 환경 변수
  5. [ ] GitHub Secrets (CI/CD)
  6. [ ] VAPID 키 (PWA)
```
