import { forwardRef, type InputHTMLAttributes } from 'react';
import { cva, type VariantProps } from 'class-variance-authority';
import { cn } from '../lib/cn';

export const inputVariants = cva(
  'w-full rounded-xl border bg-surface-2/60 text-fg outline-none transition-colors ' +
    'placeholder:text-muted/70 focus-visible:border-primary/60 focus-visible:ring-2 ' +
    'focus-visible:ring-primary/30 disabled:opacity-45 disabled:pointer-events-none',
  {
    variants: {
      inputSize: {
        sm: 'h-9 px-3 text-sm',
        md: 'h-11 px-3.5 text-sm',
        lg: 'h-12 px-4 text-base',
      },
      invalid: {
        true: 'border-down/60 focus-visible:border-down/60 focus-visible:ring-down/30',
        false: 'border-border',
      },
    },
    defaultVariants: {
      inputSize: 'md',
      invalid: false,
    },
  },
);

export interface InputProps
  extends Omit<InputHTMLAttributes<HTMLInputElement>, 'size'>,
    VariantProps<typeof inputVariants> {}

/**
 * Token-based text input primitive. i18n-agnostic: the caller passes any
 * translated `placeholder`. Right-aligned numeric fields pass `className="text-right"`.
 */
export const Input = forwardRef<HTMLInputElement, InputProps>(function Input(
  { className, inputSize, invalid, ...props },
  ref,
) {
  return (
    <input
      ref={ref}
      aria-invalid={invalid ?? undefined}
      className={cn(inputVariants({ inputSize, invalid }), className)}
      {...props}
    />
  );
});

Input.displayName = 'Input';
