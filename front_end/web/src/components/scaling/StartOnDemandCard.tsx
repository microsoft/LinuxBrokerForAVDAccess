import { useEffect, useState } from 'react';

import { Badge } from '../ui/Badge';
import { Button } from '../ui/Button';
import { Notice } from '../ui/Feedback';
import { Switch, TextField } from '../ui/Field';
import { GlassCard } from '../ui/GlassCard';
import { useToast } from '../ui/Toast';
import { useSetStartOnDemand } from '../../hooks/useBroker';
import { useConfirm } from '../../hooks/useConfirm';
import { errorMessage } from '../../lib/api';
import type { AvdHostScripts, ScalingPolicy } from '../../types/broker';

const DEFAULT_MAX_PENDING = 2;
const MAX_PENDING_LIMIT = 20;
const HOSTNAMES_SHOWN = 5;

function plural(count: number, one: string, many: string) {
  return `${count.toLocaleString()} ${count === 1 ? one : many}`;
}

function validMaxPending(text: string) {
  return /^\d{1,2}$/.test(text.trim()) && Number(text) >= 1 && Number(text) <= MAX_PENDING_LIMIT;
}

function listHostnames(hostnames: string[], total: number) {
  const shown = hostnames.slice(0, HOSTNAMES_SHOWN).join(', ');
  const more = total - Math.min(total, HOSTNAMES_SHOWN);
  return more > 0 ? `${shown} and ${more.toLocaleString()} more` : shown;
}

/** Which broker script the AVD session hosts run, since only a current one waits for a host. */
function AvdHostScriptSummary({ scripts }: { scripts: AvdHostScripts }) {
  return (
    <section aria-labelledby="avd-host-scripts">
      <h3 id="avd-host-scripts" className="m-0 text-sm font-semibold">
        AVD host scripts
      </h3>
      <p className="mt-1 mb-0 text-xs text-muted">
        The broker script on each AVD session host that asked for a Linux host in the last seven days. Version{' '}
        {scripts.CurrentVersion} or later waits while a host starts; an older script turns the user away.
      </p>

      {scripts.Seen === 0 ? (
        <p className="mt-3 mb-0 text-sm text-muted">No AVD session host has asked for a Linux host in the last seven days.</p>
      ) : (
        <>
          {scripts.Outdated > 0 ? (
            <Notice tone="warning" className="mt-3">
              {plural(scripts.Outdated, 'AVD host runs', 'AVD hosts run')} a script that cannot wait for a host to start
              {scripts.OutdatedHostnames.length ? `: ${listHostnames(scripts.OutdatedHostnames, scripts.Outdated)}` : ''}.
              Their users are turned away when no host is free. Update them with{' '}
              <code className="text-xs">deploy/Update-AvdHostBrokerScript.ps1</code>.
            </Notice>
          ) : null}
          <ul className="mt-3 mb-0 list-none space-y-2 p-0 text-sm">
            {scripts.Versions.map((version) => (
              <li key={version.ClientVersion} className="flex flex-wrap items-center justify-between gap-2">
                <span>
                  Version <span className="font-mono text-xs">{version.ClientVersion}</span>
                </span>
                <span className="flex items-center gap-2 tabular-nums">
                  {plural(version.AvdHosts, 'host', 'hosts')}
                  {version.Current ? (
                    <Badge tone="ok" icon="check-circle">Current</Badge>
                  ) : (
                    <Badge tone="info" icon="info-circle">Older</Badge>
                  )}
                </span>
              </li>
            ))}
            {scripts.Outdated > 0 ? (
              <li className="flex flex-wrap items-center justify-between gap-2">
                <span>No version reported</span>
                <span className="flex items-center gap-2 tabular-nums">
                  {plural(scripts.Outdated, 'host', 'hosts')}
                  <Badge tone="warn" icon="alert-triangle">Cannot wait</Badge>
                </span>
              </li>
            ) : null}
          </ul>
        </>
      )}
    </section>
  );
}

