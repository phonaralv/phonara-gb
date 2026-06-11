import type { ReactNode } from 'react';
import { useT } from '../lib/i18n';

type BadgeProps = {
  icon: ReactNode;
  labelKey: 'auth.entry.trust.wallet' | 'auth.entry.trust.korea' | 'auth.entry.trust.participation';
};

function Badge({ icon, labelKey }: BadgeProps) {
  const t = useT();
  return (
    <li className="flex items-center gap-3 rounded-xl border border-border/60 bg-card/40 px-4 py-3 backdrop-blur-sm">
      <span
        aria-hidden="true"
        className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-primary/10 text-primary"
      >
        {icon}
      </span>
      <span className="text-sm font-medium text-foreground">{t(labelKey)}</span>
    </li>
  );
}

export function AuthTrustBadges() {
  return (
    <ul className="grid gap-2" aria-label="trust">
      <Badge
        labelKey="auth.entry.trust.wallet"
        icon={
          <svg
            width="18"
            height="18"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <path d="M12 2 4 5v6c0 5 3.4 9.4 8 11 4.6-1.6 8-6 8-11V5l-8-3Z" />
            <path d="m9 12 2 2 4-4" />
          </svg>
        }
      />
      <Badge
        labelKey="auth.entry.trust.korea"
        icon={
          <svg
            width="18"
            height="18"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <circle cx="12" cy="12" r="9" />
            <path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18" />
          </svg>
        }
      />
      <Badge
        labelKey="auth.entry.trust.participation"
        icon={
          <svg
            width="18"
            height="18"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <path d="M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83" />
          </svg>
        }
      />
    </ul>
  );
}
