import { useState } from 'react';

import type { IconName } from '../../components/Icon';
import { Breadcrumbs } from '../../components/layout/Breadcrumbs';
import { Badge, PowerBadge } from '../../components/ui/Badge';
import type { Tone } from '../../components/ui/Badge';
import { Button, ButtonLink } from '../../components/ui/Button';
import { EmptyState, ErrorPanel, LoadingPanel, PageHeader, Spinner } from '../../components/ui/Feedback';
import { Checkbox } from '../../components/ui/Field';
import { GlassCard } from '../../components/ui/GlassCard';
import { useToast } from '../../components/ui/Toast';
import { useImportCandidates, useImportVms } from '../../hooks/useBroker';
import { errorMessage } from '../../lib/api';
import { valueOrDash } from '../../lib/format';
import type { ImportResult } from '../../types/broker';

const RESULTS: Record<ImportResult['Results'][number]['Result'], { tone: Tone; icon: IconName; label: string }> = {
  Imported: { tone: 'ok', icon: 'check-circle', label: 'Imported' },
  Exists: { tone: 'neutral', icon: 'dash-circle', label: 'Already registered' },
  NotTagged: { tone: 'danger', icon: 'x-circle', label: 'Not tagged' },
  Unresolved: { tone: 'warn', icon: 'alert-triangle', label: 'Not in DNS' },
};

function ImportResults({ result, onDismiss }: { result: ImportResult; onDismiss: () => void }) {
  return (
    <GlassCard className="mb-4 p-4" role="status" aria-label="Import results">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 className="m-0 text-sm font-semibold">{result.message}</h2>
          <p className="mt-1 mb-0 text-xs text-muted">
            Imported hosts start as unreachable and are offered to users once the reachability probe reaches them.
          </p>
        </div>
        <Button size="sm" variant="ghost" icon="x" onClick={onDismiss} aria-label="Dismiss the import results">
          Dismiss
        </Button>
      </div>
      <ul className="m-0 mt-3 flex list-none flex-col gap-1.5 p-0 text-sm">
        {result.Results.map((entry) => (
          <li key={entry.Hostname} className="flex flex-wrap items-center gap-2">
            <Badge tone={RESULTS[entry.Result]?.tone ?? 'neutral'} icon={RESULTS[entry.Result]?.icon ?? 'dash-circle'}>
              {RESULTS[entry.Result]?.label ?? entry.Result}
            </Badge>
            <span className="font-medium">{entry.Hostname}</span>
            <span className="text-xs text-muted">{entry.Problem ?? entry.message}</span>
          </li>
        ))}
      </ul>
    </GlassCard>
  );
}

