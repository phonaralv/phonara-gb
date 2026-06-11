import { createRoute } from '@tanstack/react-router';
import { Route as rootRoute } from './__root';
import { LegalPage, type LegalSection } from '../components/legal-page';

const EFFECTIVE_DATE = '2026-06-11';

const SECTIONS: LegalSection[] = [
  { id: 'privacy-s1', title: 'legal.privacy.s1.title', body: 'legal.privacy.s1.body' },
  { id: 'privacy-s2', title: 'legal.privacy.s2.title', body: 'legal.privacy.s2.body' },
  { id: 'privacy-s3', title: 'legal.privacy.s3.title', body: 'legal.privacy.s3.body' },
  { id: 'privacy-s4', title: 'legal.privacy.s4.title', body: 'legal.privacy.s4.body' },
  { id: 'privacy-s5', title: 'legal.privacy.s5.title', body: 'legal.privacy.s5.body' },
  { id: 'privacy-s6', title: 'legal.privacy.s6.title', body: 'legal.privacy.s6.body' },
  { id: 'privacy-s7', title: 'legal.privacy.s7.title', body: 'legal.privacy.s7.body' },
  { id: 'privacy-s8', title: 'legal.privacy.s8.title', body: 'legal.privacy.s8.body' },
  { id: 'privacy-s9', title: 'legal.privacy.s9.title', body: 'legal.privacy.s9.body' },
  { id: 'privacy-s10', title: 'legal.privacy.s10.title', body: 'legal.privacy.s10.body' },
];

function PrivacyPage() {
  return (
    <LegalPage
      title="legal.privacy.title"
      intro="legal.privacy.intro"
      effectiveDate={EFFECTIVE_DATE}
      sections={SECTIONS}
    />
  );
}

export const Route = createRoute({
  getParentRoute: () => rootRoute,
  path: '/privacy',
  component: PrivacyPage,
});
