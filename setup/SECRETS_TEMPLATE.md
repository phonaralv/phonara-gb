# PHONARA v2 — 시크릿/키 수집 메모

> ⚠️ 이 파일에 실제 키를 입력하지 마세요. git에 절대 커밋 금지.
> 실제 값은 .env.local 또는 Supabase Dashboard에만 입력하세요.
> 이 파일은 "어디서 뭘 가져와야 하는지" 확인용 참조 문서입니다.

---

## Supabase Dashboard에서 복사

URL: https://supabase.com/dashboard/project/yocjhjsdwoijfdrehzoq/settings/api

| 항목 | Dashboard 위치 | .env.local 변수명 |
|------|----------------|------------------|
| Project URL | Project Settings → API → URL | `VITE_SUPABASE_URL` |
| anon public key | Project Settings → API → `anon` `public` | `VITE_SUPABASE_ANON_KEY` |
| service_role key | Project Settings → API → `service_role` `secret` | **서버/CI 전용, 클라 금지** |

---

## .env.local (앱 루트에 생성)

```env
VITE_APP_NAME=PHONARA
VITE_APP_ENV=local
VITE_APP_URL=http://localhost:3000
VITE_SUPABASE_URL=https://yocjhjsdwoijfdrehzoq.supabase.co
VITE_SUPABASE_ANON_KEY=<여기에 anon key 붙여넣기>
VITE_DEFAULT_LOCALE=ko
VITE_SUPPORTED_LOCALES=ko,en
```

---

## Supabase Edge Function Secrets

URL: https://supabase.com/dashboard/project/yocjhjsdwoijfdrehzoq/functions

함수: `liquidation-worker` → Secrets 탭

| 이름 | 생성 방법 |
|------|----------|
| `CRON_SECRET` | 터미널에서 `openssl rand -hex 32` 실행 후 복사 |

---

## GitHub Secrets (CI/CD 구현 시)

URL: https://github.com/<your-repo>/settings/secrets/actions

| 이름 | 값 |
|------|-----|
| `SUPABASE_PROJECT_ID` | `yocjhjsdwoijfdrehzoq` |
| `SUPABASE_SERVICE_ROLE_KEY` | Dashboard → API → service_role key |
| `SUPABASE_ACCESS_TOKEN` | supabase.com → 우측 상단 프로필 → Access Tokens |
| `SUPABASE_DB_PASSWORD` | Dashboard → Project Settings → Database → Database password |
| `VITE_SUPABASE_ANON_KEY` | Dashboard → API → anon public key |

---

## VAPID 키 (PWA Web Push 구현 시)

```bash
# 생성 명령어
npx web-push generate-vapid-keys --encoding base64
```

출력 결과를 아래에 메모 (이 파일은 커밋 금지):
- Public Key → `VITE_VAPID_PUBLIC_KEY` (.env.local + 배포 플랫폼)
- Private Key → Supabase Edge Function Secret `VAPID_PRIVATE_KEY` (서버 전용)
