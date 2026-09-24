import { useEffect, useState } from 'react';

import { DataTable } from '../../components/data/DataTable';
import type { Column } from '../../components/data/DataTable';
import { Badge, NetworkBadge, PowerBadge } from '../../components/ui/Badge';
import { Button } from '../../components/ui/Button';
import { Checkbox, TextField } from '../../components/ui/Field';
import {
  EmptyState,
  ErrorPanel,
  LoadingPanel,
  Notice,
  PageHeader,
  Spinner,
} from '../../components/ui/Feedback';
import { GlassCard } from '../../components/ui/GlassCard';
import { useToast } from '../../components/ui/Toast';
import { useApplyHostSettings, useHostSettings, useHostSettingsHistory, useSaveHostSettings } from '../../hooks/useBroker';
import { useCan } from '../../hooks/useSession';
import { errorMessage } from '../../lib/api';
import { formatUtc, valueOrDash } from '../../lib/format';
import { settingsHistoryChanges } from '../../lib/settingsDiff';
import type { HostSettings, Vm } from '../../types/broker';

interface NumberFieldSpec {
  key: keyof HostSettings;
  label: string;
  help: string;
  min: number;
  max: number;
}

const LIFECYCLE_FIELDS: NumberFieldSpec[] = [
  {
    key: 'GracePeriodSeconds',
    label: 'Reconnect grace period (seconds)',
    help: 'How long a disconnected user can reconnect and resume before their account is removed and the VM returns to the pool. Between 60 and 86400. Default 1200 (20 minutes).',
    min: 60,
    max: 86400,
  },
  {
    key: 'ReconcileIntervalSeconds',
    label: 'Reconcile interval (seconds)',
    help: 'How often each host re-checks session state. Lower values detect disconnects sooner but poll the broker more often. Between 30 and 900. Default 60.',
    min: 30,
    max: 900,
  },
  {
    key: 'WatcherDebounceSeconds',
    label: 'Watcher debounce (seconds)',
    help: 'Minimum gap between logind-triggered reconciliations. Between 1 and 300.',
    min: 1,
    max: 300,
  },
  {
    key: 'WatcherSettleSeconds',
    label: 'Watcher settle (seconds)',
    help: 'Pause after a logind signal before reconciling. Between 0 and 60.',
    min: 0,
    max: 60,
  },
];

const IDLE_FIELDS: NumberFieldSpec[] = [
  {
    key: 'IdleTimeoutSeconds',
    label: 'Idle timeout (seconds)',
    help: 'Disconnect a connected user after this much inactivity. If keep-sessions-alive is on, reconnect resumes open applications during the grace period; otherwise the user receives a fresh desktop on the same host. Enter 0 to disable, otherwise at least 300.',
    min: 0,
    max: 86400,
  },
  {
    key: 'IdleWarningSeconds',
    label: 'Idle warning lead time (seconds)',
    help: 'How long before the idle timeout the user is warned on screen. Must be less than the idle timeout. Between 0 and 900, where 0 means no warning.',
    min: 0,
    max: 900,
  },
];

const SCREEN_FIELDS: NumberFieldSpec[] = [
  {
    key: 'ScreenIdleDelaySeconds',
    label: 'Screen blank delay (seconds)',
    help: 'Inactivity before the screen blanks. 0 means never blank. Between 0 and 86400.',
    min: 0,
    max: 86400,
  },
  {
    key: 'ScreenLockDelaySeconds',
    label: 'Lock delay after blanking (seconds)',
    help: 'Grace period between the screen blanking and locking. 0 locks immediately. Between 0 and 86400.',
    min: 0,
    max: 86400,
  },
];

type FormState = Record<string, string | boolean>;

function toFormState(settings: HostSettings): FormState {
  return { ...settings } as unknown as FormState;
}

