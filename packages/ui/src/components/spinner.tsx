import { forwardRef, type HTMLAttributes } from 'react';
import { cva, type VariantProps } from 'class-variance-authority';
import { cn } from '../lib/cn';

const spinnerVariants = cva(
  'inline-block animate-spin rounded-full border-solid border-border border-t-primary',
  {
    variants: {
      size: {
        sm: 'h-4 w-4 border-2',
        md: 'h-9 w-9 border-[3px]',
        lg: 'h-12 w-12 border-4',
      },
    },
    defaultVariants: { size: 'md' },
  },
);

export interface SpinnerProps
  extends HTMLAttributes<HTMLSpanElement>,
    VariantProps<typeof spinnerVariants> {
  /** Pre-translated accessible label for screen readers. */
  label?: string;
}

/** Loading spinner. Replaces the bespoke `.spinner` class. */
export const Spinner = forwardRef<HTMLSpanElement, SpinnerProps>(function Spinner(
  { className, size, label, ...props },
  ref,
) {
  return (
    <span
      ref={ref}
      role="status"
      aria-label={label}
      aria-live="polite"
      className={cn(spinnerVariants({ size }), className)}
      {...props}
    />
  );
});

Spinner.displayName = 'Spinner';
