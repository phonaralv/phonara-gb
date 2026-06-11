import { forwardRef, type HTMLAttributes, type ReactNode } from 'react';
import { Badge } from './badge';

export interface ProvablyFairBadgeProps extends HTMLAttributes<HTMLSpanElement> {
  children: ReactNode;
}

export const ProvablyFairBadge = forwardRef<HTMLSpanElement, ProvablyFairBadgeProps>(
  function ProvablyFairBadge({ children, ...props }, ref) {
    return (
      <Badge ref={ref} tone="primary" size="sm" {...props}>
        {children}
      </Badge>
    );
  },
);

ProvablyFairBadge.displayName = 'ProvablyFairBadge';