export function HostSettingsPage() {
  const { showToast } = useToast();
  const { data, isPending, error } = useHostSettings();
  const saveSettings = useSaveHostSettings();
  const applySettings = useApplyHostSettings();
  const can = useCan();

  const [form, setForm] = useState<FormState | null>(null);

  // Seeded whenever the server's settings version changes, so a save refreshes the
  // form without discarding edits made against the same version.
  useEffect(() => {
    if (data?.settings) {
      setForm(toFormState(data.settings));
    }
  }, [data?.settings]);

  if (isPending) {
    return <LoadingPanel label="Loading host settings" />;
  }

  if (error || !data || !form) {
    return <ErrorPanel message={errorMessage(error, 'Unable to retrieve host settings.')} />;
  }

  const settings = data.settings;

  function setValue(key: string, value: string | boolean) {
    setForm((current) => (current ? { ...current, [key]: value } : current));
  }

  function numberValue(key: keyof HostSettings) {
    const value = form?.[key as string];
    return value === undefined || value === null ? '' : String(value);
  }

  function boolValue(key: keyof HostSettings) {
    return Boolean(form?.[key as string]);
  }

  async function save(event: React.FormEvent) {
    event.preventDefault();
    if (!form || !can.admin) {
      return;
    }

    // Field names are lowercased on the way out because the BFF maps them back to
    // the API's PascalCase payload in one place.
    const payload: Record<string, string | boolean> = {};
    for (const [key, value] of Object.entries(form)) {
      payload[key.toLowerCase()] = value;
    }

    try {
      const result = await saveSettings.mutateAsync(payload as never);
      showToast(result.message, result.tone);
    } catch (cause) {
      showToast(errorMessage(cause, 'Unable to save host settings.'), 'danger');
    }
  }

  async function apply(hostname?: string) {
    if (!can.operate) {
      return;
    }
    try {
      const result = await applySettings.mutateAsync(hostname);
      showToast(result.message, result.tone);
    } catch (cause) {
      showToast(errorMessage(cause, 'Unable to push host settings.'), 'danger');
    }
  }

  const numberField = (field: NumberFieldSpec) => (
    <TextField
      key={String(field.key)}
      label={field.label}
      help={field.help}
      type="number"
      min={field.min}
      max={field.max}
      required
      value={numberValue(field.key)}
      onChange={(event) => setValue(String(field.key), event.target.value)}
    />
  );

  return (
    <>
      <PageHeader
        title="Linux host settings"
        subtitle="Session lifecycle, idle handling and screen lock policy for every Linux host."
        icon="wrench"
        actions={
          <Badge tone="neutral" icon="shield">
            Settings version {settings.SettingsVersion}
          </Badge>
        }
      />

      <Notice tone="info" className="mb-5">
        These settings apply to every Linux host. Hosts fetch them on each reconcile run, so a saved
        change reaches the fleet on its own, including hosts that are currently powered off or
        created later by scale-up. Use <strong>Apply Now</strong> only when you want a change to
        take effect immediately.
      </Notice>

      <GlassCard className="p-6">
        <form onSubmit={save} noValidate>
          <h2 className="mb-3 text-xs font-semibold tracking-wider text-muted uppercase">
            Session lifecycle
          </h2>
          <div className="grid grid-cols-1 gap-5 md:grid-cols-2">
            {LIFECYCLE_FIELDS.map(numberField)}
          </div>
          <div className="mt-4">
            <Checkbox
              label="Keep sessions alive during the grace period"
              help={
                boolValue('ScreenLockEnabled')
                  ? 'Cannot be combined with screen lock: a resumed locked xrdp session cannot be unlocked because users never know their rotating password.'
                  : 'Disconnected desktops stay running until the grace period expires so reconnect resumes open applications and idle disconnects become resumable. Sessions hold memory while disconnected. Hosts must run the updated agent (deploy/Migrate-LinuxHostReleaseAgent.ps1), otherwise they show as pending.'
              }
              checked={boolValue('PreserveSessionsOnDisconnect')}
              disabled={boolValue('ScreenLockEnabled')}
              onChange={(checked) => setValue('PreserveSessionsOnDisconnect', checked)}
            />
          </div>

          <hr className="my-6 border-[var(--lb-hairline)]" />

          <h2 className="mb-3 text-xs font-semibold tracking-wider text-muted uppercase">
            Idle sessions
          </h2>
          {settings.IdleTimeoutSeconds === 0 ? (
            <Notice tone="warning" className="mb-4">
              Idle enforcement is currently disabled.
            </Notice>
          ) : null}
          <div className="grid grid-cols-1 gap-5 md:grid-cols-2">{IDLE_FIELDS.map(numberField)}</div>

          <hr className="my-6 border-[var(--lb-hairline)]" />

          <h2 className="mb-3 text-xs font-semibold tracking-wider text-muted uppercase">
            Screen lock
          </h2>
          <Notice tone="warning" className="mb-4">
            A locked GNOME greeter inside an xrdp session frequently cannot be unlocked after a
            reconnect, which strands the host&apos;s lease. The defaults therefore disable the lock
            screen. Only enable it if you have an idle-lock control to satisfy.
          </Notice>

          <div className="flex flex-col gap-4">
            <Checkbox
              label="Remove the lock screen entirely"
              help="Disables the Super+L shortcut and the Lock entry in the system menu, so a user cannot lock the session manually."
              checked={boolValue('DisableLockScreen')}
              onChange={(checked) => setValue('DisableLockScreen', checked)}
            />
            <Checkbox
              label="Lock the screen when the screensaver activates"
              help={
                boolValue('PreserveSessionsOnDisconnect')
                  ? 'Cannot be combined with keep-sessions-alive: a resumed session behind a lock screen cannot be unlocked because users never know their rotating password.'
                  : 'Off by default, for the reason above.'
              }
              checked={boolValue('ScreenLockEnabled')}
              disabled={boolValue('PreserveSessionsOnDisconnect')}
              onChange={(checked) => setValue('ScreenLockEnabled', checked)}
            />

            <div className="grid grid-cols-1 gap-5 md:grid-cols-2">
              {SCREEN_FIELDS.map(numberField)}
            </div>

            <Checkbox
              label="Prevent users from changing these screen lock settings"
              help="Applies dconf locks so the values above cannot be overridden inside a session."
              checked={boolValue('ScreenLockSettingsLocked')}
              onChange={(checked) => setValue('ScreenLockSettingsLocked', checked)}
            />
          </div>

          <div className="mt-6 flex flex-wrap gap-2">
            <Button
              type="submit"
              variant="primary"
              icon="check-circle"
              disabled={saveSettings.isPending || !can.admin}
            >
              {saveSettings.isPending ? 'Saving…' : 'Save settings'}
            </Button>
          </div>
        </form>
      </GlassCard>

      <div className="mt-8 mb-4 flex flex-wrap items-center justify-between gap-2">
        <h2 className="m-0 text-lg">Host status</h2>
        <Button
          icon="refresh"
          size="sm"
          disabled={applySettings.isPending || !can.operate}
          onClick={() => void apply()}
        >
          {applySettings.isPending ? 'Applying…' : 'Apply now to all hosts'}
        </Button>
      </div>

      <DriftTable
        hosts={data.hosts}
        currentVersion={settings.SettingsVersion}
        onApply={(hostname) => void apply(hostname)}
        busy={applySettings.isPending}
        canApply={can.operate}
      />

      <SettingsHistory />
    </>
  );
}

