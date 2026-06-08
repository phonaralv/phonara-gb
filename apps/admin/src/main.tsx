import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { koMessages } from '@phonara/i18n';
import './styles.css';

const exceptionQueues = ['Deposits', 'Withdrawals', 'Risk Flags', 'Support'];

function AdminApp() {
  return (
    <main className="admin-shell">
      <aside>
        <strong>PHONARA Admin</strong>
        {exceptionQueues.map((item) => (
          <span key={item}>{item}</span>
        ))}
      </aside>
      <section>
        <p className="eyebrow">Phase 0</p>
        <h1>{koMessages['app.admin.phase0.title']}</h1>
        <p>{koMessages['app.admin.phase0.description']}</p>
      </section>
    </main>
  );
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <AdminApp />
  </StrictMode>,
);
