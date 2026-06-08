const requiredClientEnv = ['VITE_SUPABASE_URL', 'VITE_SUPABASE_ANON_KEY'] as const;

const missing = requiredClientEnv.filter((key) => !process.env[key]);

if (missing.length > 0) {
  console.warn(`Missing local env values: ${missing.join(', ')}`);
  console.warn('Create .env from .env.example before running the app against Supabase.');
}

for (const key of Object.keys(process.env)) {
  if (key.startsWith('VITE_') && key.includes('SERVICE_ROLE')) {
    throw new Error('Service role keys must never be exposed through VITE_ env values.');
  }
}
