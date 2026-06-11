import { forwardRef, type HTMLAttributes, type ReactNode } from 'react';
import { cva, type VariantProps } from 'class-variance-authority';
import { cn } from '../lib/cn';

export const multiplierDisplayVariants = cva(
  'rounded-2xl border px-4 py-3 text-center tabular-nums',
  {
    variants: {
      tone: {
        neutral: 'border-border bg-surface-2 text-fg',
        up: 'border-up/40 bg-up/15 text-up',
        down: 'border-down/40 bg-down/15 text-down',
        primary: 'border-primary/40 bg-primary/15 text-primary',
      },
    },
    defaultVariants: { tone: 'neutral' },
  },
);

export interface MultiplierDisplayProps
  extends HTMLAttributes<HTMLDivElement>,
    VariantProps<typeof multiplierDisplayVariants> {
  label: ReactNode;
  value: ReactNode;
}

export const MultiplierDisplay = forwardRef<HTMLDivElement, MultiplierDisplayProps>(
  function MultiplierDisplay({ label, value, tone, className, ...props }, ref) {
    return (
      <div ref={ref} className={cn(multiplierDisplayVariants({ tone }), className)} {...props}>
        <p className="text-xs font-medium uppercase tracking-wide text-muted">{label}</p>
        <p className="mt-1 text-2xl font-black">{value}</p>
      </div>
    );
  },
);

MultiplierDisplay.displayName = 'MultiplierDisplay';
