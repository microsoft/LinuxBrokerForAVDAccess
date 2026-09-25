import { useId, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';

import { DataTable } from '../../components/data/DataTable';
import type { Column } from '../../components/data/DataTable';
import { SESSION_STATES, SessionStateBadge, sessionDetail } from '../../components/sessions/SessionState';
import { ActionMenu } from '../../components/ui/ActionMenu';
import { Badge } from '../../components/ui/Badge';
import { EmptyState, ErrorPanel, LoadingPanel, PageHeader, Spinner } from '../../components/ui/Feedback';
import { Switch } from '../../components/ui/Field';
import { GlassCard } from '../../components/ui/GlassCard';
import { Icon } from '../../components/Icon';
import { useAutoRefresh } from '../../hooks/useAutoRefresh';
import { useSessions, useUserSearch } from '../../hooks/useBroker';
import { useSessionActions } from '../../hooks/useSessionActions';
import { errorMessage } from '../../lib/api';
import { classNames, formatAge, valueOrDash } from '../../lib/format';
import type { BrokerSession, SessionState } from '../../types/broker';

type Filter = 'all' | SessionState;

const FILTER_ORDER: SessionState[] = [
  'active', 'disconnected', 'released', 'connecting', 'not-connected', 'cleanup-pending', 'unmanaged', 'unknown',
];

/** The form checkout gives a sign-in name, so "John.Smith" finds "JohnSmith". */
function brokerUsername(value: string) {
  return value.replace(/[^A-Za-z0-9_]/g, '');
}

function FindUser() {
  const navigate = useNavigate();
  const [text, setText] = useState('');
  const query = brokerUsername(text);
  const { data, isFetching } = useUserSearch(query);
  const inputId = useId();
  const resultsId = useId();
  const users = query.length >= 2 ? (data?.Users ?? []) : [];

  return (
    <GlassCard className="mb-4 p-4">
      <form
        role="search"
        className="flex flex-wrap items-end gap-3"
        onSubmit={(event) => {
          event.preventDefault();
          const exact = users.find((user) => user.Username.toLowerCase() === query.toLowerCase());
          if (exact) {
            navigate(`/users/${encodeURIComponent(exact.Username)}`);
          } else if (users.length === 1) {
            navigate(`/users/${encodeURIComponent(users[0].Username)}`);
          }
        }}
      >
        <div className="flex min-w-0 flex-1 flex-col gap-1.5 sm:max-w-md">
          <label htmlFor={inputId} className="text-sm font-medium text-ink">
            Find a user
          </label>
          <div className="relative">
            <Icon
              name="search"
              size={15}
              className="pointer-events-none absolute top-1/2 left-2.5 -translate-y-1/2 text-subtle"
            />
            <input
              id={inputId}
              type="search"
              className="lb-field pl-8 text-sm"
              placeholder="Sign-in name, such as john.smith"
              autoComplete="off"
              spellCheck={false}
              value={text}
              aria-describedby={resultsId}
              onChange={(event) => setText(event.target.value)}
            />
          </div>
        </div>
        <p id={resultsId} className="mb-0 text-xs text-muted" aria-live="polite">
          {query.length < 2
            ? 'Finds anyone the broker has ever given a Linux host, signed in or not.'
            : isFetching && !data
              ? 'Searching…'
              : `${users.length} ${users.length === 1 ? 'user' : 'users'} found`}
        </p>
      </form>

      {users.length ? (
        <ul className="m-0 mt-3 flex list-none flex-col divide-y divide-[var(--lb-hairline)] p-0">
          {users.map((user) => (
            <li key={user.Username} className="flex flex-wrap items-center gap-x-3 gap-y-1 py-2 text-sm">
              <Link to={`/users/${encodeURIComponent(user.Username)}`} className="font-semibold no-underline hover:underline">
                {user.Username}
              </Link>
              <span className="text-xs text-muted">
                {user.CurrentHostname ? `On ${user.CurrentHostname}` : 'No host right now'}
              </span>
              {user.ProfileResetPending ? (
                <Badge tone="warn" icon="refresh">Profile reset pending</Badge>
              ) : null}
            </li>
          ))}
        </ul>
      ) : null}
    </GlassCard>
  );
}

export function SessionList() {
  const autoRefresh = useAutoRefresh(30);
  const { data, isPending, isFetching, error, refetch } = useSessions(autoRefresh.intervalMs);
  const actions = useSessionActions();
  const [searchParams, setSearchParams] = useSearchParams();

  const requested = (searchParams.get('state') ?? 'all') as Filter;
  const filter: Filter = requested === 'all' || requested in SESSION_STATES ? requested : 'all';

  function choose(next: Filter) {
    setSearchParams(
      (current) => {
        const params = new URLSearchParams(current);
        if (next === 'all') {
          params.delete('state');
        } else {
          params.set('state', next);
        }
        return params;
      },
      { replace: true },
    );
  }

  const sessions = data?.Sessions ?? [];
  const shown = filter === 'all' ? sessions : sessions.filter((session) => session.State === filter);

  const columns: Array<Column<BrokerSession>> = [
    {
      key: 'user',
      header: 'User',
      sort: 'text',
      value: (session) => session.Username,
      className: 'font-semibold whitespace-nowrap',
      render: (session) => (
        <Link to={`/users/${encodeURIComponent(session.Username)}`} className="no-underline hover:underline">
          {session.Username}
        </Link>
      ),
    },
    {
      key: 'host',
      header: 'Host',
      sort: 'text',
      value: (session) => session.Hostname,
      className: 'whitespace-nowrap',
      render: (session) =>
        session.VMID ? (
          <Link to={`/vms/${session.VMID}`} className="no-underline hover:underline">
            {session.Hostname}
          </Link>
        ) : (
          session.Hostname
        ),
    },
    {
      key: 'state',
      header: 'State',
      sort: 'text',
      value: (session) => SESSION_STATES[session.State]?.label ?? session.State,
      render: (session) => (
        <span className="flex flex-wrap gap-1">
          <SessionStateBadge state={session.State} />
          {session.DrainRequested ? <Badge tone="warn" icon="box-arrow-right">Host draining</Badge> : null}
        </span>
      ),
    },
    {
      key: 'detail',
      header: 'Details',
      value: (session) => sessionDetail(session),
      className: 'text-xs',
      render: (session) => sessionDetail(session),
    },
    {
      key: 'avd',
      header: 'AVD host',
      sort: 'text',
      value: (session) => session.AvdHost,
      className: 'text-xs whitespace-nowrap',
      render: (session) => valueOrDash(session.AvdHost),
    },
    {
      key: 'report',
      header: 'Host report',
      sort: 'number',
      value: (session) => session.HeartbeatAgeSeconds ?? Number.MAX_SAFE_INTEGER,
      className: 'text-xs whitespace-nowrap',
      render: (session) =>
        session.HeartbeatAgeSeconds === null ? (
          <span className="text-muted">Never</span>
        ) : (
          <span className={session.HeartbeatFresh ? undefined : 'text-muted'}>{formatAge(session.HeartbeatAgeSeconds)}</span>
        ),
    },
    {
      key: 'actions',
      header: 'Actions',
      headerClassName: 'text-right',
      className: 'text-right',
      render: (session) => {
        const items = actions.actionsFor(session);
        return items.length ? (
          <ActionMenu label={`Session actions for ${session.Username} on ${session.Hostname}`} text="Session" items={items} />
        ) : null;
      },
    },
  ];

  return (
    <>
      <PageHeader
        title="Sessions"
        subtitle="Who is on which Linux host, and why someone cannot connect."
        icon="person"
        actions={
          <>
            <Switch
              label={<span className="text-xs whitespace-nowrap text-muted">Auto refresh {autoRefresh.status}</span>}
              checked={autoRefresh.enabled}
              onChange={autoRefresh.setEnabled}
            />
            {isFetching && !isPending ? <Spinner label="" /> : null}
            <button
              type="button"
              className="lb-btn border-[var(--lb-hairline)] bg-[var(--lb-glass-bg-strong)] px-2.5 py-1.5 text-xs"
              onClick={() => void refetch()}
            >
              <Icon name="refresh" size={14} />
              Refresh
            </button>
          </>
        }
      />

      <FindUser />

      {isPending ? <LoadingPanel label="Loading sessions" /> : null}

      {error ? <ErrorPanel message={errorMessage(error, 'Unable to retrieve sessions.')} /> : null}

      {data && sessions.length === 0 ? (
        <EmptyState
          title="No one is on a Linux host"
          message="Sessions appear here when a user checks out a host from Azure Virtual Desktop, or when a host reports someone signed in."
          icon="person"
        />
      ) : null}

      {data && sessions.length > 0 ? (
        <>
          <div role="group" aria-label="Show sessions" className="mb-3 flex flex-wrap items-center gap-1.5">
            {(['all', ...FILTER_ORDER] as Filter[]).map((option) => {
              const count = option === 'all' ? data.Summary.Total : (data.Summary[option] ?? 0);
              const active = option === filter;
              return (
                <button
                  key={option}
                  type="button"
                  aria-pressed={active}
                  disabled={!active && count === 0 && option !== 'all'}
                  onClick={() => choose(option)}
                  className={classNames(
                    'lb-btn px-2.5 py-1 text-xs disabled:opacity-40',
                    active
                      ? 'border-transparent bg-[var(--lb-brand)] text-[var(--lb-on-brand)]'
                      : 'border-[var(--lb-hairline)] bg-[var(--lb-glass-bg-strong)] text-ink hover:border-[var(--lb-brand)]',
                  )}
                >
                  {option === 'all' ? 'All sessions' : SESSION_STATES[option].label}
                  <span className="tabular-nums opacity-80">{count}</span>
                </button>
              );
            })}
          </div>

          <DataTable
            columns={columns}
            rows={shown}
            rowKey={(session) => `${session.Hostname}/${session.Username}`}
            searchable
            searchPlaceholder="Filter by user, host or state…"
            noun="sessions"
            emptyMessage="No session is in this state."
            caption="Sessions on the brokered Linux hosts"
          />

          <details className="mt-4 text-sm">
            <summary className="cursor-pointer text-muted">What the states mean</summary>
            <dl className="mt-2 mb-0 grid grid-cols-1 gap-x-4 gap-y-2 md:grid-cols-[auto_1fr]">
              {FILTER_ORDER.map((state) => (
                <div key={state} className="contents">
                  <dt>
                    <SessionStateBadge state={state} />
                  </dt>
                  <dd className="m-0 text-muted">{SESSION_STATES[state].help}</dd>
                </div>
              ))}
            </dl>
          </details>
        </>
      ) : null}

      {actions.dialog}
    </>
  );
}
