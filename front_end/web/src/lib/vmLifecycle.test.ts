import { describe, expect, it } from 'vitest';

import {
  canDrain,
  canRelease,
  canRetryCleanup,
  canReturn,
  canReturnToService,
  canStart,
  canStopOrRestart,
  canToggleMaintenance,
  isAssigned,
  isReady,
} from '../lib/vmLifecycle';

/*
 * These four hosts mirror the fixtures in front_end/tests/conftest.py, and the
 * expectations are the ones the Jinja suite pinned in
 * test_vm_row_actions_follow_lifecycle_rules. ReleaseVm moves a CheckedOut host to
 * Released; ReturnVm moves CheckedOut or Released back to Available. Offering
 * either on an already Available host was misleading.
 */
const HOSTS = [
  { Hostname: 'linux-host-01', VmStatus: 'Available', release: false, return: false },
  { Hostname: 'linux-host-02', VmStatus: 'CheckedOut', release: true, return: true },
  { Hostname: 'linux-host-03', VmStatus: 'Maintenance', release: false, return: false },
  { Hostname: 'linux-host-04', VmStatus: 'Released', release: false, return: true },
];

describe('VM lifecycle actions', () => {
  it.each(HOSTS)('$Hostname ($VmStatus) offers the right actions', (host) => {
    expect(canRelease(host)).toBe(host.release);
    expect(canReturn(host)).toBe(host.return);
  });

  it('treats an unknown status as offering neither action', () => {
    expect(canRelease({ VmStatus: 'Rebuilding' })).toBe(false);
    expect(canReturn({ VmStatus: 'Rebuilding' })).toBe(false);
  });

  it('handles a missing status without throwing', () => {
    expect(canRelease({ VmStatus: null })).toBe(false);
    expect(canReturn({ VmStatus: null })).toBe(false);
  });
});

describe('isReady', () => {
  it('requires available, powered on and reachable together', () => {
    expect(
      isReady({ VmStatus: 'Available', PowerState: 'On', NetworkStatus: 'Reachable' }),
    ).toBe(true);
  });

  it.each([
    { VmStatus: 'CheckedOut', PowerState: 'On', NetworkStatus: 'Reachable' },
    { VmStatus: 'Available', PowerState: 'Off', NetworkStatus: 'Reachable' },
    { VmStatus: 'Available', PowerState: 'On', NetworkStatus: 'Unreachable' },
  ])('rejects %o', (vm) => {
    expect(isReady(vm)).toBe(false);
  });
});


describe('cleanup and maintenance lifecycle actions', () => {
  it('hides release and return while cleanup is pending', () => {
    expect(canRelease({ VmStatus: 'CheckedOut', CleanupPending: true })).toBe(false);
    expect(canReturn({ VmStatus: 'Released', CleanupPending: true })).toBe(false);
  });

  it('offers cleanup retry only while cleanup is pending', () => {
    expect(canRetryCleanup({ CleanupPending: true })).toBe(true);
    expect(canRetryCleanup({ CleanupPending: false })).toBe(false);
  });

  it('allows maintenance toggles only for unassigned available or maintenance hosts', () => {
    expect(canToggleMaintenance({ VmStatus: 'Available', Username: null, AvdHost: null })).toBe(true);
    expect(canToggleMaintenance({ VmStatus: 'Maintenance', Username: null, AvdHost: null })).toBe(true);
    expect(canToggleMaintenance({ VmStatus: 'Available', Username: 'user', AvdHost: null })).toBe(false);
    expect(canToggleMaintenance({ VmStatus: 'CheckedOut', Username: null, AvdHost: null })).toBe(false);
  });
});

describe('host actions', () => {
  const idle = { VmStatus: 'Available', Username: null, PowerState: 'On', DrainRequested: false };
  const inUse = { VmStatus: 'CheckedOut', Username: 'alice', PowerState: 'On', DrainRequested: false };

  it('treats a checked-out or released host, or one with a user, as in use', () => {
    expect(isAssigned(idle)).toBe(false);
    expect(isAssigned(inUse)).toBe(true);
    expect(isAssigned({ VmStatus: 'Released', Username: null })).toBe(true);
    expect(isAssigned({ VmStatus: 'Available', Username: 'leftover' })).toBe(true);
  });

  it('offers start only to a host that is not running', () => {
    expect(canStart({ PowerState: 'Off' })).toBe(true);
    expect(canStart({ PowerState: null })).toBe(true);
    expect(canStart({ PowerState: 'On' })).toBe(false);
  });

  it('lets an operator stop an idle host but only an administrator stop one in use', () => {
    expect(canStopOrRestart(idle, false)).toBe(true);
    expect(canStopOrRestart(inUse, false)).toBe(false);
    expect(canStopOrRestart(inUse, true)).toBe(true);
    expect(canStopOrRestart({ ...idle, PowerState: 'Off' }, true)).toBe(false);
  });

  it('offers drain until the host is draining or in maintenance, then return to service', () => {
    expect(canDrain(idle)).toBe(true);
    expect(canDrain(inUse)).toBe(true);
    expect(canReturnToService(idle)).toBe(false);

    const draining = { ...inUse, DrainRequested: true };
    expect(canDrain(draining)).toBe(false);
    expect(canReturnToService(draining)).toBe(true);

    const maintenance = { ...idle, VmStatus: 'Maintenance' };
    expect(canDrain(maintenance)).toBe(false);
    expect(canReturnToService(maintenance)).toBe(true);
  });
});