function SettingsHistory() {
  const { data, isPending, error } = useHostSettingsHistory();
  const entries = data ? settingsHistoryChanges(data) : [];

  return (
    <>
      <h2 className="mt-10 mb-4 text-lg">Version history</h2>

      {isPending ? <Spinner label="Loading version history" /> : null}

      {error ? (
        <Notice tone="warning">{errorMessage(error, 'Unable to retrieve the version history.')}</Notice>
      ) : null}

      {data && entries.length === 0 ? (
        <p className="text-sm text-muted">No saved versions yet.</p>
      ) : null}

      {entries.length > 0 ? (
        <GlassCard className="px-5 py-1">
          <ol className="m-0 list-none divide-y divide-[var(--lb-hairline)] p-0">
            {entries.map(({ version, changes }) => (
              <li key={`${version.SettingsVersion}-${version.ValidFromUtc}`} className="py-4">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="flex items-center gap-2">
                    <strong>Version {version.SettingsVersion}</strong>
                    {version.IsCurrent ? (
                      <Badge tone="ok" icon="check-circle">
                        Current
                      </Badge>
                    ) : null}
                  </span>
                  <span className="text-xs text-muted">
                    {version.UpdatedBy ? `Saved by ${version.UpdatedBy}` : 'Saved before changes were attributed'}
                    {' \u00b7 '}
                    <span className="font-mono">{formatUtc(version.ValidFromUtc)}</span>
                  </span>
                </div>

                {changes === null ? (
                  <p className="mt-1 mb-0 text-xs text-muted">The earliest version kept.</p>
                ) : changes.length === 0 ? (
                  <p className="mt-1 mb-0 text-xs text-muted">No setting changed in this version.</p>
                ) : (
                  <ul className="mt-2 mb-0 flex list-none flex-col gap-1 p-0 text-sm">
                    {changes.map((change) => (
                      <li key={change.field}>
                        <span className="text-muted">{change.label}:</span> {change.from}{' '}
                        <span aria-hidden>{'\u2192'}</span>
                        <span className="sr-only">changed to</span> <strong>{change.to}</strong>
                      </li>
                    ))}
                  </ul>
                )}
              </li>
            ))}
          </ol>
        </GlassCard>
      ) : null}
    </>
  );
}

