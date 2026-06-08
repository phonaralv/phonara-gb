import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { koMessages } from '@phonara/i18n';
import './styles.css';

function App() {
  return (
    <main className="shell">
      <section className="hero">
        <p className="eyebrow">PHONARA v2</p>
        <h1>{koMessages['app.web.phase0.title']}</h1>
        <p>{koMessages['app.web.phase0.description']}</p>
        <div className="grid">
          <article>
            <h2>PHON</h2>
            <p>Reward-first wallet economy.</p>
          </article>
          <article>
            <h2>USDT</h2>
            <p>Trading and game settlement support.</p>
          </article>
          <article>
            <h2>KRW</h2>
            <p>Korean bank transfer entry point.</p>
          </article>
        </div>
      </section>
    </main>
  );
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
