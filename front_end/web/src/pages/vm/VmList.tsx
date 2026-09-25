import { useEffect, useId, useState } from 'react';
import type { FormEvent, ReactNode } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';

import { Pagination, PerPageSelect } from '../../components/data/Pagination';
import {
  BulkResults,
  ColumnChooser,
  OPTIONAL_COLUMNS,
  SortHeader,
  STATUS_CHIPS,
  StatusChips,
  useHostColumns,
} from '../../components/hosts/HostListParts';
import type { OptionalColumn } from '../../components/hosts/HostListParts';
import { LifecycleExplainer } from '../../components/hosts/LifecycleExplainer';
import { Icon } from '../../components/Icon';
import { ActionMenu } from '../../components/ui/ActionMenu';
import type { ActionMenuItem } from '../../components/ui/ActionMenu';
import { Badge, NetworkBadge, PowerBadge, VmStatusBadge } from '../../components/ui/Badge';
import { Button, ButtonLink } from '../../components/ui/Button';
import { EmptyState, ErrorPanel, LoadingPanel, Notice, PageHeader, Spinner } from '../../components/ui/Feedback';
import { Checkbox, Switch } from '../../components/ui/Field';
import { GlassCard } from '../../components/ui/GlassCard';
import { RelativeTime } from '../../components/ui/RelativeTime';
import { useToast } from '../../components/ui/Toast';
import { useAutoRefresh } from '../../hooks/useAutoRefresh';
import { useBroadcastDialog } from '../../hooks/useBroadcastDialog';
import { useSyncPowerStates, useVmPage } from '../../hooks/useBroker';
import { BULK_ACTIONS, useBulkHostActions } from '../../hooks/useBulkHostActions';
import type { BulkAction } from '../../hooks/useBulkHostActions';
import { useHostRowActions } from '../../hooks/useHostRowActions';
import { useCan } from '../../hooks/useSession';
import { errorMessage } from '../../lib/api';
import { classNames, valueOrDash } from '../../lib/format';
import type { VmListItem, VmListSort, VmListStatus } from '../../types/broker';

export const HOSTS_PER_PAGE = 50;
const PER_PAGE_CHOICES = [25, 50, 100, 200];
const SEARCH_DELAY_MS = 300;
const STATUSES = STATUS_CHIPS.map((chip) => chip.key);
const SORTS: VmListSort[] = [
  'hostname', 'status', 'power', 'network', 'user', 'ip', 'os', 'agent', 'heartbeat', 'sessions', 'vmid', 'updated',
];
const OPERATOR_BULK: BulkAction[] = ['drain', 'undrain', 'start', 'stop', 'apply'];

export interface HostListView {
  page: number;
  perPage: number;
  q: string;
  status: VmListStatus;
  sort: VmListSort;
  dir: 'asc' | 'desc';
}

/** The list the address bar asks for; anything unrecognized falls back to the default. */
export function readHostListView(params: URLSearchParams): HostListView {
  const page = Number.parseInt(params.get('page') ?? '', 10);
  const perPage = Number.parseInt(params.get('per_page') ?? '', 10);
  const status = params.get('status') as VmListStatus | null;
  const sort = params.get('sort') as VmListSort | null;
  return {
    page: Number.isFinite(page) && page >= 1 ? page : 1,
    perPage: Number.isFinite(perPage) ? Math.min(200, Math.max(1, perPage)) : HOSTS_PER_PAGE,
    q: (params.get('q') ?? '').trim().slice(0, 128),
    status: status && STATUSES.includes(status) ? status : 'all',
    sort: sort && SORTS.includes(sort) ? sort : 'hostname',
    dir: params.get('dir') === 'desc' ? 'desc' : 'asc',
  };
}

/** What the portal asks the BFF for: every field, so the answer is always a page. */
export function hostListSearch(view: HostListView) {
  const params = new URLSearchParams({
    page: String(view.page),
    per_page: String(view.perPage),
    status: view.status,
    sort: view.sort,
    dir: view.dir,
  });
  if (view.q) params.set('q', view.q);
  return `?${params.toString()}`;
}

