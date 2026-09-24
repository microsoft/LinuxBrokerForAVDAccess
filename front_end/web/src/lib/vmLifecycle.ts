import type { Vm } from '../types/broker';

/*
 * Which lifecycle actions a VM row offers.
 *
 * Release ends an active checkout, so it only applies to a VM that is actually
 * checked out. Return puts a VM back in the pool, which is meaningful for a
 * checked-out VM and for one left in Released with a lingering assignment. These
 * used to be inline conditions in the Jinja table; keeping them here means the
 * table and the tests agree on one definition.
 */

export function canRelease(vm: Pick<Vm, 'VmStatus' | 'CleanupPending'>): boolean {
  return vm.VmStatus === 'CheckedOut' && !vm.CleanupPending;
}

export function canReturn(vm: Pick<Vm, 'VmStatus' | 'CleanupPending'>): boolean {
  return !vm.CleanupPending && (vm.VmStatus === 'CheckedOut' || vm.VmStatus === 'Released');
}

export function canRetryCleanup(vm: Pick<Vm, 'CleanupPending'>): boolean {
  return Boolean(vm.CleanupPending);
}

export function canToggleMaintenance(
  vm: Pick<Vm, 'VmStatus' | 'Username' | 'AvdHost'>,
): boolean {
  return (
    (vm.VmStatus === 'Available' || vm.VmStatus === 'Maintenance') &&
    !vm.Username &&
    !vm.AvdHost
  );
}

/** A VM is ready only when it is powered on, reachable and unassigned. */
export function isReady(vm: Pick<Vm, 'VmStatus' | 'PowerState' | 'NetworkStatus'>): boolean {
  return (
    vm.VmStatus === 'Available' && vm.PowerState === 'On' && vm.NetworkStatus === 'Reachable'
  );
}

/*
 * Host actions. A host is in use while a user is assigned to it, and stopping or
 * restarting it then ends that user's session, so the broker only allows it for an
 * administrator who types the hostname. The portal hides what the broker would refuse.
 */

type ActionVm = Pick<Vm, 'VmStatus' | 'Username' | 'PowerState' | 'DrainRequested'>;

export function isAssigned(vm: Pick<Vm, 'VmStatus' | 'Username'>): boolean {
  return Boolean(vm.Username) || vm.VmStatus === 'CheckedOut' || vm.VmStatus === 'Released';
}

export function canStart(vm: Pick<Vm, 'PowerState'>): boolean {
  return vm.PowerState !== 'On';
}

/** Stop and restart apply to a running host; one that is in use needs an administrator. */
export function canStopOrRestart(vm: ActionVm, isAdmin: boolean): boolean {
  return vm.PowerState === 'On' && (isAdmin || !isAssigned(vm));
}

export function canDrain(vm: ActionVm): boolean {
  return !vm.DrainRequested && vm.VmStatus !== 'Maintenance';
}

export function canReturnToService(vm: ActionVm): boolean {
  return Boolean(vm.DrainRequested) || (vm.VmStatus === 'Maintenance' && !vm.Username);
}
