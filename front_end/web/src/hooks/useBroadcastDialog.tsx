import { useState } from 'react';

import { MessageDialog } from '../components/ui/MessageDialog';
import { useToast } from '../components/ui/Toast';
import { useBroadcast } from './useBroker';
import { errorMessage } from '../lib/api';

export interface BroadcastRequest {
  /** Only these hosts. Leave out to reach every session. */
  hostnames?: string[];
  title: string;
  /** Who the message reaches, in a sentence. */
  recipients: string;
}

/** Composes and sends a message to many sessions at once. */
export function useBroadcastDialog() {
  const { showToast } = useToast();
  const broadcast = useBroadcast();
  const [request, setRequest] = useState<BroadcastRequest | null>(null);

  async function send(message: string) {
    if (!request) {
      return;
    }
    try {
      const result = await broadcast.mutateAsync({ message, hostnames: request.hostnames });
      const complete = result.TargetCount > 0 && result.Results.every((entry) => entry.Result === 'Delivered' || entry.Result === 'NoSession') && !result.NotAttempted.length;
      showToast(result.message, complete ? 'success' : 'warning');
      setRequest(null);
    } catch (cause) {
      showToast(errorMessage(cause, 'Unable to send the message.'), 'danger');
    }
  }

  const dialog = (
    <MessageDialog
      open={request !== null}
      title={request?.title ?? 'Message'}
      recipients={request?.recipients ?? ''}
      sendLabel="Send to all"
      busy={broadcast.isPending}
      onSend={(message) => void send(message)}
      onCancel={() => {
        if (!broadcast.isPending) {
          setRequest(null);
        }
      }}
    />
  );

  return { openBroadcast: setRequest, dialog };
}
