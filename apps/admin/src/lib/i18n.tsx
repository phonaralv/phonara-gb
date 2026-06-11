import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useState,
  type ReactNode,
} from 'react';
import {
  DEFAULT_LOCALE,
  translate,
  type Locale,
  type MessageKey,
} from '@phonara/i18n';

const STORAGE_KEY = 'phonara-admin.locale';

type TranslateFn = (key: MessageKey, vars?: Record<string, string | number>) => string;

interface I18nContextValue {
  locale: Locale;
  setLocale: (locale: Locale) => void;
  t: TranslateFn;
}

const I18nContext = createContext<I18nContextValue | null>(null);

function readInitialLocale(): Locale {
  if (typeof window === 'undefined') return DEFAULT_LOCALE;
  const stored = window.localStorage.getItem(STORAGE_KEY);
  if (stored === 'ko' || stored === 'en') return stored;
  const nav = window.navigator.language.toLowerCase();
  return nav.startsWith('en') ? 'en' : DEFAULT_LOCALE;
}

export function I18nProvider({ children }: { children: ReactNode }) {
  const [locale, setLocaleState] = useState<Locale>(readInitialLocale);

  const setLocale = useCallback((next: Locale) => {
    setLocaleState(next);
    if (typeof window !== 'undefined') {
      window.localStorage.setItem(STORAGE_KEY, next);
      document.documentElement.lang = next;
    }
  }, []);

  const t = useCallback<TranslateFn>(
    (key, vars) => translate(locale, key, vars),
    [locale],
  );

  const value = useMemo<I18nContextValue>(() => ({ locale, setLocale, t }), [locale, setLocale, t]);

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n(): I18nContextValue {
  const ctx = useContext(I18nContext);
  if (!ctx) throw new Error('useI18n must be used within <I18nProvider>');
  return ctx;
}

export function useT(): TranslateFn {
  return useI18n().t;
}
