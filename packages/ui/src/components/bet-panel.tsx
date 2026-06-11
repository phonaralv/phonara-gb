import { forwardRef, type HTMLAttributes, type ReactNode } from 'react';
import { cn } from '../lib/cn';

export interface BetPanelProps extends Omit<HTMLAttributes<HTMLDivElement>, 'title'> {
  title: ReactNode;
  description?: ReactNode;
  actions?: ReactNode;
}

export const BetPanel = forwardRef<HTMLDivElement, BetPanelProps>(function BetPanel(
  { title, description, actions, children, className, ...props },
  ref,
) {
  return (
    <section
      ref={ref}
      className={cn('rounded-2xl border border-border bg-surface p-5 shadow-xl', className)}
      {...props}
    >
      <div className="mb-4 flex items-start justify-between gap-3">
        <div>
          <h2 className="text-lg font-bold text-fg">{title}</h2>
          {description && <p className="mt-1 text-sm text-muted">{description}</p>}
        </div>
        {actions}
      </div>
      {children}
    </section>
  );
});

BetPanel.displayName = 'BetPanel';
