# Reference Repositories

This file preserves external reference repositories and implementation references recovered from earlier PHONARA planning chats.

## Source of Truth

- Product direction: `docs/PHONARA_V2_MASTER_PLAN.md`
- This file is only a reference index.
- References are for analysis and redesign, not copying.

## Non-Negotiable Rules

- Do not copy code blindly.
- Check licenses before adopting ideas.
- Analyze architecture and adapt it to PHONARA.
- Keep PHONARA's money path server-authoritative and ledger-backed.
- Never import client-side balance mutation patterns from demo repos.
- Preserve the core product direction in `docs/PHONARA_V2_MASTER_PLAN.md`.

## Recovered Reference Set

| Repository | Category | Use For | Do Not Use For |
|------------|----------|---------|----------------|
| [litmajor/Velocity](https://github.com/litmajor/Velocity) | Crash server engine | Event-driven Crash architecture, WebSocket rhythm, tick/audit concepts, global round comparison | Direct wallet model, JSON persistence, production money path |
| [akashmahlaz/aviator-crash](https://github.com/akashmahlaz/aviator-crash) | Aviator-style Crash demo | Aviator-style visual/Socket.io UX ideas, room/chat feel | Client balance mutation, production settlement, security model |
| [tanh1c/stake-originals-clone](https://github.com/tanh1c/stake-originals-clone) | Stake Originals-style UI and provably fair demos | Crash/Plinko/Mines-style UI polish, fairness modal UX, stats/history patterns | Browser-only wallet, copied PF formulas without verification, money logic |
| [xtoshi999/Crash-Game-Frontend](https://github.com/xtoshi999/Crash-Game-Frontend) | Multiplayer Crash frontend | Phaser/Web3-style multiplayer presentation, joined-player UX, countdown/chat patterns | External backend assumptions, Solana-specific architecture unless intentionally adopted later |
| [Vilyard/casino-lobby](https://github.com/Vilyard/casino-lobby) | Casino lobby UI | Lobby cards, filters, search, glassmorphism/card-grid ideas | Game engines, wallet/settlement, security |
| [TanStack Start Bun server example](https://github.com/TanStack/router/blob/main/examples/react/start-bun/server.ts) | Runtime/server reference | Bun + TanStack Start deployment/server patterns | Product/domain behavior |

## V2 Reference Set Provided by User

The repositories below are additional V2 references provided by the user after Phase 0. The final product plan in `docs/PHONARA_V2_MASTER_PLAN.md` is treated as the strategic synthesis of these references. Use this section to preserve the source material and to prevent future agents from copying unsafe patterns.

### Authentication

| Repository | Use For | Priority | Notes |
|------------|---------|----------|-------|
| [wpcodevo/nextjs14-supabase-ssr-authentication](https://github.com/wpcodevo/nextjs14-supabase-ssr-authentication) | Supabase SSR Auth, cookie/session flow, server/client auth boundaries | High | Next.js-focused; adapt concepts to PHONARA's stack rather than copying file structure. |
| [SarathAdhi/next-supabase-auth](https://github.com/SarathAdhi/next-supabase-auth) | Supabase + shadcn auth starter UX | Medium | Useful for auth forms and component patterns. |
| [Vercel with-supabase example](https://github.com/vercel/next.js/tree/canary/examples/with-supabase) | Official Supabase auth template, cookie-based auth, env naming | High | Prefer this over older community starters for modern SSR auth behavior. |
| [stefandunn/nextjs-supabase](https://github.com/stefandunn/nextjs-supabase) | AuthWrapper/starter pattern reference | Low | Older 2022 starter; verify current relevance before using. |

### UI/UX Design System

| Repository | Use For | Priority | Notes |
|------------|---------|----------|-------|
| [shadcn-ui/ui](https://github.com/shadcn-ui/ui) | Component primitives and design-system conventions | High | Use as a component pattern source, not as product direction. |
| [birobirobiro/awesome-shadcn-ui](https://github.com/birobirobiro/awesome-shadcn-ui) | Discovery of shadcn ecosystem components | Medium | Use to find component ideas; vet each dependency. |
| [abderrahimghazali/shadcn-fintech](https://github.com/abderrahimghazali/shadcn-fintech) | Fintech dashboard cards, live ticker feel, financial UI rhythm | Medium | Good visual reference for wallet/admin/dashboard surfaces. |
| [cenksari/react-crypto-exchange](https://github.com/cenksari/react-crypto-exchange) | Crypto exchange UI layout, trading panels | Medium | UI reference only; trading engine remains PHONARA-native. |

### Casino Engine

| Repository | Use For | Priority | Notes |
|------------|---------|----------|-------|
| [Casino-Crash-Game/aviator-crash](https://github.com/Casino-Crash-Game/aviator-crash) | Full-stack Crash/Aviator reference | Medium | Analyze architecture and safety before use. Do not import unsafe money paths. |
| [LaChance-Lab/solana-casino-games-evm-web3](https://github.com/LaChance-Lab/solana-casino-games-evm-web3) | Multi-game casino coverage and Web3 game concepts | Medium | Broad reference for 10-game scope; PHONARA starts with safer tested engines. |
| [goldenratio/crash-server](https://github.com/goldenratio/crash-server) | Provably fair Crash server concepts | Medium | Server/PF reference; verify formulas and license before adopting ideas. |
| [caterpillardev/rocket-crash-game](https://github.com/caterpillardev/rocket-crash-game) | Referral and Crash UI reference | Low | Use for UX/referral inspiration, not settlement. |

### Trading Engine

| Repository | Use For | Priority | Notes |
|------------|---------|----------|-------|
| [jogeshwar01/exchange](https://github.com/jogeshwar01/exchange) | Matching engine concepts | Medium | Rust engine architecture reference only; PHONARA initial engine is TS/Decimal/ledger backed. |
| [crypto-zero/apex-engine](https://github.com/crypto-zero/apex-engine) | Lock-free/high-performance architecture concepts | Low | Advanced performance reference, not Phase 1 implementation target. |
| [nautechsystems/nautilus_trader](https://github.com/nautechsystems/nautilus_trader) | Perpetual/trading system design ideas | Medium | Large professional framework; extract concepts carefully. |
| [QuantConnect/Lean](https://github.com/QuantConnect/Lean) | Algorithmic trading engine concepts | Low | Useful for long-term strategy/testing ideas; too broad for early PHONARA. |

### Charts and Orderbook

| Repository | Use For | Priority | Notes |
|------------|---------|----------|-------|
| [tradingview/lightweight-charts](https://github.com/tradingview/lightweight-charts) | Production-grade lightweight charting | High | Strong candidate for PHONARA trading charts. |
| [tradingview/charting-library-examples](https://github.com/tradingview/charting-library-examples) | React/chart integration examples | Medium | Use only if compatible with licensing and product constraints. |
| [jose-donato/crypto-orderbook](https://github.com/jose-donato/crypto-orderbook) | Full-stack orderbook patterns | Medium | UI/data-flow reference; actual settlement remains PHONARA ledger. |
| [kysley/react-orderbook](https://github.com/kysley/react-orderbook) | Web Worker orderbook UI pattern | Medium | Useful for performance-minded frontend orderbook display. |

### Exchange Backend

| Repository | Use For | Priority | Notes |
|------------|---------|----------|-------|
| [Polygant/OpenCEX](https://github.com/Polygant/OpenCEX) | Fiat deposit/withdrawal and exchange backend concepts | Medium | Reference only; PHONARA uses its own KRW/PHON/USDT ledger rules. |
| [FlipSideHR/FlyptoX](https://github.com/FlipSideHR/FlyptoX) | Node.js exchange full-stack patterns | Low | Broad exchange reference; verify architecture and license before using ideas. |

### Token Contracts

| Repository / Docs | Use For | Priority | Notes |
|-------------------|---------|----------|-------|
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | Token contract best practices | High | Preferred baseline for any future ERC20-style PHON contract. |
| [OpenZeppelin ERC20 Docs](https://docs.openzeppelin.com/contracts/5.x/erc20) | ERC20 design and decimals guidance | High | Use for token education and future contract planning. |
| [coinbase/extended-optimism-mintable-token](https://github.com/coinbase/extended-optimism-mintable-token) | Optimism mintable token extension ideas | Low | Future chain expansion candidate only. |
| [TRON TIP-20](https://github.com/tronprotocol/tips/blob/master/tip-20.md) | TRC20/TRON standard awareness | Low | Future TRON expansion reference only. |

## Detailed Reference Notes

### Velocity

- URL: `https://github.com/litmajor/Velocity`
- Earlier comparison classified this as a strong Crash server-engine reference.
- Useful patterns:
  - Event-driven server shape.
  - WebSocket broadcast cadence.
  - Global shared round architecture comparison.
  - Tick ledger / dispute audit concepts.
- PHONARA decision:
  - Use only as architecture inspiration.
  - PHONARA settlement must remain Supabase RPC + append-only ledger backed.
  - Any shared-round model requires an ADR before implementation.

### aviator-crash

- URL: `https://github.com/akashmahlaz/aviator-crash`
- Earlier comparison classified this as an Aviator UI/Socket.io demo.
- Useful patterns:
  - Aviator-style visual flow.
  - Multiplayer room feel.
  - Basic live UI interaction ideas.
- PHONARA decision:
  - Do not reuse unsafe client-side balance handling.
  - Treat as UX demo only.

### stake-originals-clone

- URL: `https://github.com/tanh1c/stake-originals-clone`
- Notable files discovered earlier:
  - `src/components/CrashGame/CrashGame.jsx`
  - `src/utils/ProvablyFair.js`
- Useful patterns:
  - Crash UI layout.
  - Stats drawer / history strip / fullscreen UX ideas.
  - Provably Fair explanation and modal presentation.
  - Plinko/Mines-style game UI references.
- PHONARA decision:
  - Good UI polish reference.
  - Do not inherit browser-local wallet or client-authoritative settlement.
  - PF math must be verified with PHONARA server-side tests before use.

### Crash-Game-Frontend

- URL: `https://github.com/xtoshi999/Crash-Game-Frontend`
- Earlier comparison referred to this as FutureSea.
- Useful patterns:
  - Phaser-based crash presentation.
  - Joined players, countdown, chat, and social UX.
  - Multiplayer frontend feel.
- PHONARA decision:
  - Use for optional multiplayer/social UX exploration.
  - Do not adopt chain-specific or external API assumptions by default.

### casino-lobby

- URL: `https://github.com/Vilyard/casino-lobby`
- Useful patterns:
  - Lobby card grid.
  - Search/filter/favorites UX.
  - Visual polish for casino entry points.
- PHONARA decision:
  - Use for lobby presentation only.
  - Game engines and settlement remain PHONARA-owned.

### TanStack Start Bun Server Example

- URL: `https://github.com/TanStack/router/blob/main/examples/react/start-bun/server.ts`
- Useful patterns:
  - Bun runtime server setup.
  - TanStack Start server deployment reference.
- PHONARA decision:
  - Use only for server/runtime setup if TanStack Start custom serving is needed.

## Implementation Workflow Before Engine Work

Before implementing Crash, Limbo, Dice, Mines, HiLo, Plinko, wallet ledger, or trading engine logic:

1. Re-read `docs/PHONARA_V2_MASTER_PLAN.md`.
2. Re-read the relevant domain doc:
   - `docs/WALLET_LEDGER.md`
   - `docs/TRADING_ENGINE.md`
   - `docs/GAME_ENGINE.md`
3. Re-read this reference file.
4. Check each referenced repository license.
5. Decide what is:
   - safe to learn from,
   - unsafe and forbidden,
   - requiring an ADR,
   - requiring user approval.
6. Implement PHONARA-native logic with tests.

## License Verification Log (Wave 0.4 — 2026-06-10)

Primary references used for Phase 4 casino planning were checked for adoptability (ideas only; no money-path copy):

| Repository | License (public) | Wave 0 verdict |
|---|---|---|
| goldenratio/crash-server | MIT | Safe for PF/math study; no code import |
| stake-originals-clone (community) | Varies / verify per fork | UX reference only; formulas re-derived in `@phonara/game-engine` |
| casino-lobby patterns | Varies | Layout reference only |

**Rule**: Before importing code from any row in this file, re-verify license on GitHub and record in Build Log. Default = **ideas only**.

## Current Reference Coverage

- Crash: covered by Velocity, aviator-crash, stake-originals-clone, Crash-Game-Frontend.
- Lobby UX: covered by casino-lobby and stake-originals-clone.
- Provably Fair UX: partially covered by stake-originals-clone.
- Multiplayer/social Crash UX: partially covered by Velocity and Crash-Game-Frontend.
- Wallet/ledger production architecture: must be PHONARA-native, not copied from demos.
- Trading engine references: not yet recovered from PC search.
- Admin/support references: not yet recovered from PC search.
