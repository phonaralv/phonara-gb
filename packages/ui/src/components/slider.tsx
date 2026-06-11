import {
  forwardRef,
  type InputHTMLAttributes,
  type ChangeEvent,
} from 'react';
import { cn } from '../lib/cn';

export interface SliderProps extends Omit<InputHTMLAttributes<HTMLInputElement>, 'type' | 'onChange'> {
  value: number;
  min?: number;
  max?: number;
  step?: number;
  onChange?: (value: number) => void;
  /** Show the current value label above the thumb */
  showLabel?: boolean;
  formatLabel?: (v: number) => string;
}

/**
 * Slider — styled range input. Primary use: leverage selector.
 * Renders a native <input type="range"> with custom CSS to match the design system.
 */
export const Slider = forwardRef<HTMLInputElement, SliderProps>(
  (
    {
      value,
      min = 1,
      max = 100,
      step = 1,
      onChange,
      showLabel = false,
      formatLabel,
      className,
      ...rest
    },
    ref,
  ) => {
    const pct = max > min ? ((value - min) / (max - min)) * 100 : 0;
    const label = formatLabel ? formatLabel(value) : `${value}×`;

    const handleChange = (e: ChangeEvent<HTMLInputElement>) => {
      onChange?.(Number(e.target.value));
    };

    return (
      <div className={cn('relative flex flex-col gap-1', className)}>
        {showLabel && (
          <div className="flex justify-between text-xs text-muted mb-1">
            <span>{formatLabel ? formatLabel(min) : `${min}×`}</span>
            <span className="text-primary font-semibold">{label}</span>
            <span>{formatLabel ? formatLabel(max) : `${max}×`}</span>
          </div>
        )}
        <div className="relative h-6 flex items-center">
          {/* Track background */}
          <div className="absolute inset-x-0 h-1.5 rounded-full bg-surface-2 border border-border" />
          {/* Filled portion */}
          <div
            className="absolute left-0 h-1.5 rounded-full bg-primary"
            style={{ width: `${pct}%` }}
          />
          <input
            ref={ref}
            type="range"
            min={min}
            max={max}
            step={step}
            value={value}
            onChange={handleChange}
            className={cn(
              'absolute inset-0 w-full h-full opacity-0 cursor-pointer',
              'disabled:cursor-not-allowed',
            )}
            {...rest}
          />
          {/* Thumb */}
          <div
            className="absolute w-4 h-4 rounded-full bg-primary border-2 border-primary-fg shadow pointer-events-none"
            style={{ left: `calc(${pct}% - 8px)` }}
          />
        </div>
      </div>
    );
  },
);
Slider.displayName = 'Slider';
