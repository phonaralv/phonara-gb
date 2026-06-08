# Environment Setup

## Required Local Values

```env
VITE_APP_NAME=PHONARA
VITE_APP_ENV=local
VITE_APP_URL=http://localhost:3000
VITE_SUPABASE_URL=https://yocjhjsdwoijfdrehzoq.supabase.co
VITE_SUPABASE_ANON_KEY=your_supabase_anon_key_here
VITE_DEFAULT_LOCALE=ko
VITE_SUPPORTED_LOCALES=ko,en
```

## Security Rules

- `.env` and `.env.local` are never committed.
- `VITE_` values are visible in the browser.
- `SUPABASE_SERVICE_ROLE_KEY` is server-only and must never be added to frontend env.
- Missing env values should fail early with a clear message.

## Confirmed Supabase Project

- URL: `https://yocjhjsdwoijfdrehzoq.supabase.co`
- Project ref: `yocjhjsdwoijfdrehzoq`
