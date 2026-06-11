import { forwardRef, type HTMLAttributes, type ReactNode } from 'react';
import { cva, type VariantProps } from 'class-variance-authority';
import { cn } from '../lib/cn';

const valueVariants = cva('font-semibold tabular-nums', {
  variants: {
    tone: {
      default: 'text-fg',
      up: 'text-up',
      down: 'text-down',
      warning: 'text-warning',
      muted: 'text-muted',
    },
  },
  defaultVariants: { tone: 'default' },
});

export interface StatProps
  extends Omit<HTMLAttributes<HTMLDivElement>, 'children'>,
    VariantProps<typeof valueVariants> {
  /** Pre-translated label. */
  label: ReactNode;
  /** Pre-formatted value (use @phonara/money formatters for amounts). */
  value: ReactNode;
  /** `between` = label/value on one row (preview rows); `stack` = label above value (grids). */
  layout?: 'between' | 'stack';
}

/**
 * Label/value pair. Replaces bespoke `.preview-row` and position-grid cells.
 * Amounts must be pre-formatted via @phonara/money (no float here).
 */
export const Stat = forwardRef<HTMLDivElement, StatProps>(function Stat(
  { className, label, value, tone, layout = 'between', ...props },
  ref,
) {
  const stack = layout === 'stack';
  return (
    <div
      ref={ref}
      className={cn(
        stack ? 'flex flex-col gap-0.5' : 'flex items-baseline justify-between gap-4',
        'text-sm',
        className,
      )}
      {...props}
    >
      <span className="text-muted">{label}</span>
      <span className={valueVariants({ tone })}>{value}</span>
    </div>
  );
});

Stat.displayName = 'Stat';
