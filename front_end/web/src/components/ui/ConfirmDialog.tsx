import { useEffect, useId, useRef, useState } from 'react';

import { Icon } from '../Icon';
import { Button } from './Button';
import type { ButtonVariant } from './Button';
import { Modal } from './Modal';

export interface ConfirmDialogProps {
  open: boolean;
  title: string;
  body: string;
  confirmLabel?: string;
  variant?: ButtonVariant;
  busy?: boolean;
  /**
   * Text the operator must type before the action can be confirmed, such as the
   * hostname of a host a user is signed in to. Matching ignores case and spaces at
   * either end.
   */
  requireText?: string;
  onConfirm: () => void;
  onCancel: () => void;
}

/** Confirmation dialog for destructive and state-changing actions. */
export function ConfirmDialog({
  open,
  title,
  body,
  confirmLabel = 'Confirm',
  variant = 'danger',
  busy = false,
  requireText,
  onConfirm,
  onCancel,
}: ConfirmDialogProps) {
  const confirmRef = useRef<HTMLButtonElement>(null);
  const typedRef = useRef<HTMLInputElement>(null);
  const typedId = useId();
  const [typed, setTyped] = useState('');

  const matches = !requireText || typed.trim().toLowerCase() === requireText.trim().toLowerCase();

  useEffect(() => {
    if (open) {
      setTyped('');
    }
  }, [open, requireText]);

  return (
    <Modal
      open={open}
      labelledBy="lb-confirm-title"
      describedBy="lb-confirm-body"
      onClose={onCancel}
      // With a required confirmation the confirm button starts disabled, so the input
      // takes focus instead.
      initialFocus={requireText ? typedRef : confirmRef}
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

      {requireText ? (
        <form
          className="mt-4 flex flex-col gap-1.5"
          onSubmit={(event) => {
            event.preventDefault();
            if (matches && !busy) {
              onConfirm();
            }
          }}
        >
          <label htmlFor={typedId} className="text-sm font-medium text-ink">
            Type <span className="font-mono">{requireText}</span> to confirm
          </label>
          <input
            id={typedId}
            ref={typedRef}
            className="lb-field font-mono"
            autoComplete="off"
            spellCheck={false}
            value={typed}
            disabled={busy}
            onChange={(event) => setTyped(event.target.value)}
          />
        </form>
      ) : null}

      <div className="mt-5 flex justify-end gap-2">
        <Button variant="secondary" onClick={onCancel} disabled={busy}>
          Cancel
        </Button>
        <Button ref={confirmRef} variant={variant} onClick={onConfirm} disabled={busy || !matches}>
          {busy ? 'Working…' : confirmLabel}
        </Button>
      </div>
    </Modal>
  );
}
