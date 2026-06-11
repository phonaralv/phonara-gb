import { forwardRef, type HTMLAttributes, type ReactNode } from 'react';
import { Button, type ButtonProps } from './button';
import { cn } from '../lib/cn';

export interface EmptyStateProps extends Omit<HTMLAttributes<HTMLDivElement>, 'title'> {
  title: ReactNode;
  description?: ReactNode;
  actionLabel?: ReactNode;
  onAction?: ButtonProps['onClick'];
}

export const EmptyState = forwardRef<HTMLDivElement, EmptyStateProps>(function EmptyState(
  { title, description, actionLabel, onAction, className, ...props },
  ref,
) {
  return (
    <div
      ref={ref}
      className={cn('rounded-2xl border border-dashed border-border bg-surface/60 p-6 text-center', className)}
      {...props}
    >
      <h3 className="font-semibold text-fg">{title}</h3>
      {description && <p className="mt-2 text-sm text-muted">{description}</p>}
      {actionLabel && onAction && (
        <Button className="mt-4" size="sm" variant="outline" onClick={onAction}>
          {actionLabel}
        </Button>
      )}
    </div>
  );
});

EmptyState.displayName = 'EmptyState';
