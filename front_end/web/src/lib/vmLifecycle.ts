import type { LeaseGuard, Vm } from '../types/broker';

export function leaseGuard(vm: Pick<Vm, 'LeaseId' | 'LeaseGeneration'>): LeaseGuard | null {
  if (typeof vm.LeaseId !== 'string'
      || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(vm.LeaseId)
      || !Number.isSafeInteger(vm.LeaseGeneration) || vm.LeaseGeneration <= 0) {
    return null;
  }
  return { leaseId: vm.LeaseId, leaseGeneration: vm.LeaseGeneration };
}

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

export function canUpdateAttributes(vm: Pick<Vm, 'VmStatus' | 'LeaseId' | 'Username'>): boolean {
  return (vm.VmStatus === 'Available' || vm.VmStatus === 'Maintenance')
    && vm.LeaseId === null && !vm.Username;
}

/** Inventory conditions only; checkout readiness also requires broker-verified enrollment. */
export function hasAvailableHostAttributes(vm: Pick<Vm, 'VmStatus' | 'PowerState' | 'NetworkStatus'>): boolean {
  return (
    vm.VmStatus === 'Available' && vm.PowerState === 'On' && vm.NetworkStatus === 'Reachable'
  );
}
