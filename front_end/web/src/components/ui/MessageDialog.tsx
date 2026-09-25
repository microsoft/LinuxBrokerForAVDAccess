import { useEffect, useId, useRef, useState } from 'react';

import { Icon } from '../Icon';
import { Button } from './Button';
import { Modal } from './Modal';

export const MESSAGE_MAX_CHARS = 500;

export interface MessageDialogProps {
  open: boolean;
  title: string;
  /** Who the message reaches, in a sentence. */
  recipients: string;
  sendLabel?: string;
  busy?: boolean;
  onSend: (message: string) => void;
  onCancel: () => void;
}

/** Composes a message shown as a notification in Linux desktop sessions. */
export function MessageDialog({
  open,
  title,
  recipients,
  sendLabel = 'Send message',
  busy = false,
  onSend,
  onCancel,
}: MessageDialogProps) {
  const [text, setText] = useState('');
  const fieldRef = useRef<HTMLTextAreaElement>(null);
  const titleId = useId();
  const bodyId = useId();
  const fieldId = useId();
  const countId = useId();

  useEffect(() => {
    if (open) {
      setText('');
    }
  }, [open]);

  const message = text.trim();
  const tooLong = message.length > MESSAGE_MAX_CHARS;

  return (
    <Modal open={open} labelledBy={titleId} describedBy={bodyId} onClose={onCancel} initialFocus={fieldRef}>
      <form
        onSubmit={(event) => {
          event.preventDefault();
          if (message && !tooLong && !busy) {
            onSend(message);
          }
        }}
      >
        <div className="flex items-start justify-between gap-3">
          <h2 id={titleId} className="text-lg">
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

        <p id={bodyId} className="mt-3 mb-0 text-sm text-muted">
          {recipients} It appears as a desktop notification and cannot be recalled.
        </p>

        <div className="mt-4 flex flex-col gap-1.5">
          <label htmlFor={fieldId} className="text-sm font-medium text-ink">
            Message
          </label>
          <textarea
            id={fieldId}
            ref={fieldRef}
            className="lb-field min-h-28 resize-y"
            value={text}
            disabled={busy}
            aria-describedby={countId}
            aria-invalid={tooLong || undefined}
            onChange={(event) => setText(event.target.value)}
          />
          <p
            id={countId}
            className={`mb-0 text-right text-xs tabular-nums ${tooLong ? 'text-[var(--lb-danger-fg)]' : 'text-muted'}`}
            aria-live="polite"
          >
            {tooLong
              ? `${message.length - MESSAGE_MAX_CHARS} ${message.length - MESSAGE_MAX_CHARS === 1 ? 'character' : 'characters'} over the ${MESSAGE_MAX_CHARS} limit`
              : `${message.length} / ${MESSAGE_MAX_CHARS}`}
          </p>
        </div>

        <div className="mt-4 flex justify-end gap-2">
          <Button variant="secondary" onClick={onCancel} disabled={busy}>
            Cancel
          </Button>
          <Button type="submit" variant="primary" icon="box-arrow-right" disabled={busy || !message || tooLong}>
            {busy ? 'Sending…' : sendLabel}
          </Button>
        </div>
      </form>
    </Modal>
  );
}
