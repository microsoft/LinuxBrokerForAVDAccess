import { useCallback, useState } from 'react';

import { ConfirmDialog } from '../components/ui/ConfirmDialog';
import type { ButtonVariant } from '../components/ui/Button';

export interface ConfirmRequest {
  title: string;
  body: string;
  confirmLabel?: string;
  variant?: ButtonVariant;
  onConfirm: () => void | Promise<void>;
}

/**
 * Shared confirmation flow for destructive and state-changing actions.
 *
 * Replaces the single Bootstrap modal that app.js populated from `data-lb-confirm-*`
 * attributes: a caller describes the action, and the dialog names the specific
 * resource before anything is sent.
 */
export function useConfirm() {
  const [request, setRequest] = useState<ConfirmRequest | null>(null);
  const [busy, setBusy] = useState(false);

  const confirm = useCallback((next: ConfirmRequest) => setRequest(next), []);

  const cancel = useCallback(() => {
    if (!busy) {
      setRequest(null);
    }
  }, [busy]);

  const accept = useCallback(async () => {
    if (!request) {
      return;
    }
    setBusy(true);
    try {
      await request.onConfirm();
      setRequest(null);
    } finally {
      setBusy(false);
    }
  }, [request]);

  const dialog = (
    <ConfirmDialog
      open={request !== null}
      title={request?.title ?? ''}
      body={request?.body ?? ''}
      confirmLabel={request?.confirmLabel}
      variant={request?.variant}
      busy={busy}
      onConfirm={() => void accept()}
      onCancel={cancel}
    />
  );

  return { confirm, dialog };
}
