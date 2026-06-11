# @phonara/wallet-ledger

This package is the normative TypeScript model for the SQL wallet ledger
semantics. It is not used at runtime by the app or database settlement path.

Known semantic differences:

- TypeScript does not support standalone `reverse`; the SQL enum contains
  `reverse` for paired server-side reversal flows.
- TypeScript rejects zero amounts.

SQL behavior always takes precedence over this package.