/** Registers the Linux host VMs tagged for the broker, found in Azure rather than typed in. */
export function ImportHosts() {
  const { showToast } = useToast();
  const { data, isPending, isFetching, error, refetch } = useImportCandidates();
  const importVms = useImportVms();
  const [selected, setSelected] = useState<Set<string>>(() => new Set());
  const [result, setResult] = useState<ImportResult | null>(null);

  const candidates = data?.Candidates ?? [];
  const importable = candidates.filter((candidate) => candidate.Importable);
  const chosen = importable.filter((candidate) => selected.has(candidate.Hostname));
  const allChosen = importable.length > 0 && chosen.length === importable.length;

  function toggle(hostname: string, checked: boolean) {
    setSelected((current) => {
      const next = new Set(current);
      if (checked) next.add(hostname);
      else next.delete(hostname);
      return next;
    });
  }

  async function submit() {
    if (!chosen.length) return;
    try {
      const outcome = await importVms.mutateAsync(chosen.map((candidate) => candidate.Hostname));
      setResult(outcome);
      setSelected(new Set());
      showToast(outcome.message, outcome.Imported === outcome.Results.length ? 'success' : 'warning');
    } catch (cause) {
      showToast(errorMessage(cause, 'Unable to import the hosts.'), 'danger');
    }
  }

  const importLabel = importVms.isPending
    ? 'Importing…'
    : chosen.length
      ? `Import ${chosen.length} ${chosen.length === 1 ? 'host' : 'hosts'}`
      : 'Import';

  return (
    <>
      <Breadcrumbs items={[{ label: 'Hosts', to: '/vms' }, { label: 'Import from Azure' }]} />
      <PageHeader
        title="Import from Azure"
        subtitle={`Register the Linux VMs tagged ${data?.Tag ?? 'broker-role=linux-host'} that the broker does not know yet.`}
        icon="server"
        actions={
          <>
            {isFetching && !isPending ? <Spinner label="" /> : null}
            <Button size="sm" icon="refresh" disabled={isFetching} onClick={() => void refetch()}>
              Refresh
            </Button>
            <ButtonLink to="/vms/add" size="sm" icon="plus">
              Add a host manually
            </ButtonLink>
          </>
        }
      />

      {result ? <ImportResults result={result} onDismiss={() => setResult(null)} /> : null}

      {isPending ? <LoadingPanel label="Looking for Linux hosts in Azure" /> : null}

      {error ? (
        <ErrorPanel
          message={errorMessage(error, 'Unable to list the Linux hosts in Azure.')}
          action={
            <Button icon="refresh" onClick={() => void refetch()}>
              Try again
            </Button>
          }
        />
      ) : null}

      {data && !error && candidates.length === 0 ? (
        data.TaggedCount ? (
          <EmptyState
            title="Every tagged host is registered"
            message={`All ${data.TaggedCount} VMs tagged ${data.Tag} in ${data.ResourceGroup ?? 'the resource group'} are in the broker already.`}
            icon="check-circle"
            action={
              <ButtonLink to="/vms" icon="chevron-left">
                Back to the hosts
              </ButtonLink>
            }
          />
        ) : (
          <EmptyState
            title="No tagged Linux hosts found"
            message={`No VM in ${data.ResourceGroup ?? 'the resource group'} has the tag ${data.Tag}. Tag the Linux host VMs, then refresh.`}
            icon="server"
          />
        )
      ) : null}

      {candidates.length > 0 ? (
        <GlassCard className="overflow-hidden">
          <div className="flex flex-wrap items-center justify-between gap-3 border-b border-[var(--lb-hairline)] px-4 py-3">
            <p className="m-0 text-sm text-muted" aria-live="polite">
              {importable.length} of {candidates.length} can be imported · {chosen.length} chosen
            </p>
            <Button
              variant="primary"
              size="sm"
              icon="arrow-down"
              disabled={!chosen.length || importVms.isPending}
              onClick={() => void submit()}
            >
              {importLabel}
            </Button>
          </div>
          <div className="max-h-[70vh] overflow-auto">
            <table className="lb-table">
              <caption className="sr-only">Linux host VMs in Azure the broker does not know yet</caption>
              <thead>
                <tr>
                  <th scope="col" className="w-10">
                    <Checkbox
                      label={<span className="sr-only">Choose every host that can be imported</span>}
                      checked={allChosen}
                      disabled={!importable.length}
                      onChange={(checked) => setSelected(checked ? new Set(importable.map((c) => c.Hostname)) : new Set())}
                    />
                  </th>
                  <th scope="col">Hostname</th>
                  <th scope="col">IP address</th>
                  <th scope="col">Power</th>
                  <th scope="col">Import</th>
                </tr>
              </thead>
              <tbody>
                {candidates.map((candidate) => (
                  <tr key={candidate.Hostname}>
                    <td>
                      <Checkbox
                        label={<span className="sr-only">Import {candidate.Hostname}</span>}
                        checked={selected.has(candidate.Hostname)}
                        disabled={!candidate.Importable}
                        onChange={(checked) => toggle(candidate.Hostname, checked)}
                      />
                    </td>
                    <td className="whitespace-nowrap">
                      <span className="font-semibold">{candidate.Hostname}</span>
                      <span className="block font-mono text-xs text-muted">{candidate.Fqdn}</span>
                    </td>
                    <td className="font-mono text-xs">{valueOrDash(candidate.IPAddress)}</td>
                    <td>
                      <PowerBadge value={candidate.PowerState} />
                    </td>
                    <td className="min-w-64 max-w-md">
                      {candidate.Importable ? (
                        <Badge tone="ok" icon="check-circle">
                          Ready to import
                        </Badge>
                      ) : (
                        <span className="text-xs text-[var(--lb-warn-fg)]">{candidate.Problem}</span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </GlassCard>
      ) : null}

      <details className="mt-4 text-sm">
        <summary className="cursor-pointer text-muted">How import works</summary>
        <ul className="mt-2 mb-0 flex flex-col gap-1 pl-5 text-muted">
          <li>
            The broker lists the VMs in {data?.ResourceGroup ?? 'its resource group'} tagged {data?.Tag ?? 'broker-role=linux-host'}
            and leaves out those already registered.
          </li>
          <li>
            Each name must resolve as {data?.DomainName ? `hostname.${data.DomainName}` : 'hostname'} in DNS; that address is
            the one the broker records. Addresses are never typed in.
          </li>
          <li>Imported hosts start as unreachable with the power state Azure reports, and join the pool once the probe reaches them.</li>
        </ul>
      </details>
    </>
  );
}
