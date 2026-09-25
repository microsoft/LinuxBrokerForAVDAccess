import { useNavigate } from 'react-router-dom';

import type { ActionMenuItem } from '../components/ui/ActionMenu';
import { useToast } from '../components/ui/Toast';
import { errorMessage } from '../lib/api';
import { canRelease, canRetryCleanup, canReturn } from '../lib/vmLifecycle';
import type { Vm } from '../types/broker';
import { useCleanupVm, useDeleteVm, useReleaseVm, useReturnVm } from './useBroker';
import { useConfirm } from './useConfirm';
import { useHostActions } from './useHostActions';
import { useCan } from './useSession';

/**
 * Every action one host row offers, as a single menu: power and rotation, the assignment
 * (release, return, retry cleanup), and for administrators edit and delete. Each confirms
 * first and names the host.
 */
export function useHostRowActions() {
  const navigate = useNavigate();
  const can = useCan();
  const { showToast } = useToast();
  const { confirm, dialog } = useConfirm();
  const hostActions = useHostActions();
  const releaseVm = useReleaseVm();
  const returnVm = useReturnVm();
  const deleteVm = useDeleteVm();
  const cleanupVm = useCleanupVm();

  function confirmRelease(vm: Vm) {
    confirm({
      title: `Release ${vm.Hostname}`,
      body: `Release ${vm.Hostname}? It stays ${vm.Username ?? 'the user'}'s for the grace period, then returns to the pool.`,
      confirmLabel: 'Release',
      variant: 'warning',
      onConfirm: async () => {
        try {
          await releaseVm.mutateAsync(vm.Hostname);
          showToast(`Released ${vm.Hostname}.`, 'success');
        } catch (cause) {
          showToast(errorMessage(cause, `Unable to release ${vm.Hostname}.`), 'danger');
        }
      },
    });
  }

  function confirmReturn(vm: Vm) {
    confirm({
      title: `Return ${vm.Hostname}`,
      body: `Return ${vm.Hostname} to the pool now? ${vm.Username ?? 'Its user'} is removed from it, and it is offered to the next user once that is done.`,
      confirmLabel: 'Return',
      variant: 'primary',
      onConfirm: async () => {
        try {
          const result = await returnVm.mutateAsync(vm.VMID);
          showToast(result.CleanupPending ? `Returned ${vm.Hostname}; its cleanup is still pending.` : `Returned ${vm.Hostname}.`, result.CleanupPending ? 'warning' : 'success');
        } catch (cause) {
          showToast(errorMessage(cause, `Unable to return ${vm.Hostname}.`), 'danger');
        }
      },
    });
  }

  function confirmCleanup(vm: Vm) {
    confirm({
      title: `Retry cleanup on ${vm.Hostname}`,
      body: `Retry removing the previous user's account and mounts from ${vm.Hostname}?`,
      confirmLabel: 'Retry cleanup',
      variant: 'warning',
      onConfirm: async () => {
        try {
          const result = await cleanupVm.mutateAsync(vm.VMID);
          showToast(result.message || `Cleanup retried on ${vm.Hostname}.`, 'success');
        } catch (cause) {
          showToast(errorMessage(cause, `Unable to retry cleanup on ${vm.Hostname}.`), 'danger');
        }
      },
    });
  }

  function confirmDelete(vm: Vm) {
    confirm({
      title: `Delete ${vm.Hostname}`,
      body: vm.Username
        ? `Permanently delete ${vm.Hostname} (VMID ${vm.VMID}) from the broker? ${vm.Username} is assigned to it, and the broker stops tracking that assignment. The VM in Azure is not touched.`
        : `Permanently delete ${vm.Hostname} (VMID ${vm.VMID}) from the broker? The VM in Azure is not touched.`,
      confirmLabel: 'Delete',
      variant: 'danger',
      requireText: vm.Username ? vm.Hostname : undefined,
      onConfirm: async () => {
        try {
          await deleteVm.mutateAsync(vm.VMID);
          showToast(`Deleted ${vm.Hostname}.`, 'success');
        } catch (cause) {
          showToast(errorMessage(cause, `Unable to delete ${vm.Hostname}.`), 'danger');
        }
      },
    });
  }

  function menuFor(vm: Vm): ActionMenuItem[] {
    const items = [...hostActions.actionsFor(vm)];
    if (can.operate && canRelease(vm)) {
      items.push({ key: 'release', label: 'Release', icon: 'box-arrow-right', tone: 'warning', onSelect: () => confirmRelease(vm) });
    }
    if (can.operate && canReturn(vm)) {
      items.push({ key: 'return', label: 'Return to the pool', icon: 'arrow-return', onSelect: () => confirmReturn(vm) });
    }
    if (can.operate && canRetryCleanup(vm)) {
      items.push({ key: 'cleanup', label: 'Retry cleanup', icon: 'refresh', tone: 'warning', onSelect: () => confirmCleanup(vm) });
    }
    if (can.admin) {
      items.push(
        { key: 'edit', label: 'Update attributes', icon: 'pencil', onSelect: () => navigate(`/vms/${vm.VMID}/update`) },
        { key: 'delete', label: 'Delete', icon: 'trash', tone: 'danger', onSelect: () => confirmDelete(vm) },
      );
    }
    return items;
  }

  return {
    menuFor,
    dialogs: (
      <>
        {dialog}
        {hostActions.dialog}
      </>
    ),
  };
}
