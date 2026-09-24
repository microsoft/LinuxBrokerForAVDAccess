import { describeSeconds } from './format';
import type { HostSettings, HostSettingsVersion } from '../types/broker';

/*
 * Field-by-field differences between saved versions of the host settings profile,
 * for the version history on the Host Settings page.
 */

interface FieldDescriptor {
  label: string;
  kind: 'seconds' | 'boolean';
}

export const SETTINGS_FIELDS: Record<string, FieldDescriptor> = {
  GracePeriodSeconds: { label: 'Reconnect grace period', kind: 'seconds' },
  ReconcileIntervalSeconds: { label: 'Reconcile interval', kind: 'seconds' },
  WatcherDebounceSeconds: { label: 'Watcher debounce', kind: 'seconds' },
  WatcherSettleSeconds: { label: 'Watcher settle', kind: 'seconds' },
  IdleTimeoutSeconds: { label: 'Idle timeout', kind: 'seconds' },
  IdleWarningSeconds: { label: 'Idle warning lead time', kind: 'seconds' },
  ScreenIdleDelaySeconds: { label: 'Screen blank delay', kind: 'seconds' },
  ScreenLockDelaySeconds: { label: 'Lock delay after blanking', kind: 'seconds' },
  ScreenLockEnabled: { label: 'Lock the screen when the screensaver activates', kind: 'boolean' },
  DisableLockScreen: { label: 'Remove the lock screen entirely', kind: 'boolean' },
  ScreenLockSettingsLocked: { label: 'Prevent users from changing screen lock settings', kind: 'boolean' },
  PreserveSessionsOnDisconnect: { label: 'Keep sessions alive during the grace period', kind: 'boolean' },
};

export interface SettingChange {
  field: string;
  label: string;
  from: string;
  to: string;
}

export interface SettingsVersionChanges {
  version: HostSettingsVersion;
  /** Null for the oldest version shown, which has nothing to compare against. */
  changes: SettingChange[] | null;
}

function describe(kind: FieldDescriptor['kind'], value: unknown): string {
  if (kind === 'boolean') {
    return value ? 'On' : 'Off';
  }
  const seconds = typeof value === 'number' ? value : Number(value);
  if (Number.isNaN(seconds)) {
    return String(value ?? '');
  }
  return `${seconds} s (${describeSeconds(seconds)})`;
}

export function diffSettings(
  previous: Partial<HostSettingsVersion>,
  next: Partial<HostSettingsVersion>,
): SettingChange[] {
  const changes: SettingChange[] = [];

  for (const [field, descriptor] of Object.entries(SETTINGS_FIELDS)) {
    const before = previous[field as keyof HostSettings];
    const after = next[field as keyof HostSettings];
    if (before === undefined || after === undefined || before === after) {
      continue;
    }
    changes.push({
      field,
      label: descriptor.label,
      from: describe(descriptor.kind, before),
      to: describe(descriptor.kind, after),
    });
  }

  return changes;
}

/** Pair each version, newest first, with what changed from the version before it. */
export function settingsHistoryChanges(versions: HostSettingsVersion[]): SettingsVersionChanges[] {
  return versions.map((version, index) => {
    const previous = versions[index + 1];
    return { version, changes: previous ? diffSettings(previous, version) : null };
  });
}
