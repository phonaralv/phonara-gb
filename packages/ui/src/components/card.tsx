import { forwardRef, type HTMLAttributes } from 'react';
import { cn } from '../lib/cn';

export const Card = forwardRef<HTMLDivElement, HTMLAttributes<HTMLDivElement>>(
  function Card({ className, ...props }, ref) {
    return (
      <div
        ref={ref}
        className={cn(
          'rounded-2xl border border-border bg-surface/80 backdrop-blur-xl ' +
            'shadow-[0_24px_64px_-32px_rgba(0,0,0,0.6)]',
          className,
        )}
        {...props}
      />
    );
  },
);

export const CardHeader = forwardRef<HTMLDivElement, HTMLAttributes<HTMLDivElement>>(
  function CardHeader({ className, ...props }, ref) {
    return (
      <div
        ref={ref}
        className={cn('flex items-center justify-between gap-3 px-5 pt-5', className)}
        {...props}
      />
    );
  },
);

export const CardTitle = forwardRef<HTMLHeadingElement, HTMLAttributes<HTMLHeadingElement>>(
  function CardTitle({ className, ...props }, ref) {
    return (
      <h3
        ref={ref}
        className={cn(
          'text-sm font-semibold uppercase tracking-[0.08em] text-muted',
          className,
        )}
        {...props}
      />
    );
  },
);

export const CardContent = forwardRef<HTMLDivElement, HTMLAttributes<HTMLDivElement>>(
  function CardContent({ className, ...props }, ref) {
    return <div ref={ref} className={cn('px-5 py-5', className)} {...props} />;
  },
);

Card.displayName = 'Card';
CardHeader.displayName = 'CardHeader';
CardTitle.displayName = 'CardTitle';
CardContent.displayName = 'CardContent';