function StartOnDemandEditor({ policy }: { policy: ScalingPolicy }) {
  const setStartOnDemand = useSetStartOnDemand();
  const { showToast } = useToast();
  const { confirm, dialog } = useConfirm();
  const enabled = policy.StartOnDemandEnabled === true;
  const savedMaxPending = policy.MaxPendingStarts ?? DEFAULT_MAX_PENDING;
  const zeroMinimums = policy.ZeroMinimumCount ?? 0;
  const [on, setOn] = useState(enabled);
  const [maxPending, setMaxPending] = useState(String(savedMaxPending));

  useEffect(() => setOn(enabled), [enabled]);
  useEffect(() => setMaxPending(String(savedMaxPending)), [savedMaxPending]);

  const valid = validMaxPending(maxPending);
  const changed = on !== enabled || (valid && Number(maxPending) !== savedMaxPending);

  async function save() {
    try {
      const result = await setStartOnDemand.mutateAsync({
        startondemandenabled: on,
        maxpendingstarts: Number(maxPending),
      });
      showToast(result.message, 'success');
    } catch (cause) {
      showToast(errorMessage(cause, 'Unable to change start on demand.'), 'danger');
    }
  }

  function submit() {
    if (!valid || !changed) {
      return;
    }
    if (enabled && !on) {
      confirm({
        title: 'Turn off start on demand?',
        body:
          zeroMinimums > 0
            ? `${plural(zeroMinimums, 'rule or window keeps', 'rules and windows keep')} a minimum of 0 hosts. While start on demand is off the scaler keeps at least 1 host on for them, and a user who finds no free host is turned away instead of waiting.`
            : 'A user who finds no free host is turned away instead of waiting while a host starts.',
        confirmLabel: 'Turn it off',
        variant: 'warning',
        onConfirm: save,
      });
      return;
    }
    void save();
  }

  return (
    <>
      <form
        noValidate
        className="space-y-4"
        onSubmit={(event) => {
          event.preventDefault();
          submit();
        }}
      >
        <Switch
          label="Start a host when a user finds none free"
          help="The user's AVD session waits, up to ten minutes, while the broker starts a stopped host for them."
          checked={on}
          onChange={setOn}
        />
        <TextField
          label="Hosts that may start at once"
          help={`At most this many hosts start for waiting users at the same time, from 1 to ${MAX_PENDING_LIMIT}. Other waiting users share the hosts already starting.`}
          type="number"
          min={1}
          max={MAX_PENDING_LIMIT}
          step={1}
          inputMode="numeric"
          fieldClassName="max-w-xs"
          value={maxPending}
          error={valid ? undefined : `Enter a whole number from 1 to ${MAX_PENDING_LIMIT}.`}
          onChange={(event) => setMaxPending(event.target.value)}
        />
        <Button type="submit" size="sm" variant="primary" disabled={setStartOnDemand.isPending || !valid || !changed}>
          {setStartOnDemand.isPending ? 'Saving…' : 'Save start on demand'}
        </Button>
      </form>
      {dialog}
    </>
  );
}

/** Whether a user who finds no free host waits while one starts, and what the AVD hosts run. */
export function StartOnDemandCard({ policy, admin }: { policy: ScalingPolicy; admin: boolean }) {
  const supported = policy.StartOnDemandEnabled !== null && policy.StartOnDemandEnabled !== undefined;
  const enabled = policy.StartOnDemandEnabled === true;
  const zeroMinimums = policy.ZeroMinimumCount ?? 0;
  const scripts = policy.AvdHostScripts;

  return (
    <GlassCard className="mb-4 p-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="max-w-3xl">
          <h2 className="m-0 text-xs font-semibold tracking-wider text-muted uppercase">Start on demand</h2>
          <p className="mt-1 mb-0 text-xs text-muted">
            When no host is free, the broker starts a stopped one and the user waits for it instead of being turned
            away. It also lets a rule or window keep a minimum of 0 hosts, so idle hosts can stop.
          </p>
        </div>
        {supported ? (
          enabled ? (
            <Badge tone="ok" icon="power">On</Badge>
          ) : (
            <Badge tone="neutral" icon="dash-circle">Off</Badge>
          )
        ) : null}
      </div>

      {!supported ? (
        <p className="mt-3 mb-0 text-sm text-muted">
          This broker does not support start on demand yet. Upgrade the broker API and run the database migration to
          use it.
        </p>
      ) : (
        <>
          {!enabled && zeroMinimums > 0 ? (
            <Notice tone="warning" className="mt-3">
              {plural(zeroMinimums, 'rule or window keeps', 'rules and windows keep')} a minimum of 0 hosts, which needs
              start on demand. While it is off the scaler keeps at least 1 host on for them.
            </Notice>
          ) : null}
          <div className="mt-4 grid grid-cols-1 gap-6 lg:grid-cols-2">
            {admin ? (
              <StartOnDemandEditor policy={policy} />
            ) : (
              <p className="m-0 text-sm">
                {enabled
                  ? `On. Up to ${plural(policy.MaxPendingStarts ?? DEFAULT_MAX_PENDING, 'host starts', 'hosts start')} at once for waiting users.`
                  : 'Off. A user who finds no free host is turned away.'}
              </p>
            )}
            {scripts ? <AvdHostScriptSummary scripts={scripts} /> : null}
          </div>
        </>
      )}
    </GlassCard>
  );
}
