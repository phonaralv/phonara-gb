import { forwardRef, type InputHTMLAttributes, type ReactNode } from 'react';
import { cn } from '../lib/cn';
import { Input } from './input';

export interface GameStakeInputProps
  extends Omit<InputHTMLAttributes<HTMLInputElement>, 'prefix'> {
  label: ReactNode;
  currency: ReactNode;
  hint?: ReactNode;
}

export const GameStakeInput = forwardRef<HTMLInputElement, GameStakeInputProps>(
  function GameStakeInput({ label, currency, hint, className, ...props }, ref) {
    return (
      <label className="flex flex-col gap-2">
        <span className="text-sm font-medium text-fg">{label}</span>
        <div className="flex items-center gap-2">
          <Input
            ref={ref}
            inputMode="decimal"
            className={cn('min-w-0 flex-1 text-right tabular-nums', className)}
            {...props}
          />
          <span className="rounded-xl border border-border bg-surface-2 px-3 py-2 text-sm font-semibold text-muted">
            {currency}
          </span>
        </div>
        {hint && <span className="text-xs text-muted">{hint}</span>}
      </label>
    );
  },
);

GameStakeInput.displayName = 'GameStakeInput';
