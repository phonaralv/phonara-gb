import { type ReactNode } from 'react';
import { cva } from 'class-variance-authority';
import { cn } from '../lib/cn';

export type SegmentedTone = 'default' | 'primary' | 'accent' | 'up' | 'down';

const segmentVariants = cva(
  'flex flex-1 flex-col items-center justify-center gap-0.5 rounded-xl border font-semibold ' +
    'transition-colors outline-none cursor-pointer select-none ' +
    'focus-visible:ring-2 focus-visible:ring-primary/50 disabled:opacity-45 disabled:pointer-events-none',
  {
    variants: {
      size: {
        sm: 'px-2 py-2 text-xs',
        md: 'px-3 py-2.5 text-sm',
      },
      tone: {
        default: '',
        primary: '',
        accent: '',
        up: '',
        down: '',
      },
      active: { true: '', false: 'border-transparent bg-white/5 text-muted hover:text-fg' },
    },
    compoundVariants: [
      { active: true, tone: 'default', className: 'border-border-strong bg-surface-2 text-fg' },
      { active: true, tone: 'primary', className: 'border-primary/40 bg-primary/15 text-primary' },
      { active: true, tone: 'accent', className: 'border-accent/40 bg-accent/15 text-accent' },
      { active: true, tone: 'up', className: 'border-up/40 bg-up/15 text-up' },
      { active: true, tone: 'down', className: 'border-down/40 bg-down/15 text-down' },
    ],
    defaultVariants: { size: 'md', tone: 'default', active: false },
  },
);

export interface SegmentedOption<T extends string> {
  value: T;
  /** Pre-translated label or arbitrary node (e.g. symbol + price). */
  label: ReactNode;
  /** Active-state color. Defaults to the control-level `tone`. */
  tone?: SegmentedTone;
  disabled?: boolean;
  testId?: string;
}

export interface SegmentedControlProps<T extends string> {
  options: readonly SegmentedOption<T>[];
  value: T;
  onChange: (value: T) => void;
  /** Default active color for options that don't set their own `tone`. */
  tone?: SegmentedTone;
  size?: 'sm' | 'md';
  className?: string;
  'aria-label'?: string;
}

/**
 * Token-based segmented toggle (radio-group semantics). Replaces bespoke
 * side/market/currency toggles. Composite of multiple buttons, so no ref is
 * forwarded (rule 85). i18n-agnostic — labels are passed in already translated.
 */
export function SegmentedControl<T extends string>({
  options,
  value,
  onChange,
  tone = 'default',
  size = 'md',
  className,
  'aria-label': ariaLabel,
}: SegmentedControlProps<T>) {
  return (
    <div role="radiogroup" aria-label={ariaLabel} className={cn('flex gap-1.5', className)}>
      {options.map((opt) => {
        const active = opt.value === value;
        return (
          <button
            key={opt.value}
            type="button"
            role="radio"
            aria-checked={active}
            disabled={opt.disabled}
            data-testid={opt.testId}
            onClick={() => onChange(opt.value)}
            className={segmentVariants({ size, tone: opt.tone ?? tone, active })}
          >
            {opt.label}
          </button>
        );
      })}
    </div>
  );
}

SegmentedControl.displayName = 'SegmentedControl';
