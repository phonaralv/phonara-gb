import { useMemo } from 'react';
import type { Currency } from '@phonara/shared-types';
import { formatMoney, type FormatMoneyOptions } from '@phonara/ui';

/**
 * Memoized, precision-safe money formatting for a raw decimal string.
 * Returns an em dash for null/undefined/invalid input so the UI never crashes
 * on a missing balance.
 */
export function useMoney(
  amount: string | null | undefined,
  currency: Currency,
  opts?: FormatMoneyOptions,
): string {
  const showCurrency = opts?.showCurrency;
  const signed = opts?.signed;
  const grouping = opts?.grouping;

  return useMemo(() => {
    if (amount == null || amount === '') return '—';
    try {
      return formatMoney(amount, currency, { showCurrency, signed, grouping });
    } catch {
      return '—';
    }
  }, [amount, currency, showCurrency, signed, grouping]);
}