/** The address bar keeps only what differs from the default, so shared links stay short. */
function viewParams(view: HostListView) {
  const params = new URLSearchParams();
  if (view.q) params.set('q', view.q);
  if (view.status !== 'all') params.set('status', view.status);
  if (view.sort !== 'hostname') params.set('sort', view.sort);
  if (view.dir !== 'asc') params.set('dir', view.dir);
  if (view.perPage !== HOSTS_PER_PAGE) params.set('per_page', String(view.perPage));
  if (view.page !== 1) params.set('page', String(view.page));
  return params;
}

const SESSION_TEXT: Record<string, string> = {
  active: 'Signed in',
  disconnected: 'Disconnected',
  none: 'Not signed in',
};

function optionalCell(column: OptionalColumn, vm: VmListItem): ReactNode {
  switch (column) {
    case 'ip':
      return <span className="font-mono text-xs">{valueOrDash(vm.IPAddress)}</span>;
    case 'os':
      return vm.OsName ? [vm.OsName, vm.OsVersion].filter(Boolean).join(' ') : valueOrDash(null);
    case 'agent':
      return vm.AgentVersion ? (
        <span className="inline-flex flex-wrap items-center gap-1">
          <span className="font-mono text-xs">{vm.AgentVersion}</span>
          {vm.AgentOutdated ? <Badge tone="warn" icon="alert-triangle">Outdated</Badge> : null}
        </span>
      ) : (
        valueOrDash(null)
      );
    case 'settings':
      if (vm.SettingsCurrent === null || vm.SettingsCurrent === undefined) {
        return valueOrDash(vm.SettingsVersion === null || vm.SettingsVersion === undefined ? null : `v${vm.SettingsVersion}`);
      }
      return vm.SettingsCurrent ? (
        <Badge tone="ok" icon="check-circle">Current</Badge>
      ) : (
        <Badge tone="warn" icon="alert-triangle">
          {vm.SettingsVersion ? `v${vm.SettingsVersion} of v${vm.CurrentSettingsVersion}` : 'Never applied'}
        </Badge>
      );
    case 'heartbeat':
      return vm.LastHeartbeatUtc ? (
        <RelativeTime value={vm.LastHeartbeatUtc} className={vm.HeartbeatFresh ? undefined : 'text-[var(--lb-warn-fg)]'} />
      ) : (
        <span className="text-muted">Never</span>
      );
    case 'sessions':
      return vm.SessionCount === null || vm.SessionCount === undefined ? valueOrDash(null) : vm.SessionCount;
    case 'vmid':
      return <span className="font-mono text-xs text-muted">{vm.VMID}</span>;
    case 'updated':
      return <RelativeTime value={vm.LastUpdateDate} />;
  }
}

/** "a, b and c", or "a, b and 4 more" for a long list. */
function nameList(names: string[]) {
  if (names.length <= 3) {
    return names.length > 1 ? `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}` : (names[0] ?? '');
  }
  return `${names.slice(0, 2).join(', ')} and ${names.length - 2} more`;
}

