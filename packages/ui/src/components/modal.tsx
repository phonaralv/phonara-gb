import {
  forwardRef,
  useCallback,
  useEffect,
  useRef,
  type KeyboardEvent,
  type ReactNode,
} from 'react';
import { createPortal } from 'react-dom';
import { cn } from '../lib/cn';
import { mergeRefs } from '../lib/merge-refs';

const FOCUSABLE =
  'a[href],button:not([disabled]),textarea:not([disabled]),input:not([disabled]),select:not([disabled]),[tabindex]:not([tabindex="-1"])';

export interface ModalProps {
  /** Controlled visibility. */
  open: boolean;
  /** Requested close (ESC, overlay click). Ignored when `dismissible` is false. */
  onClose: () => void;
  children: ReactNode;
  /** id of the element labelling the dialog (aria-labelledby). */
  labelledBy?: string;
  /** id of the element describing the dialog (aria-describedby). */
  describedBy?: string;
  /** When false, ESC/overlay click do not close (e.g. while a request is in-flight). */
  dismissible?: boolean;
  /** Extra classes for the dialog panel. */
  className?: string;
}

/**
 * Accessible modal primitive: portal to `document.body`, scroll lock, focus
 * trap, ESC/overlay dismissal, and focus restoration. Composite dialogs
 * (ConfirmDialog, Sheet, ...) build on top of this instead of re-implementing
 * overlay/focus logic.
 */
export const Modal = forwardRef<HTMLDivElement, ModalProps>(function Modal(
  { open, onClose, children, labelledBy, describedBy, dismissible = true, className },
  ref,
) {
  const panelRef = useRef<HTMLDivElement>(null);
  const lastActiveRef = useRef<HTMLElement | null>(null);

  useEffect(() => {
    if (!open) return;
    lastActiveRef.current = document.activeElement as HTMLElement | null;
    const { body } = document;
    const prevOverflow = body.style.overflow;
    body.style.overflow = 'hidden';

    const panel = panelRef.current;
    const first = panel?.querySelector<HTMLElement>(FOCUSABLE);
    (first ?? panel)?.focus();

    return () => {
      body.style.overflow = prevOverflow;
      lastActiveRef.current?.focus?.();
    };
  }, [open]);

  const onKeyDown = useCallback(
    (e: KeyboardEvent<HTMLDivElement>) => {
      if (e.key === 'Escape' && dismissible) {
        e.stopPropagation();
        onClose();
        return;
      }
      if (e.key !== 'Tab') return;
      const panel = panelRef.current;
      if (!panel) return;
      const items = Array.from(panel.querySelectorAll<HTMLElement>(FOCUSABLE)).filter(
        (el) => el.offsetParent !== null,
      );
      if (items.length === 0) return;
      const firstEl = items[0]!;
      const lastEl = items[items.length - 1]!;
      if (e.shiftKey && document.activeElement === firstEl) {
        e.preventDefault();
        lastEl.focus();
      } else if (!e.shiftKey && document.activeElement === lastEl) {
        e.preventDefault();
        firstEl.focus();
      }
    },
    [dismissible, onClose],
  );

  if (!open) return null;

  return createPortal(
    <div
      className="fixed inset-0 z-1000 flex items-center justify-center bg-black/70 p-4 backdrop-blur-sm"
      onClick={(e) => {
        if (dismissible && e.target === e.currentTarget) onClose();
      }}
    >
      <div
        ref={mergeRefs(panelRef, ref)}
        role="dialog"
        aria-modal="true"
        aria-labelledby={labelledBy}
        aria-describedby={describedBy}
        tabIndex={-1}
        onKeyDown={onKeyDown}
        className={cn(
          'w-full max-w-sm rounded-2xl border border-border bg-surface p-6 outline-none ' +
            'shadow-[0_24px_64px_-24px_rgba(0,0,0,0.7)]',
          className,
        )}
      >
        {children}
      </div>
    </div>,
    document.body,
  );
});

Modal.displayName = 'Modal';
