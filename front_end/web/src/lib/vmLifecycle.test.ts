import { describe, expect, it } from 'vitest';

import { canRelease, canReturn, canUpdateAttributes, hasAvailableHostAttributes, leaseGuard } from '../lib/vmLifecycle';

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

describe('hasAvailableHostAttributes', () => {
  it('requires available, powered on and reachable together', () => {
    expect(
      hasAvailableHostAttributes({ VmStatus: 'Available', PowerState: 'On', NetworkStatus: 'Reachable' }),
    ).toBe(true);
  });

  it.each([
    { VmStatus: 'CheckedOut', PowerState: 'On', NetworkStatus: 'Reachable' },
    { VmStatus: 'Available', PowerState: 'Off', NetworkStatus: 'Reachable' },
    { VmStatus: 'Available', PowerState: 'On', NetworkStatus: 'Unreachable' },
  ])('rejects %o', (vm) => {
    expect(hasAvailableHostAttributes(vm)).toBe(false);
  });
});

describe('leaseGuard', () => {
  const LeaseId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

  it.each([1, 7, 9007199254740991])('preserves the exact safe JSON generation %s', (LeaseGeneration) => {
    const guard = leaseGuard({ LeaseId, LeaseGeneration });
    expect(guard).toEqual({
      leaseId: LeaseId, leaseGeneration: LeaseGeneration,
    });
    expect(JSON.stringify(guard)).toBe(`{"leaseId":"${LeaseId}","leaseGeneration":${LeaseGeneration}}`);
  });

  it.each([
    { LeaseId: null, LeaseGeneration: 0 },
    { LeaseId: '', LeaseGeneration: 7 },
    { LeaseId: 'not-a-lease', LeaseGeneration: 7 },
    { LeaseId, LeaseGeneration: -1 },
    { LeaseId, LeaseGeneration: 0 },
    { LeaseId, LeaseGeneration: 7.5 },
    { LeaseId, LeaseGeneration: Number.NaN },
    { LeaseId, LeaseGeneration: 9007199254740992 },
    { LeaseId, LeaseGeneration: Number('9223372036854775807') },
  ])('does not invent a guard for %o', (vm) => {
    expect(leaseGuard(vm)).toBeNull();
  });
});

describe('canUpdateAttributes', () => {
  it.each(['Available', 'Maintenance'])('allows an unassigned %s host', (VmStatus) => {
    expect(canUpdateAttributes({ VmStatus, LeaseId: null, Username: null })).toBe(true);
  });

  it.each([
    { VmStatus: 'CheckedOut', LeaseId: 'lease', Username: 'user' },
    { VmStatus: 'Released', LeaseId: 'lease', Username: 'user' },
    { VmStatus: 'Available', LeaseId: 'lease', Username: null },
    { VmStatus: 'Maintenance', LeaseId: 'lease', Username: 'user' },
    { VmStatus: 'Maintenance', LeaseId: null, Username: 'user' },
  ])('rejects an assigned host: %o', (vm) => {
    expect(canUpdateAttributes(vm)).toBe(false);
  });
});
