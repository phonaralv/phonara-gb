import { forwardRef, type ButtonHTMLAttributes } from 'react';
import { cva, type VariantProps } from 'class-variance-authority';
import { cn } from '../lib/cn';

export const buttonVariants = cva(
  'inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-xl font-semibold ' +
    'transition-[transform,opacity,background-color,box-shadow,border-color] duration-150 ' +
    'select-none outline-none focus-visible:ring-2 focus-visible:ring-primary/60 ' +
    'disabled:opacity-45 disabled:pointer-events-none active:scale-[0.98]',
  {
    variants: {
      variant: {
        primary: 'bg-primary text-primary-fg shadow-[0_10px_30px_-12px_var(--color-primary)] hover:opacity-90',
        secondary: 'bg-surface-2 text-fg border border-border hover:border-border-strong',
        outline: 'bg-transparent text-fg border border-border hover:border-border-strong hover:bg-white/5',
        ghost: 'bg-transparent text-muted hover:text-fg hover:bg-white/5',
        danger: 'bg-down text-white hover:opacity-90',
        success: 'bg-up text-white hover:opacity-90',
      },
      size: {
        sm: 'h-9 px-3 text-sm',
        md: 'h-11 px-5 text-sm',
        lg: 'h-12 px-6 text-base',
        icon: 'h-10 w-10',
      },
      full: {
        true: 'w-full',
      },
    },
    defaultVariants: {
      variant: 'primary',
      size: 'md',
    },
  },
);

export interface ButtonProps
  extends ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {}

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { className, variant, size, full, type, ...props },
  ref,
) {
  return (
    <button
      ref={ref}
      type={type ?? 'button'}
      className={cn(buttonVariants({ variant, size, full }), className)}
      {...props}
    />
  );
});

Button.displayName = 'Button';
