import { useState } from 'react';

import { hasDesktop } from '../components/sessions/SessionState';
import type { ActionMenuItem } from '../components/ui/ActionMenu';
import { MessageDialog } from '../components/ui/MessageDialog';
import { useToast } from '../components/ui/Toast';
import { useMessageSession, useSignOutSession } from './useBroker';
import { useConfirm } from './useConfirm';
import { useCan } from './useSession';
import { errorMessage } from '../lib/api';
import type { BrokerSession } from '../types/broker';

type ActionSession = Pick<BrokerSession, 'Hostname' | 'Username' | 'State' | 'PowerState' | 'HasAssignment'>;

/**
 * Sign out and message for one user's session, with the confirmation each needs.
 *
 * Every dialog names the user and the host. Signing out closes the desktop, so it is
 * always confirmed; returning the host as well says that the assignment ends too.
 */
export function useSessionActions() {
  const can = useCan();
  const { showToast } = useToast();
  const { confirm, dialog } = useConfirm();
  const signOut = useSignOutSession();
  const sendMessage = useMessageSession();
  const [messageTo, setMessageTo] = useState<ActionSession | null>(null);

  function requestSignOut(session: ActionSession, returnHost = false) {
    const { Username: user, Hostname: host } = session;
    confirm({
      title: returnHost ? `Sign ${user} out and return ${host}` : `Sign ${user} out of ${host}`,
      body: returnHost
        ? `${user}'s desktop on ${host} closes and anything unsaved is lost. The assignment ends now: the broker removes the account, and ${user} gets a host the next time they connect.`
        : `${user}'s desktop on ${host} closes and anything unsaved is lost. The host is released, so ${user} can reconnect to it until the grace period ends.`,
      confirmLabel: returnHost ? 'Sign out and return' : 'Sign out',
      variant: 'danger',
      onConfirm: async () => {
        try {
          const result = await signOut.mutateAsync({ hostname: host, username: user, returnHost });
          showToast(result.message, 'success');
        } catch (cause) {
          showToast(errorMessage(cause, `Unable to sign ${user} out of ${host}.`), 'danger');
        }
      },
    });
  }

  function requestMessage(session: ActionSession) {
    setMessageTo(session);
  }

  async function send(message: string) {
    if (!messageTo) {
      return;
    }
    try {
      const result = await sendMessage.mutateAsync({ hostname: messageTo.Hostname, username: messageTo.Username, message });
      showToast(result.message, result.Delivered ? 'success' : 'warning');
      setMessageTo(null);
    } catch (cause) {
      showToast(errorMessage(cause, `Unable to send the message to ${messageTo.Username}.`), 'danger');
    }
  }

  /** The actions this operator may take on this session, in menu order. */
  function actionsFor(session: ActionSession): ActionMenuItem[] {
    if (!can.operate || session.PowerState !== 'On' || session.State === 'cleanup-pending') {
      return [];
    }

    const items: ActionMenuItem[] = [];
    if (hasDesktop(session)) {
      items.push({ key: 'message', label: 'Send message', icon: 'box-arrow-right', onSelect: () => requestMessage(session) });
    }
    items.push({ key: 'signout', label: 'Sign out', icon: 'power', tone: 'danger', onSelect: () => requestSignOut(session) });
    if (session.HasAssignment) {
      items.push({
        key: 'signout-return',
        label: 'Sign out and return host',
        icon: 'arrow-return',
        tone: 'danger',
        onSelect: () => requestSignOut(session, true),
      });
    }
    return items;
  }

  const dialogs = (
    <>
      {dialog}
      <MessageDialog
        open={messageTo !== null}
        title={messageTo ? `Message ${messageTo.Username}` : 'Message'}
        recipients={messageTo ? `The message is shown in ${messageTo.Username}'s desktop on ${messageTo.Hostname}.` : ''}
        busy={sendMessage.isPending}
        onSend={(message) => void send(message)}
        onCancel={() => {
          if (!sendMessage.isPending) {
            setMessageTo(null);
          }
        }}
      />
    </>
  );

  return { actionsFor, requestSignOut, requestMessage, dialog: dialogs };
}
