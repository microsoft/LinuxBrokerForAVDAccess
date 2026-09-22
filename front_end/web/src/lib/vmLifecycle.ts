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

export function canRelease(vm: Pick<Vm, 'VmStatus'>): boolean {
  return vm.VmStatus === 'CheckedOut';
}

export function canReturn(vm: Pick<Vm, 'VmStatus'>): boolean {
  return vm.VmStatus === 'CheckedOut' || vm.VmStatus === 'Released';
}

/** A VM is ready only when it is powered on, reachable and unassigned. */
export function isReady(vm: Pick<Vm, 'VmStatus' | 'PowerState' | 'NetworkStatus'>): boolean {
  return (
    vm.VmStatus === 'Available' && vm.PowerState === 'On' && vm.NetworkStatus === 'Reachable'
  );
}
