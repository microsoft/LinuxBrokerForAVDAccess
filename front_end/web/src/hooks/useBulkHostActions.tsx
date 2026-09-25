import { useState } from 'react';

import { useToast } from '../components/ui/Toast';
import type { ButtonVariant } from '../components/ui/Button';
import { apiPost, errorMessage } from '../lib/api';
import { runBounded, summarizeBulk } from '../lib/bulk';
import type { BulkOutcome } from '../lib/bulk';
import { canDrain, canReturnToService, canStart, isAssigned } from '../lib/vmLifecycle';
import type { ApplySettingsResult, VmListItem } from '../types/broker';
import { useVmInvalidation } from './useBroker';
import { useConfirm } from './useConfirm';

export type BulkAction = 'drain' | 'undrain' | 'start' | 'stop' | 'apply' | 'delete';

/** Hosts acted on at once; the rest wait their turn. */
const CONCURRENCY = 4;

interface BulkSpec {
  label: string;
  verb: string;
  body: string;
  variant: ButtonVariant;
  eligible: (vm: VmListItem) => boolean;
  skipReason: string;
  run: (vm: VmListItem) => Promise<string>;
}

async function message(path: string, body?: unknown) {
  const result = await apiPost<{ message?: string }>(path, body);
  return result?.message ?? 'Done.';
}

export const BULK_ACTIONS: Record<BulkAction, BulkSpec> = {
  drain: {
    label: 'Drain',
    verb: 'Drained',
    body: 'Users keep their sessions and no one new is assigned; hosts without a user move to maintenance now.',
    variant: 'warning',
    eligible: canDrain,
    skipReason: 'already out of rotation',
    run: (vm) => message(`/vms/${vm.VMID}/drain`),
  },
  undrain: {
    label: 'Return to service',
    verb: 'Returned',
    body: 'They are offered to new users again.',
    variant: 'primary',
    eligible: canReturnToService,
    skipReason: 'already in service',
    run: (vm) => message(`/vms/${vm.VMID}/undrain`),
  },
  start: {
    label: 'Start',
    verb: 'Started',
    body: 'Each is offered to users once it is reachable.',
    variant: 'primary',
    eligible: (vm) => canStart(vm),
    skipReason: 'already on',
    run: (vm) => message(`/vms/${vm.VMID}/start`),
  },
  stop: {
    label: 'Stop',
    verb: 'Stopped',
    body: "Each stops with the scaling rule's stop mode. Scaling can start hosts again to keep its minimum; drain them to keep them out of rotation.",
    variant: 'warning',
    eligible: (vm) => vm.PowerState === 'On' && !isAssigned(vm),
    skipReason: 'off, or in use (stop a host in use from its own menu)',
    run: (vm) => message(`/vms/${vm.VMID}/stop`),
  },
  apply: {
    label: 'Apply settings',
    verb: 'Applied settings to',
    body: 'Pushes the current Linux host settings to each host now instead of at its next check.',
    variant: 'primary',
    eligible: (vm) => vm.PowerState === 'On' && vm.NetworkStatus === 'Reachable',
    skipReason: 'not reachable',
    run: async (vm) => {
      const result = await apiPost<ApplySettingsResult>('/hosts/settings/apply', { hostname: vm.Hostname });
      if (result.succeededCount < result.targetCount) {
        throw new Error(result.message || 'The host did not apply the settings.');
      }
      return result.message || 'Applied.';
    },
  },
  delete: {
    label: 'Delete',
    verb: 'Deleted',
    body: 'They are removed from the broker for good. The VMs in Azure are not touched.',
    variant: 'danger',
    eligible: (vm) => !isAssigned(vm),
    skipReason: 'in use (delete a host in use from its own menu)',
    run: (vm) => message(`/vms/${vm.VMID}/delete`),
  },
};

export interface BulkRun {
  label: string;
  outcomes: BulkOutcome[];
  skipped: string[];
}

/**
 * One action on many hosts: hosts it does not apply to are skipped and named, the rest
 * run a few at a time, and each host's outcome is kept for the summary.
 */
export function useBulkHostActions(onDone: () => void) {
  const { confirm, dialog } = useConfirm();
  const { showToast } = useToast();
  const invalidate = useVmInvalidation();
  const [running, setRunning] = useState<BulkAction | null>(null);
  const [lastRun, setLastRun] = useState<BulkRun | null>(null);

  function request(action: BulkAction, hosts: VmListItem[]) {
    const spec = BULK_ACTIONS[action];
    const eligible = hosts.filter(spec.eligible);
    const skipped = hosts.filter((vm) => !spec.eligible(vm));
    if (!eligible.length) {
      showToast(`${spec.label} does not apply to the selected hosts: ${spec.skipReason}.`, 'warning');
      return;
    }

    const count = `${eligible.length} host${eligible.length === 1 ? '' : 's'}`;
    const skippedText = skipped.length
      ? ` ${skipped.length} selected host${skipped.length === 1 ? ' is' : 's are'} skipped: ${spec.skipReason}.`
      : '';
    confirm({
      title: `${spec.label} ${count}?`,
      body: `${spec.body}${skippedText}${action === 'delete' ? ' Type delete to confirm.' : ''}`,
      confirmLabel: `${spec.label} ${count}`,
      variant: spec.variant,
      requireText: action === 'delete' ? 'delete' : undefined,
      onConfirm: async () => {
        setRunning(action);
        try {
          const outcomes = await runBounded(eligible, CONCURRENCY, async (vm): Promise<BulkOutcome> => {
            try {
              return { hostname: vm.Hostname, ok: true, message: await spec.run(vm) };
            } catch (cause) {
              return { hostname: vm.Hostname, ok: false, message: errorMessage(cause, 'The request failed.') };
            }
          });
          setLastRun({ label: spec.label, outcomes, skipped: skipped.map((vm) => vm.Hostname) });
          showToast(summarizeBulk(spec.verb, outcomes, skipped.length), outcomes.every((outcome) => outcome.ok) ? 'success' : 'warning');
        } finally {
          setRunning(null);
          invalidate();
          onDone();
        }
      },
    });
  }

  return { request, running, lastRun, clearLastRun: () => setLastRun(null), dialog };
}
