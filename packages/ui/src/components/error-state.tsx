import { forwardRef, type HTMLAttributes, type ReactNode } from 'react';
import { Button, type ButtonProps } from './button';
import { cn } from '../lib/cn';

export interface ErrorStateProps extends Omit<HTMLAttributes<HTMLDivElement>, 'title'> {
  title: ReactNode;
  description?: ReactNode;
  actionLabel?: ReactNode;
  onAction?: ButtonProps['onClick'];
}

export const ErrorState = forwardRef<HTMLDivElement, ErrorStateProps>(function ErrorState(
  { title, description, actionLabel, onAction, className, ...props },
  ref,
) {
  return (
    <div
      ref={ref}
      className={cn('rounded-2xl border border-down/40 bg-down/10 p-5 text-center', className)}
      role="alert"
      {...props}
    >
      <h3 className="font-semibold text-fg">{title}</h3>
      {description && <p className="mt-2 text-sm text-muted">{description}</p>}
      {actionLabel && onAction && (
        <Button className="mt-4" size="sm" variant="danger" onClick={onAction}>
          {actionLabel}
        </Button>
      )}
    </div>
  );
});

ErrorState.displayName = 'ErrorState';