function DriftTable({
  hosts,
  currentVersion,
  onApply,
  busy,
  canApply,
}: {
  hosts: Vm[];
  currentVersion: number;
  onApply: (hostname: string) => void;
  busy: boolean;
  canApply: boolean;
}) {
  if (hosts.length === 0) {
    return (
      <EmptyState
        title="No Linux hosts registered"
        message="Hosts appear here once they are registered with the broker."
        icon="server"
      />
    );
  }

  const columns: Array<Column<Vm>> = [
    {
      key: 'hostname',
      header: 'Hostname',
      sort: 'text',
      value: (host) => host.Hostname,
      className: 'font-semibold whitespace-nowrap',
      render: (host) => host.Hostname,
    },
    {
      key: 'power',
      header: 'Power',
      sort: 'text',
      value: (host) => host.PowerState,
      render: (host) => <PowerBadge value={host.PowerState} />,
    },
    {
      key: 'network',
      header: 'Network',
      sort: 'text',
      value: (host) => host.NetworkStatus,
      render: (host) => <NetworkBadge value={host.NetworkStatus} />,
    },
    {
      key: 'version',
      header: 'Applied version',
      sort: 'number',
      value: (host) => host.SettingsVersion ?? -1,
      render: (host) => {
        if (host.SettingsVersion === currentVersion) {
          return (
            <Badge tone="ok" icon="check-circle">
              {host.SettingsVersion}
            </Badge>
          );
        }
        if (host.SettingsVersion) {
          return (
            <Badge tone="warn" icon="clock">
              {host.SettingsVersion} (pending {currentVersion})
            </Badge>
          );
        }
        return (
          <Badge tone="neutral" icon="dash-circle">
            Not reported
          </Badge>
        );
      },
    },
    {
      key: 'applied',
      header: 'Applied',
      sort: 'date',
      value: (host) => host.SettingsAppliedDate,
      className: 'font-mono text-xs whitespace-nowrap',
      render: (host) => valueOrDash(host.SettingsAppliedDate),
    },
    {
      key: 'actions',
      header: 'Actions',
      headerClassName: 'text-right',
      className: 'text-right',
      render: (host) => (
        canApply ? (
          <Button
            size="sm"
            disabled={busy}
            onClick={() => onApply(host.Hostname)}
            aria-label={`Apply settings now to ${host.Hostname}`}
          >
            Apply now
          </Button>
        ) : null
      ),
    },
  ];

  return (
    <>
      <DataTable
        columns={columns}
        rows={hosts}
        rowKey={(host) => host.VMID}
        searchable
        searchPlaceholder="Search hosts…"
        noun="hosts"
        caption="Which hosts have applied the current settings version"
      />
      <p className="mt-2 text-xs text-muted">
        A host showing an older version has not reconciled yet. It converges on its own within one
        reconcile interval of coming back online, so no action is required.
      </p>
    </>
  );
}
