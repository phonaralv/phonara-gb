import {
  forwardRef,
  useEffect,
  useRef,
  type ReactNode,
  type HTMLAttributes,
} from 'react';
import { cn } from '../lib/cn';
import { mergeRefs } from '../lib/merge-refs';

export interface SheetProps extends Omit<HTMLAttributes<HTMLDivElement>, 'title'> {
  open: boolean;
  onClose: () => void;
  title?: ReactNode;
  children: ReactNode;
  /** @default 'bottom' */
  side?: 'bottom' | 'right';
}

/**
 * Sheet — mobile-first bottom / side drawer.
 * Renders a backdrop + sliding panel. Use for order panels, detail drawers, etc.
 */
export const Sheet = forwardRef<HTMLDivElement, SheetProps>(
  ({ open, onClose, title, children, side = 'bottom', className, ...rest }, ref) => {
    const panelRef = useRef<HTMLDivElement>(null);

    useEffect(() => {
      if (!open) return;
      const onKey = (e: KeyboardEvent) => {
        if (e.key === 'Escape') onClose();
      };
      document.addEventListener('keydown', onKey);
      return () => document.removeEventListener('keydown', onKey);
    }, [open, onClose]);

    if (!open) return null;

    const isBottom = side === 'bottom';

    return (
      <div className="fixed inset-0 z-50 flex" role="dialog" aria-modal="true">
        {/* Backdrop */}
        <div
          className="absolute inset-0 bg-bg/80 backdrop-blur-sm"
          onClick={onClose}
          aria-hidden="true"
        />
        {/* Panel */}
        <div
          ref={mergeRefs(panelRef, ref)}
          className={cn(
            'relative z-10 flex flex-col bg-surface shadow-2xl',
            isBottom
              ? 'mt-auto w-full max-h-[90dvh] rounded-t-2xl'
              : 'ml-auto h-full w-full max-w-sm rounded-l-2xl',
            className,
          )}
          {...rest}
        >
          {/* Drag handle (bottom only) */}
          {isBottom && (
            <div className="flex justify-center pt-3 pb-1 flex-shrink-0">
              <span className="h-1 w-10 rounded-full bg-border-strong" />
            </div>
          )}
          {title && (
            <div className="px-5 pt-3 pb-4 border-b border-border flex-shrink-0">
              <p className="font-semibold text-fg text-base">{title}</p>
            </div>
          )}
          <div className="overflow-y-auto flex-1 p-5">{children}</div>
        </div>
      </div>
    );
  },
);
Sheet.displayName = 'Sheet';
