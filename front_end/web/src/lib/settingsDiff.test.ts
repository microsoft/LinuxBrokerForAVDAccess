import { describe, expect, it } from 'vitest';

import { formatAge, formatMegabytes, formatUtc } from './format';
import { diffSettings, settingsHistoryChanges } from './settingsDiff';
import type { HostSettingsVersion } from '../types/broker';

const BASE: HostSettingsVersion = {
  GracePeriodSeconds: 1200, ReconcileIntervalSeconds: 60, WatcherDebounceSeconds: 10,
  WatcherSettleSeconds: 2, IdleTimeoutSeconds: 0, IdleWarningSeconds: 120,
  ScreenLockEnabled: false, DisableLockScreen: true, ScreenIdleDelaySeconds: 0,
  ScreenLockDelaySeconds: 0, ScreenLockSettingsLocked: true, PreserveSessionsOnDisconnect: false,
  SettingsVersion: 3, UpdatedBy: 'alice@contoso.com', ValidFromUtc: '2026-08-01T10:00:00Z',
  ValidToUtc: '2026-09-01T10:00:00Z', IsCurrent: false,
};

describe('diffSettings', () => {
  it('lists only the fields that changed, with readable values', () => {
    const changes = diffSettings(BASE, { ...BASE, GracePeriodSeconds: 1800, PreserveSessionsOnDisconnect: true });
    expect(changes).toEqual([
      { field: 'GracePeriodSeconds', label: 'Reconnect grace period', from: '1200 s (20 minutes)', to: '1800 s (30 minutes)' },
      { field: 'PreserveSessionsOnDisconnect', label: 'Keep sessions alive during the grace period', from: 'Off', to: 'On' },
    ]);
  });

  it('describes a disabled idle timeout as disabled', () => {
    const [change] = diffSettings({ ...BASE, IdleTimeoutSeconds: 3600 }, BASE);
    expect(change.to).toBe('0 s (disabled)');
  });

  it('ignores the version and attribution columns', () => {
    expect(diffSettings(BASE, { ...BASE, SettingsVersion: 4, UpdatedBy: 'bob@contoso.com' })).toEqual([]);
  });
});

describe('settingsHistoryChanges', () => {
  it('compares each version with the one before it, newest first', () => {
    const current = { ...BASE, SettingsVersion: 5, IdleTimeoutSeconds: 900, IsCurrent: true, ValidToUtc: null };
    const middle = { ...BASE, SettingsVersion: 4, GracePeriodSeconds: 600 };
    const history = settingsHistoryChanges([current, middle, BASE]);

    expect(history.map((entry) => entry.version.SettingsVersion)).toEqual([5, 4, 3]);
    expect(history[0].changes?.map((change) => change.field)).toEqual(['GracePeriodSeconds', 'IdleTimeoutSeconds']);
    expect(history[1].changes?.map((change) => change.field)).toEqual(['GracePeriodSeconds']);
    expect(history[2].changes).toBeNull();
  });
});

describe('formatting helpers', () => {
  it.each([
    [null, '\u2014'],
    [10, 'just now'],
    [60, '1 min ago'],
    [600, '10 min ago'],
    [3600, '1 hour ago'],
    [7200, '2 hours ago'],
    [86400 * 3, '3 days ago'],
  ])('formats an age of %s seconds as %s', (seconds, expected) => {
    expect(formatAge(seconds)).toBe(expected);
  });

  it('shows UTC timestamps without guessing a zone', () => {
    expect(formatUtc('2026-09-24T12:00:05.123Z')).toBe('2026-09-24 12:00:05 UTC');
    expect(formatUtc('2026-09-24T12:00:05Z')).toBe('2026-09-24 12:00:05 UTC');
    expect(formatUtc('Wed, 24 Sep 2026 12:00:05 GMT')).toBe('Wed, 24 Sep 2026 12:00:05 GMT');
    expect(formatUtc(null)).toBe('\u2014');
  });

  it('switches to gigabytes above 1024 MB', () => {
    expect(formatMegabytes(512)).toBe('512 MB');
    expect(formatMegabytes(16000)).toBe('15.6 GB');
    expect(formatMegabytes(null)).toBe('\u2014');
  });
});
