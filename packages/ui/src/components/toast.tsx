import { forwardRef, type HTMLAttributes, type ReactNode } from 'react';
import { cva, type VariantProps } from 'class-variance-authority';
import { cn } from '../lib/cn';

export const toastVariants = cva(
  'rounded-2xl border px-4 py-3 shadow-2xl backdrop-blur-sm',
  {
    variants: {
      tone: {
        neutral: 'border-border bg-surface/95 text-fg',
        success: 'border-up/40 bg-up/15 text-fg',
        warning: 'border-warning/40 bg-warning/15 text-fg',
        danger: 'border-down/40 bg-down/15 text-fg',
      },
    },
    defaultVariants: { tone: 'neutral' },
  },
);

export interface ToastProps
  extends Omit<HTMLAttributes<HTMLDivElement>, 'title'>,
    VariantProps<typeof toastVariants> {
  title?: ReactNode;
  description?: ReactNode;
}

export const Toast = forwardRef<HTMLDivElement, ToastProps>(function Toast(
  { tone, title, description, className, children, ...props },
  ref,
) {
  return (
    <div ref={ref} role="status" className={cn(toastVariants({ tone }), className)} {...props}>
      {title && <p className="font-semibold text-sm">{title}</p>}
      {description && <p className="mt-1 text-xs text-muted">{description}</p>}
      {children}
    </div>
  );
});

Toast.displayName = 'Toast';