export function VmList() {
  const can = useCan();
  const navigate = useNavigate();
  const { showToast } = useToast();
  const [searchParams, setSearchParams] = useSearchParams();
  const view = readHostListView(searchParams);
  const autoRefresh = useAutoRefresh(30);
  const { data, isPending, isFetching, error, refetch } = useVmPage(hostListSearch(view), autoRefresh.intervalMs);
  const { columns, setColumns } = useHostColumns();
  const rowActions = useHostRowActions();
  const broadcast = useBroadcastDialog();
  const syncPower = useSyncPowerStates();
  const [selected, setSelected] = useState<Map<number, VmListItem>>(() => new Map());
  const bulk = useBulkHostActions(() => setSelected(new Map()));
  const searchId = useId();

  const [text, setText] = useState(view.q);
  const [shownQ, setShownQ] = useState(view.q);
  if (shownQ !== view.q) {
    // The address bar changed by itself (back, or a link): show what it searches for now.
    setShownQ(view.q);
    if (text.trim() !== view.q) {
      setText(view.q);
    }
  }

  useEffect(() => {
    const next = text.trim().slice(0, 128);
    if (next === view.q) {
      return undefined;
    }
    const timer = window.setTimeout(() => {
      setSearchParams((current) => viewParams({ ...readHostListView(current), q: next, page: 1 }), { replace: true });
    }, SEARCH_DELAY_MS);
    return () => window.clearTimeout(timer);
  }, [text, view.q, setSearchParams]);

  function update(next: Partial<HostListView>) {
    setSearchParams((current) => viewParams({ ...readHostListView(current), ...next }), { replace: true });
  }

  function submitSearch(event: FormEvent) {
    event.preventDefault();
    update({ q: text.trim().slice(0, 128), page: 1 });
  }

  const items = data?.items ?? [];
  const onPage = new Map(items.map((vm) => [vm.VMID, vm]));
  const chosen = [...selected.values()].map((vm) => onPage.get(vm.VMID) ?? vm);
  const offPage = chosen.filter((vm) => !onPage.has(vm.VMID)).length;
  const allOnPage = items.length > 0 && items.every((vm) => selected.has(vm.VMID));
  const shownColumns = OPTIONAL_COLUMNS.filter((column) => columns.includes(column.key));
  const filtered = Boolean(view.q) || view.status !== 'all';
  const busy = bulk.running !== null;

  function toggle(vm: VmListItem, checked: boolean) {
    setSelected((current) => {
      const next = new Map(current);
      if (checked) next.set(vm.VMID, vm);
      else next.delete(vm.VMID);
      return next;
    });
  }

  function togglePage(checked: boolean) {
    setSelected((current) => {
      const next = new Map(current);
      for (const vm of items) {
        if (checked) next.set(vm.VMID, vm);
        else next.delete(vm.VMID);
      }
      return next;
    });
  }

  function sortBy(key: VmListSort) {
    update({ sort: key, dir: view.sort === key && view.dir === 'asc' ? 'desc' : 'asc', page: 1 });
  }

  async function syncPowerStates() {
    try {
      const result = await syncPower.mutateAsync();
      showToast(result.message, result.PowerSyncFailed ? 'warning' : 'success');
    } catch (cause) {
      showToast(errorMessage(cause, 'Unable to sync power states from Azure.'), 'danger');
    }
  }

  function sendMessage() {
    const names = chosen.map((vm) => vm.Hostname);
    broadcast.openBroadcast({
      title: `Message ${names.length} ${names.length === 1 ? 'host' : 'hosts'}`,
      hostnames: names,
      recipients: `The message is shown in every session on ${nameList(names)}. Hosts no one is signed in to are skipped.`,
    });
  }

  function startMaintenance() {
    navigate(`/vms/maintenance/new?hosts=${encodeURIComponent(chosen.map((vm) => vm.Hostname).join(','))}`);
  }

  const tools: ActionMenuItem[] = can.admin
    ? [
        { key: 'import', label: 'Import from Azure', icon: 'arrow-down', onSelect: () => navigate('/vms/import') },
        { key: 'add', label: 'Add a host manually', icon: 'plus', onSelect: () => navigate('/vms/add') },
        { key: 'test', label: 'Test brokering', icon: 'person', onSelect: () => navigate('/vms/checkout') },
      ]
    : [];

  const first = data && data.total ? (data.page - 1) * data.per_page + 1 : 0;
  const last = first ? first + items.length - 1 : 0;

  return (
    <>
      <PageHeader
        title="Hosts"
        subtitle="Linux hosts registered with the broker."
        icon="server"
        actions={
          <>
            <Switch
              label={<span className="text-xs whitespace-nowrap text-muted">Auto refresh {autoRefresh.status}</span>}
              checked={autoRefresh.enabled}
              onChange={autoRefresh.setEnabled}
            />
            {isFetching && !isPending ? <Spinner label="" /> : null}
            <Button size="sm" icon="refresh" onClick={() => void refetch()}>
              Refresh
            </Button>
            {can.operate ? (
              <Button size="sm" icon="power" disabled={syncPower.isPending} onClick={() => void syncPowerStates()}>
                {syncPower.isPending ? 'Syncing…' : 'Sync power state'}
              </Button>
            ) : null}
            {tools.length ? <ActionMenu label="Tools" text="Tools" items={tools} /> : null}
          </>
        }
      />

      <div className="mb-3 flex flex-wrap items-center justify-between gap-3">
        <form role="search" className="relative min-w-0 flex-1 sm:max-w-sm" onSubmit={submitSearch}>
          <label htmlFor={searchId} className="sr-only">
            Search hosts
          </label>
          <Icon
            name="search"
            size={15}
            className="pointer-events-none absolute top-1/2 left-2.5 -translate-y-1/2 text-subtle"
          />
          <input
            id={searchId}
            type="search"
            data-shortcut="search"
            className="lb-field pl-8 text-sm"
            placeholder="Search hostname, IP, user, status or OS…"
            autoComplete="off"
            spellCheck={false}
            value={text}
            onChange={(event) => setText(event.target.value)}
          />
        </form>
        <ColumnChooser columns={columns} onChange={setColumns} />
      </div>

      <div className="mb-3">
        <StatusChips counts={data?.counts} active={view.status} onChange={(status) => update({ status, page: 1 })} />
      </div>

      {data?.legacy ? (
        <Notice tone="info" className="mb-3">
          The broker API is older than this portal, so the portal pages the list itself and the heartbeat columns stay
          empty. Upgrade the API to fill them in.
        </Notice>
      ) : null}

      {bulk.lastRun ? <BulkResults run={bulk.lastRun} onDismiss={bulk.clearLastRun} /> : null}

      {can.operate && selected.size > 0 ? (
        <div role="region" aria-label="Selected hosts" className="lb-inset mb-3 flex flex-wrap items-center gap-2 p-2.5">
          <span className="text-sm font-medium" aria-live="polite">
            {selected.size} selected{offPage ? ` (${offPage} on other pages)` : ''}
          </span>
          <Button size="sm" variant="ghost" icon="x" onClick={() => setSelected(new Map())}>
            Clear
          </Button>
          <span aria-hidden="true" className="mx-1 hidden h-5 w-px bg-[var(--lb-hairline)] sm:block" />
          {OPERATOR_BULK.map((action) => (
            <Button key={action} size="sm" disabled={busy} onClick={() => bulk.request(action, chosen)}>
              {BULK_ACTIONS[action].label}
            </Button>
          ))}
          <Button size="sm" disabled={busy} onClick={sendMessage}>
            Send message
          </Button>
          {can.admin ? (
            <>
              <Button size="sm" icon="wrench" disabled={busy} onClick={startMaintenance}>
                Start maintenance
              </Button>
              <Button size="sm" variant="danger" icon="trash" disabled={busy} onClick={() => bulk.request('delete', chosen)}>
                Delete
              </Button>
            </>
          ) : null}
          {bulk.running ? <Spinner label={`${BULK_ACTIONS[bulk.running].label} in progress`} /> : null}
        </div>
      ) : null}

      {isPending ? <LoadingPanel label="Loading hosts" /> : null}

      {error && !data ? <ErrorPanel message={errorMessage(error, 'Unable to retrieve the hosts.')} /> : null}
      {error && data ? (
        <Notice tone="warning" className="mb-3">
          {errorMessage(error, 'Unable to refresh the hosts.')} Showing the list as it was.
        </Notice>
      ) : null}

      {data && data.total === 0 && !filtered ? (
        <EmptyState
          title="No hosts registered yet"
          message="Import the Linux VMs tagged for the broker, or add a host by hand."
          icon="server"
          action={
            can.admin ? (
              <div className="flex flex-wrap justify-center gap-2">
                <ButtonLink to="/vms/import" variant="primary" icon="arrow-down">
                  Import from Azure
                </ButtonLink>
                <ButtonLink to="/vms/add" icon="plus">
                  Add a host manually
                </ButtonLink>
              </div>
            ) : undefined
          }
        />
      ) : null}

      {data && items.length === 0 && (filtered || data.total > 0) ? (
        data.total > 0 ? (
          <EmptyState
            title={`Page ${view.page} is past the end of the list`}
            message={`${data.total} ${data.total === 1 ? 'host matches' : 'hosts match'}, on ${data.total_pages} ${data.total_pages === 1 ? 'page' : 'pages'}.`}
            icon="list"
            action={
              <Button icon="chevron-left" onClick={() => update({ page: data.total_pages })}>
                Go to the last page
              </Button>
            }
          />
        ) : (
          <EmptyState
            title="No host matches"
            message={view.q ? `Nothing matches “${view.q}” here.` : 'No host is in this state right now.'}
            icon="search"
            action={
              <Button
                icon="x"
                onClick={() => {
                  setText('');
                  update({ q: '', status: 'all', page: 1 });
                }}
              >
                Show all hosts
              </Button>
            }
          />
        )
      ) : null}

      {items.length > 0 ? (
        <>
          <GlassCard className="overflow-hidden">
            <div className="max-h-[70vh] overflow-auto">
              <table className="lb-table">
                <caption className="sr-only">Hosts registered with the broker</caption>
                <thead>
                  <tr>
                    {can.operate ? (
                      <th scope="col" className="w-10">
                        <Checkbox
                          label={<span className="sr-only">Select every host on this page</span>}
                          checked={allOnPage}
                          onChange={togglePage}
                        />
                      </th>
                    ) : null}
                    <SortHeader label="Hostname" sortKey="hostname" sort={view.sort} dir={view.dir} onSort={sortBy} />
                    <SortHeader label="Status" sortKey="status" sort={view.sort} dir={view.dir} onSort={sortBy} />
                    <SortHeader label="Power" sortKey="power" sort={view.sort} dir={view.dir} onSort={sortBy} />
                    <SortHeader label="Network" sortKey="network" sort={view.sort} dir={view.dir} onSort={sortBy} />
                    <SortHeader label="Assigned to" sortKey="user" sort={view.sort} dir={view.dir} onSort={sortBy} />
                    {shownColumns.map((column) => (
                      <SortHeader
                        key={column.key}
                        label={column.label}
                        sortKey={column.sort}
                        sort={view.sort}
                        dir={view.dir}
                        onSort={sortBy}
                      />
                    ))}
                    <th scope="col" className="text-right">
                      Actions
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {items.map((vm) => {
                    const isSelected = selected.has(vm.VMID);
                    const menu = rowActions.menuFor(vm);
                    return (
                      <tr key={vm.VMID} className={classNames(isSelected && 'bg-[var(--lb-hover)]')}>
                        {can.operate ? (
                          <td>
                            <Checkbox
                              label={<span className="sr-only">Select {vm.Hostname}</span>}
                              checked={isSelected}
                              onChange={(checked) => toggle(vm, checked)}
                            />
                          </td>
                        ) : null}
                        <td className="font-semibold whitespace-nowrap">
                          <Link to={`/vms/${vm.VMID}`} className="no-underline hover:underline">
                            {vm.Hostname}
                          </Link>
                        </td>
                        <td>
                          <span className="flex flex-wrap gap-1">
                            <VmStatusBadge value={vm.VmStatus} />
                            {vm.DrainRequested ? <Badge tone="warn" icon="box-arrow-right">Draining</Badge> : null}
                            {vm.CleanupPending ? <Badge tone="warn" icon="alert-triangle">Cleanup pending</Badge> : null}
                          </span>
                        </td>
                        <td>
                          <PowerBadge value={vm.PowerState} />
                        </td>
                        <td>
                          <NetworkBadge value={vm.NetworkStatus} />
                        </td>
                        <td className="whitespace-nowrap">
                          {vm.Username ? (
                            <>
                              <Link to={`/users/${encodeURIComponent(vm.Username)}`} className="no-underline hover:underline">
                                {vm.Username}
                              </Link>
                              {vm.SessionState && SESSION_TEXT[vm.SessionState] ? (
                                <span className="block text-xs text-muted">{SESSION_TEXT[vm.SessionState]}</span>
                              ) : null}
                            </>
                          ) : (
                            valueOrDash(null)
                          )}
                        </td>
                        {shownColumns.map((column) => (
                          <td key={column.key} className="whitespace-nowrap">
                            {optionalCell(column.key, vm)}
                          </td>
                        ))}
                        <td className="text-right">
                          {menu.length ? <ActionMenu label={`Host actions for ${vm.Hostname}`} text="Actions" items={menu} /> : null}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          </GlassCard>

          <div className="mt-4 flex flex-wrap items-center justify-between gap-3">
            <div className="flex items-center gap-3">
              <PerPageSelect
                perPage={view.perPage}
                options={PER_PAGE_CHOICES}
                onPerPageChange={(perPage) => update({ perPage, page: 1 })}
              />
              <span className="text-xs text-muted" aria-live="polite">
                {first === last ? `Host ${first}` : `Hosts ${first}–${last}`} of {data?.total}
              </span>
            </div>
            <Pagination page={view.page} totalPages={data?.total_pages ?? 0} onPageChange={(page) => update({ page })} />
          </div>
        </>
      ) : null}

      <LifecycleExplainer className="mt-4" />

      {rowActions.dialogs}
      {bulk.dialog}
      {broadcast.dialog}
    </>
  );
}

