import type { ActionMenuItem } from '../components/ui/ActionMenu';
import { useToast } from '../components/ui/Toast';
import { usePowerAction, useSetVmDrain } from './useBroker';
import type { PowerAction } from './useBroker';
import { useConfirm } from './useConfirm';
import { useCan } from './useSession';
import { errorMessage } from '../lib/api';
import { canDrain, canReturnToService, canStart, canStopOrRestart, isAssigned } from '../lib/vmLifecycle';
import type { Vm } from '../types/broker';

type ActionVm = Pick<Vm, 'VMID' | 'Hostname' | 'VmStatus' | 'Username' | 'PowerState' | 'DrainRequested'>;

interface PowerCopy {
  verb: string;
  title: string;
  body: string;
  confirmLabel: string;
}

function powerCopy(vm: ActionVm, action: PowerAction, deallocate: boolean): PowerCopy {
  const host = vm.Hostname;
  const user = vm.Username ?? 'A user';
  const inUse = isAssigned(vm);

  if (action === 'start') {
    return {
      verb: 'start',
      title: `Start ${host}`,
      body: `Start ${host} in Azure? It is offered to users as soon as it is reachable.`,
      confirmLabel: 'Start',
    };
  }

  if (action === 'restart') {
    return {
      verb: 'restart',
      title: `Restart ${host}`,
      body: inUse
        ? `${user} is signed in to ${host}. Restarting ends their session; they can reconnect to the same host once it is back.`
        : `Restart ${host}? It is out of rotation until it is reachable again.`,
      confirmLabel: 'Restart',
    };
  }

  const how = deallocate ? 'deallocates' : 'powers off';
  return {
    verb: deallocate ? 'deallocate' : 'stop',
    title: deallocate ? `Deallocate ${host}` : `Stop ${host}`,
    body: inUse
      ? `${user} is signed in to ${host}. Stopping it ends their session and their assignment, and they get another host when they reconnect. The VM ${how}.`
      : deallocate
        ? `Deallocate ${host}? Azure releases its compute, so it stops costing compute but may take longer to start, and capacity is not guaranteed when you start it again. Scaling can start it again to keep the minimum number of hosts; drain it instead to keep it out of rotation.`
        : `Stop ${host}? The VM ${how} using the scaling rule's stop mode. Scaling can start it again to keep the minimum number of hosts; drain it instead to keep it out of rotation.`,
    confirmLabel: deallocate ? 'Deallocate' : 'Stop',
  };
}

/**
 * Start, stop, restart, drain and return to service for one host, with the
 * confirmation each needs and the toast that reports it.
 *
 * Every dialog names the host and, when there is one, its current user. Stopping or
 * restarting a host that is in use also asks for its hostname to be typed, which the
 * broker requires before it will end someone's session.
 */
export function useHostActions() {
  const can = useCan();
  const { showToast } = useToast();
  const { confirm, dialog } = useConfirm();
  const powerAction = usePowerAction();
  const setDrain = useSetVmDrain();

  function requestPower(vm: ActionVm, action: PowerAction, deallocate = false) {
    const copy = powerCopy(vm, action, deallocate);
    const inUse = action !== 'start' && isAssigned(vm);

    confirm({
      title: copy.title,
      body: copy.body,
      confirmLabel: copy.confirmLabel,
      variant: inUse ? 'danger' : action === 'start' ? 'primary' : 'warning',
      requireText: inUse ? vm.Hostname : undefined,
      onConfirm: async () => {
        try {
          const result = await powerAction.mutateAsync({
            vmid: vm.VMID,
            action,
            confirm: inUse ? vm.Hostname : undefined,
            mode: action === 'stop' && deallocate ? 'Deallocate' : undefined,
          });
          showToast(result.message || `${copy.title} requested.`, 'success');
        } catch (cause) {
          showToast(errorMessage(cause, `Unable to ${copy.verb} ${vm.Hostname}.`), 'danger');
        }
      },
    });
  }

  function requestDrain(vm: ActionVm, enabled: boolean) {
    const host = vm.Hostname;
    const body = !enabled
      ? `Return ${host} to service? It is offered to new users again.`
      : isAssigned(vm)
        ? `Drain ${host}? ${vm.Username ?? 'The current user'} keeps the session and can reconnect, but no one new is assigned. The host moves to maintenance when the assignment ends.`
        : `Take ${host} out of rotation? It has no user, so it moves to maintenance now.`;

    confirm({
      title: enabled ? `Drain ${host}` : `Return ${host} to service`,
      body,
      confirmLabel: enabled ? 'Drain' : 'Return to service',
      variant: enabled ? 'warning' : 'primary',
      onConfirm: async () => {
        try {
          const result = await setDrain.mutateAsync({ vmid: vm.VMID, enabled });
          showToast(result.message, 'success');
        } catch (cause) {
          showToast(errorMessage(cause, `Unable to update ${host}.`), 'danger');
        }
      },
    });
  }

  /** The actions this operator may take on this host, in menu order. */
  function actionsFor(vm: ActionVm): ActionMenuItem[] {
    if (!can.operate) {
      return [];
    }

    const items: ActionMenuItem[] = [];

    if (canStart(vm)) {
      items.push({ key: 'start', label: 'Start', icon: 'power', onSelect: () => requestPower(vm, 'start') });
    }
    if (canStopOrRestart(vm, can.admin)) {
      items.push(
        { key: 'restart', label: 'Restart', icon: 'refresh', tone: 'warning', onSelect: () => requestPower(vm, 'restart') },
        { key: 'stop', label: 'Stop', icon: 'power', tone: 'warning', onSelect: () => requestPower(vm, 'stop') },
        { key: 'deallocate', label: 'Stop and deallocate', icon: 'power', tone: 'warning', onSelect: () => requestPower(vm, 'stop', true) },
      );
    }
    if (canDrain(vm)) {
      items.push({ key: 'drain', label: 'Drain', icon: 'box-arrow-right', tone: 'warning', onSelect: () => requestDrain(vm, true) });
    }
    if (canReturnToService(vm)) {
      items.push({ key: 'undrain', label: 'Return to service', icon: 'check-circle', onSelect: () => requestDrain(vm, false) });
    }

    return items;
  }

  return { actionsFor, requestPower, requestDrain, dialog };
}
