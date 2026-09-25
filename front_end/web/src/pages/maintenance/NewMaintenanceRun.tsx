import { useMemo, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';

import { Breadcrumbs } from '../../components/layout/Breadcrumbs';
import { PATCH_MODES } from '../../components/maintenance/MaintenanceStatus';
import { Badge, VmStatusBadge } from '../../components/ui/Badge';
import { Button, ButtonLink } from '../../components/ui/Button';
import { ErrorPanel, LoadingPanel, Notice, PageHeader } from '../../components/ui/Feedback';
import { Checkbox, Switch, TextAreaField, TextField } from '../../components/ui/Field';
import { GlassCard } from '../../components/ui/GlassCard';
import { useToast } from '../../components/ui/Toast';
import { useCreateMaintenanceRun, useFleetHealth, useMaintenanceRuns, useScalingPreview } from '../../hooks/useBroker';
import { errorMessage } from '../../lib/api';
import { classNames } from '../../lib/format';
import { PATCH_AGENT_VERSION, versionAtLeast } from '../../lib/version';
import type { HostHealth, MaintenancePatchMode } from '../../types/broker';

type HostFilter = 'all' | 'free' | 'in-use' | 'off';

const FILTERS: Array<{ key: HostFilter; label: string }> = [
  { key: 'all', label: 'All hosts' },
  { key: 'free', label: 'Not in use' },
  { key: 'in-use', label: 'In use' },
  { key: 'off', label: 'Powered off' },
];

function inUse(host: HostHealth) {
  return Boolean(host.Username) || host.CleanupPending || host.VmStatus === 'CheckedOut' || host.VmStatus === 'Released';
}

function matches(host: HostHealth, filter: HostFilter) {
  if (filter === 'off') return host.PowerState === 'Off';
  if (filter === 'in-use') return inUse(host);
  if (filter === 'free') return host.PowerState !== 'Off' && !inUse(host);
  return true;
}

interface FormState {
  name: string;
  patchMode: MaintenancePatchMode;
  batchSize: string;
  minReady: string;
  deadline: boolean;
  deadlineMinutes: string;
  warningMinutes: string;
  warningMessage: string;
  includePoweredOff: boolean;
  maxFailures: string;
  canaryCount: string;
}

const INITIAL: FormState = {
  name: '',
  patchMode: 'Security',
  batchSize: '1',
  minReady: '',
  deadline: false,
  deadlineMinutes: '60',
  warningMinutes: '15',
  warningMessage: '',
  includePoweredOff: false,
  maxFailures: '1',
  canaryCount: '0',
};

function wholeNumber(value: string, minimum: number, maximum: number): number | null {
  if (!/^\d+$/.test(value.trim())) return null;
  const number = Number(value);
  return number >= minimum && number <= maximum ? number : null;
}

/** The problems that stop the form being sent, keyed by field. */
export function validateRunForm(form: FormState, selected: number) {
  const problems: Partial<Record<keyof FormState | 'hosts', string>> = {};
  if (!selected) problems.hosts = 'Choose at least one host.';
  if (wholeNumber(form.batchSize, 1, 50) === null) problems.batchSize = 'Enter a whole number from 1 to 50.';
  if (form.minReady.trim() && wholeNumber(form.minReady, 0, 1000) === null) problems.minReady = 'Enter a whole number, or leave it blank.';
  if (form.deadline) {
    const deadline = wholeNumber(form.deadlineMinutes, 5, 1440);
    const warning = wholeNumber(form.warningMinutes, 1, 240);
    if (deadline === null) problems.deadlineMinutes = 'Enter 5 to 1440 minutes.';
    if (warning === null) problems.warningMinutes = 'Enter 1 to 240 minutes.';
    else if (deadline !== null && warning >= deadline) problems.warningMinutes = 'The warning must come before the deadline.';
  }
  if (wholeNumber(form.maxFailures, 1, 1000) === null) problems.maxFailures = 'Enter a whole number from 1 to 1000.';
  if (wholeNumber(form.canaryCount, 0, 50) === null) problems.canaryCount = 'Enter a whole number from 0 to 50.';
  if (form.warningMessage.trim().length > 500) problems.warningMessage = 'Keep the message to 500 characters.';
  return problems;
}

export function NewMaintenanceRun() {
  const navigate = useNavigate();
  const { showToast } = useToast();
  const health = useFleetHealth();
  const runs = useMaintenanceRuns();
  const preview = useScalingPreview();
  const create = useCreateMaintenanceRun();

  const [searchParams] = useSearchParams();
  const [form, setForm] = useState<FormState>(INITIAL);
  // The host list's "Start maintenance" arrives with its selection as ?hosts=a,b.
  const [selected, setSelected] = useState<Set<string>>(
    () => new Set((searchParams.get('hosts') ?? '').split(',').map((name) => name.trim()).filter(Boolean)),
  );
  const [filter, setFilter] = useState<HostFilter>('all');
  const [search, setSearch] = useState('');
  const [percent, setPercent] = useState('25');
  const [submitted, setSubmitted] = useState(false);

  const hosts = useMemo(
    () => [...(health.data?.Hosts ?? [])].sort((a, b) => a.Hostname.localeCompare(b.Hostname)),
    [health.data],
  );
  const shown = hosts.filter(
    (host) => matches(host, filter) && host.Hostname.toLowerCase().includes(search.trim().toLowerCase()),
  );
  const chosen = hosts.filter((host) => selected.has(host.Hostname));
  const problems = validateRunForm(form, chosen.length);
  const patching = form.patchMode !== 'RebootOnly';
  const tooOld = patching ? chosen.filter((host) => !versionAtLeast(host.AgentVersion, PATCH_AGENT_VERSION)) : [];
  const busy = chosen.filter(inUse);
  const off = chosen.filter((host) => host.PowerState === 'Off');
  const scalingMinimum = preview.data?.Phase.MinVMs;

  if (health.isPending || runs.isPending) {
    return <LoadingPanel label="Loading hosts" />;
  }
  if (health.error) {
    return <ErrorPanel message={errorMessage(health.error, 'Unable to retrieve the hosts.')} />;
  }
  if (runs.data?.Available === false) {
    return (
      <ErrorPanel
        message="Rolling maintenance needs the broker API and database from this release."
        action={<ButtonLink to="/vms/maintenance" icon="chevron-left">Back</ButtonLink>}
      />
    );
  }
  if (runs.data?.Active) {
    return (
      <ErrorPanel
        title="A run is already active"
        message={`Maintenance run ${runs.data.Active.RunID} is still ${runs.data.Active.Status.toLowerCase()}. Finish or cancel it before starting another.`}
        action={<ButtonLink to={`/vms/maintenance/${runs.data.Active.RunID}`} icon="eye">Open it</ButtonLink>}
      />
    );
  }

  function toggle(hostname: string, checked: boolean) {
    setSelected((current) => {
      const next = new Set(current);
      if (checked) next.add(hostname);
      else next.delete(hostname);
      return next;
    });
  }

  function setShown(checked: boolean) {
    setSelected((current) => {
      const next = new Set(current);
      for (const host of shown) {
        if (checked) next.add(host.Hostname);
        else next.delete(host.Hostname);
      }
      return next;
    });
  }

  function pickPercent() {
    const share = wholeNumber(percent, 1, 100);
    if (share === null || !shown.length) return;
    const count = Math.max(1, Math.ceil((shown.length * share) / 100));
    setSelected(new Set(shown.slice(0, count).map((host) => host.Hostname)));
  }

  async function submit() {
    setSubmitted(true);
    if (Object.keys(problems).length) return;
    try {
      const result = await create.mutateAsync({
        name: form.name.trim() || undefined,
        hostnames: chosen.map((host) => host.Hostname),
        patchMode: form.patchMode,
        batchSize: Number(form.batchSize),
        minReady: form.minReady.trim() ? Number(form.minReady) : null,
        signOutDeadlineMinutes: form.deadline ? Number(form.deadlineMinutes) : null,
        warningMinutes: Number(form.warningMinutes) || 15,
        warningMessage: form.deadline && form.warningMessage.trim() ? form.warningMessage.trim() : undefined,
        includePoweredOff: form.includePoweredOff,
        maxFailures: Number(form.maxFailures),
        canaryCount: Number(form.canaryCount),
      });
      showToast(result.message, 'success');
      navigate(`/vms/maintenance/${result.RunID}`);
    } catch (cause) {
      showToast(errorMessage(cause, 'Unable to start the maintenance run.'), 'danger');
    }
  }

  const allShownSelected = shown.length > 0 && shown.every((host) => selected.has(host.Hostname));
  const show = (field: keyof typeof problems) => (submitted ? problems[field] : undefined);

  return (
    <>
      <Breadcrumbs items={[{ label: 'Hosts', to: '/vms' }, { label: 'Maintenance', to: '/vms/maintenance' }, { label: 'New run' }]} />
      <PageHeader
        title="New maintenance run"
        subtitle="Choose the hosts and how to treat their users. Nothing happens until the next scheduled advance."
        icon="wrench"
        actions={<ButtonLink to="/vms/maintenance" size="sm" icon="chevron-left">Back</ButtonLink>}
      />

      <form
        noValidate
        onSubmit={(event) => {
          event.preventDefault();
          void submit();
        }}
      >
        <div className="grid grid-cols-1 gap-4 xl:grid-cols-5">
          <GlassCard className="overflow-hidden xl:col-span-3">
            <div className="border-b border-[var(--lb-hairline)] p-4">
              <h2 className="m-0 text-sm font-semibold">Hosts</h2>
              <p className="mt-1 mb-3 text-xs text-muted">
                Hosts are taken off first, then free ones, then those in use. {chosen.length} of {hosts.length} chosen.
              </p>
              <div className="flex flex-wrap items-end gap-2">
                <TextField
                  label="Find a host"
                  type="search"
                  fieldClassName="min-w-[14rem] flex-1"
                  value={search}
                  placeholder="Hostname"
                  onChange={(event) => setSearch(event.target.value)}
                />
                <div className="flex items-end gap-1.5">
                  <TextField
                    label="Pick a share"
                    fieldClassName="w-24"
                    inputMode="numeric"
                    value={percent}
                    onChange={(event) => setPercent(event.target.value)}
                  />
                  <span className="pb-2 text-sm text-muted">%</span>
                  <Button size="sm" onClick={pickPercent} disabled={!shown.length}>
                    Pick
                  </Button>
                </div>
              </div>
              <div role="group" aria-label="Show hosts" className="mt-3 flex flex-wrap gap-1.5">
                {FILTERS.map((option) => {
                  const active = option.key === filter;
                  return (
                    <button
                      key={option.key}
                      type="button"
                      aria-pressed={active}
                      onClick={() => setFilter(option.key)}
                      className={classNames(
                        'lb-btn px-2.5 py-1 text-xs',
                        active
                          ? 'border-transparent bg-[var(--lb-brand)] text-[var(--lb-on-brand)]'
                          : 'border-[var(--lb-hairline)] bg-[var(--lb-glass-bg-strong)] text-ink hover:border-[var(--lb-brand)]',
                      )}
                    >
                      {option.label}
                      <span className="tabular-nums opacity-80">{hosts.filter((host) => matches(host, option.key)).length}</span>
                    </button>
                  );
                })}
              </div>
            </div>

            <div className="max-h-[28rem] overflow-auto">
              <table className="lb-table">
                <caption className="sr-only">Hosts to include in the run</caption>
                <thead>
                  <tr>
                    <th scope="col" className="w-10">
                      <Checkbox
                        label={<span className="sr-only">Choose every host shown</span>}
                        checked={allShownSelected}
                        disabled={!shown.length}
                        onChange={setShown}
                      />
                    </th>
                    <th scope="col">Host</th>
                    <th scope="col">Status</th>
                    <th scope="col">User</th>
                    <th scope="col">Agent</th>
                  </tr>
                </thead>
                <tbody>
                  {shown.map((host) => (
                    <tr key={host.Hostname}>
                      <td>
                        <Checkbox
                          label={<span className="sr-only">Include {host.Hostname}</span>}
                          checked={selected.has(host.Hostname)}
                          onChange={(checked) => toggle(host.Hostname, checked)}
                        />
                      </td>
                      <td className="whitespace-nowrap">
                        {host.Hostname}
                        {host.PowerState === 'Off' ? <span className="block text-xs text-muted">Powered off</span> : null}
                      </td>
                      <td>
                        <VmStatusBadge value={host.VmStatus} />
                      </td>
                      <td className="text-sm">{host.Username ?? '—'}</td>
                      <td className="whitespace-nowrap">
                        <span className="font-mono text-xs">{host.AgentVersion ?? '—'}</span>
                        {patching && !versionAtLeast(host.AgentVersion, PATCH_AGENT_VERSION) ? (
                          <span className="ml-1.5">
                            <Badge tone="warn" icon="alert-triangle">Too old to patch</Badge>
                          </span>
                        ) : null}
                      </td>
                    </tr>
                  ))}
                  {!shown.length ? (
                    <tr>
                      <td colSpan={5} className="text-center text-sm text-muted">No host matches.</td>
                    </tr>
                  ) : null}
                </tbody>
              </table>
            </div>
            {show('hosts') ? <p className="m-0 px-4 py-2 text-xs text-[var(--lb-danger-fg)]">{show('hosts')}</p> : null}
          </GlassCard>

          <div className="flex flex-col gap-4 xl:col-span-2">
            <GlassCard className="p-5">
              <fieldset className="m-0 border-0 p-0">
                <legend className="mb-2 text-sm font-medium text-ink">What to do</legend>
                <div className="flex flex-col gap-2">
                  {(Object.keys(PATCH_MODES) as MaintenancePatchMode[]).map((mode) => (
                    <label key={mode} className="flex cursor-pointer items-start gap-2.5 text-sm">
                      <input
                        type="radio"
                        name="patch-mode"
                        className="mt-1"
                        checked={form.patchMode === mode}
                        onChange={() => setForm({ ...form, patchMode: mode })}
                      />
                      <span>
                        <span className="font-medium">{PATCH_MODES[mode].label}</span>
                        <span className="block text-xs text-muted">{PATCH_MODES[mode].help}</span>
                      </span>
                    </label>
                  ))}
                </div>
              </fieldset>

              <div className="mt-5 grid grid-cols-2 gap-4">
                <TextField
                  label="Hosts at a time"
                  inputMode="numeric"
                  value={form.batchSize}
                  error={show('batchSize')}
                  onChange={(event) => setForm({ ...form, batchSize: event.target.value })}
                />
                <TextField
                  label="Ready hosts to keep"
                  inputMode="numeric"
                  value={form.minReady}
                  placeholder={scalingMinimum !== undefined && scalingMinimum !== null ? `${scalingMinimum} (scaling)` : 'Scaling minimum'}
                  error={show('minReady')}
                  help="Blank follows the scaling minimum in force at each step."
                  onChange={(event) => setForm({ ...form, minReady: event.target.value })}
                />
              </div>

              <Switch
                className="mt-5"
                label="Sign users out after a deadline"
                help="Without a deadline, the run waits for each user to leave. With one, users are warned first."
                checked={form.deadline}
                onChange={(deadline) => setForm({ ...form, deadline })}
              />
              {form.deadline ? (
                <div className="mt-3 grid grid-cols-2 gap-4">
                  <TextField
                    label="Deadline (minutes)"
                    inputMode="numeric"
                    value={form.deadlineMinutes}
                    error={show('deadlineMinutes')}
                    help="Counted from when the host is taken."
                    onChange={(event) => setForm({ ...form, deadlineMinutes: event.target.value })}
                  />
                  <TextField
                    label="Warn before (minutes)"
                    inputMode="numeric"
                    value={form.warningMinutes}
                    error={show('warningMinutes')}
                    onChange={(event) => setForm({ ...form, warningMinutes: event.target.value })}
                  />
                  <TextAreaField
                    label="Warning message"
                    fieldClassName="col-span-2"
                    rows={3}
                    maxLength={500}
                    value={form.warningMessage}
                    placeholder={`This host restarts for maintenance in ${form.warningMinutes || 15} minutes. Save your work and sign out.`}
                    help="Leave blank for the standard message."
                    onChange={(event) => setForm({ ...form, warningMessage: event.target.value })}
                  />
                </div>
              ) : null}
            </GlassCard>

            <GlassCard className="p-5">
              <h2 className="mt-0 mb-3 text-xs font-semibold tracking-wider text-muted uppercase">Safety</h2>
              <Switch
                label="Include powered-off hosts"
                help="They are started, patched and stopped again. Otherwise they are skipped."
                checked={form.includePoweredOff}
                onChange={(includePoweredOff) => setForm({ ...form, includePoweredOff })}
              />
              <div className="mt-4 grid grid-cols-2 gap-4">
                <TextField
                  label="Stop after failures"
                  inputMode="numeric"
                  value={form.maxFailures}
                  error={show('maxFailures')}
                  onChange={(event) => setForm({ ...form, maxFailures: event.target.value })}
                />
                <TextField
                  label="Pause after first"
                  inputMode="numeric"
                  value={form.canaryCount}
                  error={show('canaryCount')}
                  help="0 for no canary pause."
                  onChange={(event) => setForm({ ...form, canaryCount: event.target.value })}
                />
              </div>
              <TextField
                label="Name (optional)"
                fieldClassName="mt-4"
                maxLength={100}
                value={form.name}
                placeholder="For example, October patching"
                onChange={(event) => setForm({ ...form, name: event.target.value })}
              />
            </GlassCard>

            {chosen.length ? (
              <GlassCard className="p-5" aria-live="polite">
                <h2 className="mt-0 mb-2 text-xs font-semibold tracking-wider text-muted uppercase">Before you start</h2>
                <ul className="m-0 flex list-none flex-col gap-1.5 p-0 text-sm">
                  <li>
                    {chosen.length} host{chosen.length === 1 ? '' : 's'}, {form.batchSize || '?'} at a time.
                  </li>
                  {busy.length ? (
                    <li>
                      {busy.length} in use: {form.deadline ? 'users are warned, then signed out at the deadline.' : 'the run waits for their users to leave.'}
                    </li>
                  ) : null}
                  {off.length ? (
                    <li>{off.length} powered off: {form.includePoweredOff ? 'started for patching, then stopped again.' : 'skipped.'}</li>
                  ) : null}
                </ul>
                {tooOld.length ? (
                  <Notice tone="warning" className="mt-3">
                    {tooOld.slice(0, 5).map((host) => host.Hostname).join(', ')}
                    {tooOld.length > 5 ? ` and ${tooOld.length - 5} more` : ''} run a host agent older than {PATCH_AGENT_VERSION} and
                    cannot be patched. Update them with deploy/Migrate-LinuxHostReleaseAgent.ps1 first, or choose Restart only.
                  </Notice>
                ) : null}
              </GlassCard>
            ) : null}

            <div className="flex flex-wrap gap-2">
              <Button type="submit" variant="primary" icon="check-circle" disabled={create.isPending}>
                {create.isPending ? 'Starting…' : 'Start the run'}
              </Button>
              <ButtonLink to="/vms/maintenance">Cancel</ButtonLink>
            </div>
          </div>
        </div>
      </form>
    </>
  );
}
