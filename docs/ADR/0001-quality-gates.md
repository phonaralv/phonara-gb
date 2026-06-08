# ADR 0001: Quality Gates First

## Status

Accepted

## Context

PHONARA includes money, games, trading, withdrawals, and Admin automation. Defects in these areas can create trust and financial failures.

## Decision

Phase 0 establishes governance, strict TypeScript, tests, env checks, i18n checks, and cleanup before domain engine implementation.

## Consequences

Implementation may feel slower at first, but later engine and UI work will be safer and easier to verify.
