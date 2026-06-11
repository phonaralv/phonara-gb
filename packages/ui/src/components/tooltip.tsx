import {
  forwardRef,
  useState,
  useRef,
  type ReactNode,
  type HTMLAttributes,
} from 'react';
import { cn } from '../lib/cn';
import { mergeRefs } from '../lib/merge-refs';

export interface TooltipProps extends Omit<HTMLAttributes<HTMLSpanElement>, 'content'> {
  content: ReactNode;
  children: ReactNode;
  /** @default 'top' */
  placement?: 'top' | 'bottom' | 'left' | 'right';
}

/**
 * Tooltip — accessible hover + focus tooltip with no external dependencies.
 * Wraps its children in a relative span. Content floats above by default.
 */
export const Tooltip = forwardRef<HTMLSpanElement, TooltipProps>(
  ({ content, children, placement = 'top', className, ...rest }, ref) => {
    const [visible, setVisible] = useState(false);
    const spanRef = useRef<HTMLSpanElement>(null);

    const placementCls = {
      top: 'bottom-full left-1/2 -translate-x-1/2 mb-1.5',
      bottom: 'top-full left-1/2 -translate-x-1/2 mt-1.5',
      left: 'right-full top-1/2 -translate-y-1/2 mr-1.5',
      right: 'left-full top-1/2 -translate-y-1/2 ml-1.5',
    }[placement];

    return (
      <span
        ref={mergeRefs(spanRef, ref)}
        className={cn('relative inline-flex', className)}
        onMouseEnter={() => setVisible(true)}
        onMouseLeave={() => setVisible(false)}
        onFocus={() => setVisible(true)}
        onBlur={() => setVisible(false)}
        {...rest}
      >
        {children}
        {visible && content != null && (
          <span
            role="tooltip"
            className={cn(
              'absolute z-50 whitespace-nowrap rounded-lg',
              'bg-surface-2 border border-border px-2.5 py-1 text-xs text-fg shadow-lg',
              'pointer-events-none',
              placementCls,
            )}
          >
            {content}
          </span>
        )}
      </span>
    );
  },
);
Tooltip.displayName = 'Tooltip';
