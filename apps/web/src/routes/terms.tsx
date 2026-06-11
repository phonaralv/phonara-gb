import { createRoute } from '@tanstack/react-router';
import { Route as rootRoute } from './__root';
import { LegalPage, type LegalSection } from '../components/legal-page';

const EFFECTIVE_DATE = '2026-06-11';

const SECTIONS: LegalSection[] = [
  { id: 'terms-s1', title: 'legal.terms.s1.title', body: 'legal.terms.s1.body' },
  { id: 'terms-s2', title: 'legal.terms.s2.title', body: 'legal.terms.s2.body' },
  { id: 'terms-s3', title: 'legal.terms.s3.title', body: 'legal.terms.s3.body' },
  { id: 'terms-s4', title: 'legal.terms.s4.title', body: 'legal.terms.s4.body' },
  { id: 'terms-s5', title: 'legal.terms.s5.title', body: 'legal.terms.s5.body' },
  { id: 'terms-s6', title: 'legal.terms.s6.title', body: 'legal.terms.s6.body' },
  { id: 'terms-s7', title: 'legal.terms.s7.title', body: 'legal.terms.s7.body' },
  { id: 'terms-s8', title: 'legal.terms.s8.title', body: 'legal.terms.s8.body' },
  { id: 'terms-s9', title: 'legal.terms.s9.title', body: 'legal.terms.s9.body' },
  { id: 'terms-s10', title: 'legal.terms.s10.title', body: 'legal.terms.s10.body' },
  { id: 'terms-s11', title: 'legal.terms.s11.title', body: 'legal.terms.s11.body' },
  { id: 'terms-s12', title: 'legal.terms.s12.title', body: 'legal.terms.s12.body' },
];

function TermsPage() {
  return (
    <LegalPage
      title="legal.terms.title"
      intro="legal.terms.intro"
      effectiveDate={EFFECTIVE_DATE}
      sections={SECTIONS}
    />
  );
}

export const Route = createRoute({
  getParentRoute: () => rootRoute,
  path: '/terms',
  component: TermsPage,
});
