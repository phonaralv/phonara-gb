import { Link } from '@tanstack/react-router';
import type { MessageKey } from '@phonara/i18n';
import { useT } from '../lib/i18n';

export interface LegalSection {
  id: string;
  title: MessageKey;
  body: MessageKey;
}

interface LegalPageProps {
  title: MessageKey;
  intro: MessageKey;
  effectiveDate: string;
  sections: LegalSection[];
}

/**
 * App-local readable document layout for legal pages (terms / privacy). Kept in
 * apps/web because it is tightly coupled to the `legal.*` product copy and the
 * app's route structure; it is not a generic design-system primitive.
 */
export function LegalPage({ title, intro, effectiveDate, sections }: LegalPageProps) {
  const t = useT();

  return (
    <main className="min-h-dvh bg-bg text-fg">
      <div className="mx-auto w-full max-w-3xl px-5 py-12 sm:px-8 sm:py-16">
        <Link
          to="/login"
          className="text-sm font-medium text-primary hover:underline focus-visible:underline"
        >
          {t('legal.back')}
        </Link>

        <header className="mt-6 border-b border-border pb-6">
          <h1 className="text-3xl font-semibold tracking-tight">{t(title)}</h1>
          <p className="mt-2 text-sm text-muted">
            {t('legal.effectiveDate', { date: effectiveDate })}
          </p>
          <p className="mt-4 text-sm leading-relaxed text-muted">{t(intro)}</p>
        </header>

        <div className="mt-8 flex flex-col gap-8">
          {sections.map((section, index) => (
            <section key={section.id} aria-labelledby={`${section.id}-title`}>
              <h2 id={`${section.id}-title`} className="text-lg font-semibold text-fg">
                {index + 1}. {t(section.title)}
              </h2>
              <p className="mt-3 text-sm leading-relaxed text-muted">{t(section.body)}</p>
            </section>
          ))}
        </div>

        <footer className="mt-12 border-t border-border pt-6 text-sm text-muted">
          {t('legal.contactBody')}
        </footer>
      </div>
    </main>
  );
}

LegalPage.displayName = 'LegalPage';
