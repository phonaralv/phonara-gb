import type { CSSProperties } from 'react';
import type { Currency } from '@phonara/shared-types';
import { format as formatCanonical, money as makeMoney } from '@phonara/money';
import { cn } from '../lib/cn';

export interface FormatMoneyOptions {
  /** Append the currency ticker, e.g. "1,234 PHON". */
  showCurrency?: boolean;
  /** Force a leading "+" for non-negative values. */
  signed?: boolean;
  /** Group the integer part with thousands separators (default true). */
  grouping?: boolean;
}

function groupInteger(intPart: string): string {
  const neg = intPart.startsWith('-');
  const digits = neg ? intPart.slice(1) : intPart;
  const grouped = digits.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return neg ? `-${grouped}` : grouped;
}

/**
 * Format a raw decimal string for a currency with no floating point math.
 * Truncates to the currency's precision (via @phonara/money) then applies
 * thousands grouping on the integer part only.
 */
export function formatMoney(
  amount: string,
  currency: Currency,
  opts: FormatMoneyOptions = {},
): string {
  const { showCurrency = false, signed = false, grouping = true } = opts;
  const canonical = formatCanonical(makeMoney(amount, currency));
  const isNeg = canonical.startsWith('-');
  const unsigned = isNeg ? canonical.slice(1) : canonical;
  const parts = unsigned.split('.');
  const intPart = parts[0] ?? '0';
  const fracPart = parts[1];
  const groupedInt = grouping ? groupInteger(intPart) : intPart;
  let out = fracPart ? `${groupedInt}.${fracPart}` : groupedInt;
  if (isNeg) out = `-${out}`;
  else if (signed) out = `+${out}`;
  if (showCurrency) out = `${out} ${currency}`;
  return out;
}

export interface MoneyProps extends FormatMoneyOptions {
  amount: string;
  currency: Currency;
  /** Tint by sign: positive → up color, negative → down color. */
  colorize?: boolean;
  className?: string;
  style?: CSSProperties;
}

/**
 * Tabular-numbers money display. Always renders deterministic, precision-safe
 * output derived from the Decimal engine.
 */
export function Money({
  amount,
  currency,
  showCurrency,
  signed,
  grouping,
  colorize,
  className,
  style,
}: MoneyProps) {
  const text = formatMoney(amount, currency, { showCurrency, signed, grouping });
  const isNeg = text.startsWith('-');
  const isPos = !isNeg && text !== '0';
  return (
    <span
      className={cn(
        'tabular-nums tracking-tight',
        colorize && isNeg && 'text-down',
        colorize && isPos && 'text-up',
        className,
      )}
      style={style}
      data-currency={currency}
    >
      {text}
    </span>
  );
}
