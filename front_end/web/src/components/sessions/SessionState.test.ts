import { describe, expect, it } from 'vitest';

import { formatDuration } from '../../lib/format';
import type { BrokerSession } from '../../types/broker';
import { hasDesktop, sessionDetail } from './SessionState';

const BASE: BrokerSession = {
  Hostname: 'linux-host-01', VMID: 1, Username: 'alice', AvdHost: 'avd-01', State: 'active', VmStatus: 'CheckedOut',
  PowerState: 'On', NetworkStatus: 'Reachable', DrainRequested: false, HasAssignment: true, CleanupPending: false,
  ReportedState: 'active', SessionStartUtc: null, DisconnectedForSeconds: null, IdleSeconds: null,
  AssignedForSeconds: 600, LastCheckoutAgeSeconds: 600, GraceRemainingSeconds: null, GracePeriodSeconds: 1200,
  HeartbeatAgeSeconds: 20, HeartbeatFresh: true,
};

describe('formatDuration', () => {
  it('reads like a person would say it', () => {
    expect(formatDuration(null)).toBe('\u2014');
    expect(formatDuration(-5)).toBe('0 s');
    expect(formatDuration(45)).toBe('45 s');
    expect(formatDuration(90)).toBe('2 min');
    expect(formatDuration(3599)).toBe('1 h');
    expect(formatDuration(3600 + 5 * 60)).toBe('1 h 5 min');
    expect(formatDuration(26 * 3600)).toBe('1 d 2 h');
    expect(formatDuration(48 * 3600)).toBe('2 d');
  });
});

describe('sessionDetail', () => {
  it('describes each state in the operator’s terms', () => {
    expect(sessionDetail(BASE)).toBe('In use');
    expect(sessionDetail({ ...BASE, IdleSeconds: 30 })).toBe('In use');
    expect(sessionDetail({ ...BASE, IdleSeconds: 900 })).toBe('In use, idle 15 min');
    expect(sessionDetail({ ...BASE, State: 'disconnected', DisconnectedForSeconds: 300 })).toBe(
      'Disconnected 5 min ago; signed out in 15 min',
    );
    expect(sessionDetail({ ...BASE, State: 'disconnected', DisconnectedForSeconds: 300, GraceRemainingSeconds: 60 })).toBe(
      'Disconnected 5 min ago; grace ends in 1 min',
    );
    expect(sessionDetail({ ...BASE, State: 'released', GraceRemainingSeconds: 0 })).toBe(
      'Grace period over; the host returns to the pool shortly',
    );
    expect(sessionDetail({ ...BASE, State: 'connecting', LastCheckoutAgeSeconds: 40 })).toBe('Checked out 40 s ago');
    expect(sessionDetail({ ...BASE, State: 'not-connected', LastCheckoutAgeSeconds: 7200 })).toBe(
      'Checked out 2 h ago; no session since',
    );
    expect(sessionDetail({ ...BASE, State: 'unknown', HeartbeatAgeSeconds: null })).toBe('The host has never reported');
    expect(sessionDetail({ ...BASE, State: 'unknown', HeartbeatAgeSeconds: 1200 })).toBe('No host report for 20 min');
  });

  it('only offers a message where a desktop is running', () => {
    expect(hasDesktop({ State: 'active' })).toBe(true);
    expect(hasDesktop({ State: 'unmanaged' })).toBe(true);
    expect(hasDesktop({ State: 'released' })).toBe(false);
    expect(hasDesktop({ State: 'not-connected' })).toBe(false);
  });
});
