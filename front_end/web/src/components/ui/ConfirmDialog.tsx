import { useCallback, useEffect, useRef } from 'react';
import { createPortal } from 'react-dom';

import { Icon } from '../Icon';
import { Button } from './Button';
import type { ButtonVariant } from './Button';

const FOCUSABLE = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
].join(',');

export interface ConfirmDialogProps {
  open: boolean;
  title: string;
  body: string;
  confirmLabel?: string;
  variant?: ButtonVariant;
  busy?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}

/**
 * Confirmation dialog for destructive and state-changing actions.
 *
 * Hand-built rather than using `<dialog>` so the focus trap, the Escape handling
 * and the restore-focus-on-close behaviour are explicit and testable, and so the
 * backdrop can carry the same glass treatment as the rest of the portal.
 */
export function ConfirmDialog({
  open,
  title,
  body,
  confirmLabel = 'Confirm',
  variant = 'danger',
  busy = false,
  onConfirm,
  onCancel,
}: ConfirmDialogProps) {
  const panelRef = useRef<HTMLDivElement>(null);
  const confirmRef = useRef<HTMLButtonElement>(null);
  const previouslyFocused = useRef<HTMLElement | null>(null);

  const handleKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLDivElement>) => {
      if (event.key === 'Escape') {
        event.stopPropagation();
        onCancel();
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
    [onCancel],
  );

  useEffect(() => {
    if (!open) {
      return;
    }

    previouslyFocused.current = document.activeElement as HTMLElement | null;
    confirmRef.current?.focus();

    const { overflow } = document.body.style;
    document.body.style.overflow = 'hidden';

    return () => {
      document.body.style.overflow = overflow;
      // Send focus back where it came from, so keyboard users do not land at the
      // top of the document after confirming a row action.
      previouslyFocused.current?.focus?.();
    };
  }, [open]);

  if (!open) {
    return null;
  }

  return createPortal(
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-[rgb(8_16_28/0.55)] p-4 backdrop-blur-sm"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) {
          onCancel();
        }
      }}
      onKeyDown={handleKeyDown}
    >
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="lb-confirm-title"
        aria-describedby="lb-confirm-body"
        className="lb-glass lb-glass-strong w-full max-w-md p-5"
      >
        <div className="flex items-start justify-between gap-3">
          <h2 id="lb-confirm-title" className="text-lg">
            {title}
          </h2>
          <button
            type="button"
            onClick={onCancel}
            className="rounded p-1 text-muted hover:bg-[var(--lb-hover)] hover:text-ink"
            aria-label="Close"
          >
            <Icon name="x" size={16} />
          </button>
        </div>

        <p id="lb-confirm-body" className="mt-3 mb-0 text-sm text-muted">
          {body}
        </p>

        <div className="mt-5 flex justify-end gap-2">
          <Button variant="secondary" onClick={onCancel} disabled={busy}>
            Cancel
          </Button>
          <Button ref={confirmRef} variant={variant} onClick={onConfirm} disabled={busy}>
            {busy ? 'Working…' : confirmLabel}
          </Button>
        </div>
      </div>
    </div>,
    document.body,
  );
}
