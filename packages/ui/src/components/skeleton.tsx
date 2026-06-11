import { forwardRef, type HTMLAttributes } from 'react';
import { cn } from '../lib/cn';

export type SkeletonProps = HTMLAttributes<HTMLDivElement>;

export const Skeleton = forwardRef<HTMLDivElement, SkeletonProps>(function Skeleton(
  { className, ...props },
  ref,
) {
  return (
    <div
      ref={ref}
      className={cn('animate-pulse rounded-xl bg-surface-2/70', className)}
      aria-hidden="true"
      {...props}
    />
  );
});

Skeleton.displayName = 'Skeleton';
