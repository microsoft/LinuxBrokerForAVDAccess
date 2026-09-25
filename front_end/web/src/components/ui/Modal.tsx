import { useCallback, useEffect, useRef } from 'react';
import type { ReactNode, RefObject } from 'react';
import { createPortal } from 'react-dom';

import { classNames } from '../../lib/format';

const FOCUSABLE = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
].join(',');

export interface ModalProps {
  open: boolean;
  /** Id of the element that names the dialog. */
  labelledBy: string;
  /** Id of the element that describes it. */
  describedBy?: string;
  onClose: () => void;
  /** Element to focus when the dialog opens; the first focusable one otherwise. */
  initialFocus?: RefObject<HTMLElement | null>;
  className?: string;
  children: ReactNode;
}

/**
 * The shell every portal dialog uses: a modal panel over a blurred backdrop.
 *
 * Hand-built rather than using `<dialog>` so the focus trap, the Escape handling and
 * the restore-focus-on-close behaviour are explicit and testable, and so the backdrop
 * carries the same glass treatment as the rest of the portal.
 */
export function Modal({ open, labelledBy, describedBy, onClose, initialFocus, className, children }: ModalProps) {
  const panelRef = useRef<HTMLDivElement>(null);
  const previouslyFocused = useRef<HTMLElement | null>(null);

  const handleKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLDivElement>) => {
      if (event.key === 'Escape') {
        event.stopPropagation();
        onClose();
        return;
      }

      if (event.key !== 'Tab' || !panelRef.current) {
        return;
      }

      // No visibility filtering: everything focusable inside the panel is visible
      // while the dialog is open, and an `offsetParent` check would silently
      // collapse the list to one element in environments without layout.
      const focusable = Array.from(panelRef.current.querySelectorAll<HTMLElement>(FOCUSABLE)).filter(
        (element) => !element.hasAttribute('disabled'),
      );

      if (focusable.length < 2) {
        return;
      }

      const first = focusable[0];
      const last = focusable[focusable.length - 1];

      // Wrap at both ends so focus can never escape the dialog while it is open.
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    },
    [onClose],
  );

  useEffect(() => {
    if (!open) {
      return;
    }

    previouslyFocused.current = document.activeElement as HTMLElement | null;
    const target = initialFocus?.current ?? panelRef.current?.querySelector<HTMLElement>(FOCUSABLE);
    target?.focus();

    const { overflow } = document.body.style;
    document.body.style.overflow = 'hidden';

    return () => {
      document.body.style.overflow = overflow;
      // Send focus back where it came from, so keyboard users do not land at the
      // top of the document after confirming a row action.
      previouslyFocused.current?.focus?.();
    };
    // Focus is placed once per opening; the ref's element does not change while open.
  }, [open]);

  if (!open) {
    return null;
  }

  return createPortal(
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-[rgb(8_16_28/0.55)] p-4 backdrop-blur-sm"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) {
          onClose();
        }
      }}
      onKeyDown={handleKeyDown}
    >
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={labelledBy}
        aria-describedby={describedBy}
        className={classNames('lb-glass lb-glass-strong w-full max-w-md p-5', className)}
      >
        {children}
      </div>
    </div>,
    document.body,
  );
}
