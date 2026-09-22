import { describe, expect, it } from 'vitest';

import { canRelease, canReturn, isReady } from '../lib/vmLifecycle';

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
