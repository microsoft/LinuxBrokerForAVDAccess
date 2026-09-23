import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { act, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { QueryClientProvider } from '@tanstack/react-query';

import { App } from './App';
import { getCsrfToken, setCsrfToken } from './lib/api';
import { createQueryClient, queryKeys } from './lib/queryClient';
import { TEST_SESSION } from './test/render';
import type { SessionInfo, Vm } from './types/broker';

/*
 * Integration cover for the whole client: session bootstrap, the app shell, the
 * query layer, and the pages mounting against real (stubbed) BFF responses.
 *
 * The unit tests check components in isolation and TypeScript checks the types,
 * but neither catches a page that throws on mount, a missing provider, or a hook
 * used incorrectly. This does.
 */

const SESSION = TEST_SESSION;
const ANONYMOUS: SessionInfo = {
  ...SESSION, authenticated: false, subject: null, user: null,
  capabilities: { manage: false, connect: false }, csrfToken: 'anon-token',
};

const DASHBOARD = {
  stats: {
    total: 9, available: 4, checked_out: 3, maintenance: 1, released: 1, other: 0,
    unreachable: 2, powered_on: 7, powered_off: 2, ready: 3, attention: 3,
    utilization: 33,
    pct: { available: 44.44, checked_out: 33.33, released: 11.11, maintenance: 11.11, other: 0 },
  },
  recentActivity: [
    {
      ActivityID: 1, CheckTimestamp: '2026-08-19 10:00:00', CurrentRunningVMs: 5,
      CurrentInUseVMs: 4, ActionTaken: 'Scale Up', VMsPoweredOn: 2, VMsPoweredOff: 0,
      NewTotalVMs: 7, Outcome: 'Scaled up by 2 VMs', Notes: 'Utilization above threshold',
    },
  ],
  apiError: false,
};

const VMS: Vm[] = [
  {
    VMID: 1, Hostname: 'linux-host-01', IPAddress: '10.0.0.4', PowerState: 'On',
    NetworkStatus: 'Reachable', VmStatus: 'Available', Username: null, AvdHost: null,
    LeaseId: null, LeaseGeneration: 0,
    Description: 'Pool host', LastUpdateDate: '2026-08-01 10:00:00',
    CreateDate: '2026-07-01 10:00:00', SysStartTime: '2026-08-01 10:00:00', SysEndTime: null,
  },
  {
    VMID: 2, Hostname: 'linux-host-02', IPAddress: '10.0.0.5', PowerState: 'On',
    NetworkStatus: 'Reachable', VmStatus: 'CheckedOut', Username: 'alice@contoso.com',
    LeaseId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', LeaseGeneration: 7,
    AvdHost: 'avd-01', Description: '', LastUpdateDate: '2026-08-02 11:00:00',
    CreateDate: '2026-07-01 10:00:00', SysStartTime: '2026-08-02 11:00:00', SysEndTime: null,
  },
];

const RULES = [
  {
    RuleID: 1, MinVMs: 2, MaxVMs: 20, ScaleUpRatio: 80, ScaleUpIncrement: 2,
    ScaleDownRatio: 30, ScaleDownIncrement: 1,
  },
];

const HOST_SETTINGS = {
  settings: {
    GracePeriodSeconds: 1200, ReconcileIntervalSeconds: 60, WatcherDebounceSeconds: 10,
    WatcherSettleSeconds: 2, IdleTimeoutSeconds: 0, IdleWarningSeconds: 120,
    ScreenLockEnabled: false, DisableLockScreen: true, ScreenIdleDelaySeconds: 0,
    ScreenLockDelaySeconds: 0, ScreenLockSettingsLocked: true, SettingsVersion: 3,
  },
  hosts: VMS,
};

const EMPTY_PAGE = { items: [], page: 1, perPage: 10, total: 0, totalPages: 0 };

function jsonResponse(body: unknown, status = 200) {
  return {
    ok: status < 400,
    status,
    json: async () => body,
  } as Response;
}

let session: SessionInfo = SESSION;
let vms: Vm[] = VMS;
const requests: string[] = [];

function stubFetch() {
  return vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input);
    requests.push(url);

    if (url.startsWith('/api/ui/session')) return jsonResponse(session);
    if (url.startsWith('/api/ui/dashboard')) return jsonResponse(DASHBOARD);
    if (url.startsWith('/api/ui/vms/history')) return jsonResponse(EMPTY_PAGE);
    const vmMatch = url.match(/^\/api\/ui\/vms\/(\d+)$/);
    if (vmMatch) return jsonResponse(VMS.find((vm) => vm.VMID === Number(vmMatch[1])));
    if (url.startsWith('/api/ui/vms/')) return jsonResponse({});
    if (url.startsWith('/api/ui/vms')) return jsonResponse(vms);
    if (url.startsWith('/api/ui/scaling/rules/history')) return jsonResponse(EMPTY_PAGE);
    if (url.startsWith('/api/ui/scaling/log')) return jsonResponse(EMPTY_PAGE);
    if (url.startsWith('/api/ui/scaling/rules')) return jsonResponse(RULES);
    if (url.startsWith('/api/ui/hosts/settings')) return jsonResponse(HOST_SETTINGS);

    return jsonResponse({ error: 'Unexpected request' }, 404);
  });
}

function renderApp(route: string, queryClient = createQueryClient()) {
  const view = render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter initialEntries={[route]}>
        <App />
      </MemoryRouter>
    </QueryClientProvider>,
  );
  return { ...view, queryClient };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}

beforeEach(() => {
  session = SESSION;
  vms = VMS;
  requests.length = 0;
  setCsrfToken(null);
  vi.stubGlobal('fetch', stubFetch());
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('App', () => {
  it('shows a starting state before the session resolves', () => {
    renderApp('/');
    expect(screen.getByText('Starting the portal')).toBeInTheDocument();
  });

  it('renders the dashboard for a signed-in operator', async () => {
    renderApp('/');

    // The header renders immediately and the counters arrive with the query, so
    // the data assertions have to wait rather than read the loading state.
    expect(await screen.findByText('33% of the pool in use')).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'Pool overview', level: 1 })).toBeInTheDocument();
    expect(screen.getByText('Verified by the broker for checkout')).toBeInTheDocument();
    expect(screen.getByText('2 unreachable \u00b7 1 maintenance')).toBeInTheDocument();
    expect(screen.getByText('Pool composition')).toBeInTheDocument();
    // The activity panel rendered too, with its action badge.
    expect(screen.getByText('Scale up')).toBeInTheDocument();
  });

  it('caches the CSRF token from the session bootstrap', async () => {
    renderApp('/');
    await screen.findByText('33% of the pool in use');

    const { getCsrfToken } = await import('./lib/api');
    expect(getCsrfToken()).toBe('test-csrf-token');
  });

  it('keeps inventory visible without claiming checkout readiness when verification is unavailable', async () => {
    const baseFetch = stubFetch();
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => (
      String(input) === '/api/ui/dashboard'
        ? jsonResponse({ ...DASHBOARD, stats: { ...DASHBOARD.stats, ready: null } })
        : baseFetch(input)
    )));
    renderApp('/');
    expect(await screen.findByText('Checkout readiness unavailable.')).toBeInTheDocument();
    expect(screen.getByText('Awaiting broker verification')).toBeInTheDocument();
    expect(screen.getByText('Unavailable')).toBeInTheDocument();
    expect(screen.getByText('33% of the pool in use')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Refresh' })).toBeInTheDocument();
    expect(screen.queryByText('Verified by the broker for checkout')).not.toBeInTheDocument();
  });

  it('sends the session cookie on every BFF call', async () => {
    renderApp('/');
    await screen.findByText('33% of the pool in use');

    const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0];
    expect(call[1]).toMatchObject({ credentials: 'same-origin' });
  });

  it('shows the sign-in landing page when signed out', async () => {
    session = ANONYMOUS;
    renderApp('/');

    // The footer carries the same wording, so match the page heading specifically.
    expect(
      await screen.findByRole('heading', { name: 'Linux Broker Management Portal', level: 1 }),
    ).toBeInTheDocument();
    expect(screen.getAllByRole('link', { name: /Sign in/ })[0]).toHaveAttribute('href', '/login');
    // No data is fetched for an anonymous visitor beyond the bootstrap itself.
    expect(requests.every((url) => url.startsWith('/api/ui/session'))).toBe(true);
  });

  it('redirects a signed-out visitor away from a deep link', async () => {
    session = ANONYMOUS;
    renderApp('/vms');

    // Rendering a page frame that cannot load any data would be worse than the
    // landing page, so everything collapses to it while signed out.
    expect(
      await screen.findByRole('heading', { name: 'Linux Broker Management Portal', level: 1 }),
    ).toBeInTheDocument();
    expect(screen.queryByRole('heading', { name: 'Virtual machines' })).not.toBeInTheDocument();
  });

  it('reports a backend it cannot reach, and can retry', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonResponse({ error: 'boom' }, 500)),
    );

    renderApp('/');
    expect(
      await screen.findByText('The portal could not start', undefined, { timeout: 5000 }),
    ).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Try again' })).toBeInTheDocument();
  });

  // Every authenticated page, mounted for real. A page that throws on mount, uses
  // a hook incorrectly, or misses a provider fails here.
  it.each([
    ['/', 'Pool overview'],
    ['/profile', 'Profile'],
    ['/vms', 'Virtual machines'],
    ['/vms/add', 'Add virtual machine'],
    ['/vms/history', 'Virtual machine history'],
    ['/vms/1', 'linux-host-01'],
    ['/vms/1/update', 'Update linux-host-01'],
    ['/scaling/rules', 'Scaling rules'],
    ['/scaling/rules/create', 'Create scaling rule'],
    ['/scaling/rules/history', 'Scaling rule history'],
    ['/scaling/log', 'Scaling activity log'],
    ['/settings/hosts', 'Linux host settings'],
  ])('mounts %s', async (route, heading) => {
    renderApp(route);
    expect(await screen.findByRole('heading', { name: heading, level: 1 })).toBeInTheDocument();
  });

  it('renders the not-found state for an unknown client route', async () => {
    renderApp('/nope');
    expect(await screen.findByText('Page not found')).toBeInTheDocument();
  });

  it('lists VMs with lifecycle-appropriate row actions', async () => {
    renderApp('/vms');
    // Wait for the rows, not just the page header, which renders while loading.
    await screen.findByRole('button', { name: 'Delete linux-host-01' });

    // linux-host-01 is Available, so neither release nor return applies.
    expect(screen.queryByRole('button', { name: 'Release linux-host-01' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Return linux-host-01' })).not.toBeInTheDocument();

    // linux-host-02 is CheckedOut, so both do.
    expect(screen.getByRole('button', { name: 'Release linux-host-02' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Return linux-host-02' })).toBeInTheDocument();
  });

  it('confirms before sending a destructive action', async () => {
    renderApp('/vms');
    const deleteButton = await screen.findByRole('button', { name: 'Delete linux-host-01' });

    await userEvent.click(deleteButton);

    expect(await screen.findByRole('dialog')).toBeInTheDocument();
    expect(screen.getByText(/Permanently delete linux-host-01/)).toBeInTheDocument();
    // Nothing has been sent yet.
    expect(requests.some((url) => url.includes('/delete'))).toBe(false);

    await userEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument());
    expect(requests.some((url) => url.includes('/delete'))).toBe(false);
  });

  it('sends the CSRF header on a confirmed mutation', async () => {
    renderApp('/vms');
    await userEvent.click(await screen.findByRole('button', { name: 'Delete linux-host-01' }));

    const dialog = await screen.findByRole('dialog');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Delete' }));

    await waitFor(() => {
      const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls.find(
        ([url]) => String(url) === '/api/ui/vms/1/delete',
      );
      expect(call).toBeDefined();
      expect(call?.[1]?.headers).toMatchObject({ 'X-CSRFToken': 'test-csrf-token' });
    });
  });

  it('surfaces a BFF error message to the operator', async () => {
    renderApp('/vms');
    const deleteButton = await screen.findByRole('button', { name: 'Delete linux-host-01' });

    vi.stubGlobal(
      'fetch',
      vi.fn(async () => jsonResponse({ error: 'Unable to delete VM. Please try again later.' }, 502)),
    );

    await userEvent.click(deleteButton);
    const dialog = await screen.findByRole('dialog');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Delete' }));

    expect(
      await screen.findByText('Unable to delete VM. Please try again later.'),
    ).toBeInTheDocument();
  });

  it('does not mount management from a cached session while capability is unresolved', async () => {
    const pending = deferred<Response>();
    vi.stubGlobal('fetch', vi.fn(() => pending.promise));
    const queryClient = createQueryClient();
    queryClient.setQueryData(queryKeys.session, SESSION);
    queryClient.setQueryData(queryKeys.vms, VMS);
    renderApp('/vms', queryClient);

    expect(screen.getByText('Starting the portal')).toBeInTheDocument();
    expect(screen.queryByRole('link', { name: 'VM Management' })).not.toBeInTheDocument();
    expect(screen.queryByText('linux-host-01')).not.toBeInTheDocument();
    expect(globalThis.fetch).toHaveBeenCalledTimes(1);
    expect(vi.mocked(fetch).mock.calls[0][0]).toBe('/api/ui/session');

    await act(async () => pending.resolve(jsonResponse(ANONYMOUS)));
    expect(await screen.findByRole('heading', { name: 'Linux Broker Management Portal' })).toBeInTheDocument();
    expect(queryClient.getQueryData(queryKeys.vms)).toBeUndefined();
  });

  it.each([
    '/', '/profile', '/vms', '/vms/add', '/vms/checkout', '/vms/history', '/vms/2',
    '/vms/2/update', '/scaling/rules', '/scaling/rules/create', '/scaling/rules/1',
    '/scaling/rules/1/update', '/scaling/rules/history', '/scaling/log', '/settings/hosts',
  ])('denies an ordinary workspace user at %s without management queries or navigation', async (route) => {
    session = { ...SESSION, capabilities: { manage: false, connect: true } };
    renderApp(route);
    expect(await screen.findByRole('heading', { name: 'Administrator access required' })).toBeInTheDocument();
    expect(screen.getByText(/Your AVD access is unchanged/)).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Sign out or switch account' })).toHaveAttribute('href', '/logout');
    for (const name of ['Dashboard', 'VM Management', 'Scaling Management', 'Host Settings', 'Profile', 'Sign in']) {
      expect(screen.queryByRole('link', { name })).not.toBeInTheDocument();
    }
    expect(screen.queryByText('Checkout VM')).not.toBeInTheDocument();
    expect(requests).toEqual(['/api/ui/session']);
  });

  it('denies a scope-only user even when no workspace capability is present', async () => {
    session = { ...SESSION, capabilities: { manage: false, connect: false } };
    renderApp('/vms');
    expect(await screen.findByRole('heading', { name: 'Administrator access required' })).toBeInTheDocument();
    expect(requests).toEqual(['/api/ui/session']);
  });

  it.each([401, 403, 503])('keeps bootstrap HTTP %s distinct without redirects or business calls', async (status) => {
    vi.stubGlobal('fetch', vi.fn(async () => jsonResponse({
      error: status === 503 ? 'Administrator access could not be verified.' : 'Access rejected.',
      code: status === 503 ? 'authorization_unavailable' : undefined,
    }, status)));
    renderApp('/vms');

    if (status === 401) {
      expect(await screen.findByText(/Your session has expired/)).toBeInTheDocument();
      expect(screen.getByRole('link', { name: 'Sign in' })).toHaveAttribute('href', '/login');
    } else if (status === 403) {
      expect(await screen.findByRole('heading', { name: 'Administrator access required' })).toBeInTheDocument();
      expect(screen.queryByRole('link', { name: 'Sign in' })).not.toBeInTheDocument();
    } else {
      expect(await screen.findByText('Administrator access could not be verified.')).toBeInTheDocument();
      expect(screen.getByRole('button', { name: 'Try again' })).toBeInTheDocument();
    }
    expect(screen.queryByRole('link', { name: 'VM Management' })).not.toBeInTheDocument();
    expect(globalThis.fetch).toHaveBeenCalledTimes(1);
  });

  it('does not trust a bootstrap response that omits capabilities', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => jsonResponse({ ...SESSION, capabilities: undefined })));
    renderApp('/');
    expect(await screen.findByText(/Administrator access could not be verified/)).toBeInTheDocument();
    expect(screen.queryByRole('link', { name: 'VM Management' })).not.toBeInTheDocument();
    expect(globalThis.fetch).toHaveBeenCalledTimes(1);
  });

  it.each(['/vms/checkout', '/vms/checkout/update', '/vms/not-an-id'])(
    'rejects the legacy or invalid VM URL %s without a VM request',
    async (route) => {
      renderApp(route);
      expect(await screen.findByText('Page not found')).toBeInTheDocument();
      expect(requests).toEqual(['/api/ui/session']);
    },
  );

  it.each(['/', '/vms'])('has no checkout link for administrators at %s', async (route) => {
    renderApp(route);
    await screen.findByRole('link', { name: 'VM Management' });
    expect(screen.queryByRole('link', { name: /Checkout/ })).not.toBeInTheDocument();
  });

  it('clears query and mutation data before showing a different administrator', async () => {
    const { queryClient } = renderApp('/vms');
    await screen.findByRole('button', { name: 'Delete linux-host-01' });
    queryClient.setQueryData(queryKeys.vm(2), VMS[1]);
    await act(async () => {
      await queryClient.getMutationCache().build(queryClient, {
        mutationFn: async () => ({ message: 'old-administrator-response' }),
      }).execute(undefined);
    });

    session = {
      ...SESSION,
      subject: { ...SESSION.subject!, objectId: 'new-admin' },
      user: { ...SESSION.user!, objectId: 'new-admin', name: 'New Administrator' },
      csrfToken: 'new-admin-csrf',
    };
    vms = [{ ...VMS[0], VMID: 91, Hostname: 'new-admin-host' }];
    await act(async () => queryClient.refetchQueries({ queryKey: queryKeys.session }));
    expect(await screen.findByRole('button', { name: 'Delete new-admin-host' })).toBeInTheDocument();
    expect(screen.queryByText('linux-host-01')).not.toBeInTheDocument();
    expect(queryClient.getQueryData(queryKeys.vm(2))).toBeUndefined();
    expect(queryClient.getMutationCache().getAll()).toHaveLength(0);
    expect(getCsrfToken()).toBe('new-admin-csrf');
    const cached = JSON.stringify(queryClient.getQueryCache().getAll().map((query) => query.state.data));
    expect(cached).not.toContain('alice@contoso.com');
    expect(cached).not.toContain('linux-host-01');
  });

  it.each(['signed-out', 'forbidden'])('clears management data when a recheck is %s', async (state) => {
    const { queryClient } = renderApp('/vms');
    await screen.findByRole('button', { name: 'Delete linux-host-01' });
    session = state === 'signed-out' ? ANONYMOUS : {
      ...SESSION, capabilities: { manage: false, connect: true },
    };
    await act(async () => queryClient.refetchQueries({ queryKey: queryKeys.session }));
    expect(await screen.findByRole('heading', {
      name: state === 'signed-out' ? 'Linux Broker Management Portal' : 'Administrator access required',
    })).toBeInTheDocument();
    expect(queryClient.getQueryData(queryKeys.vms)).toBeUndefined();
    expect(screen.queryByRole('link', { name: 'VM Management' })).not.toBeInTheDocument();
  });

  it('preserves an administrator form while a periodic capability check is pending', async () => {
    const { queryClient } = renderApp('/vms/add');
    await screen.findByRole('heading', { name: 'Add virtual machine' });
    await userEvent.type(screen.getByLabelText('Hostname'), 'unsaved-host');
    const pending = deferred<Response>();
    vi.stubGlobal('fetch', vi.fn(() => pending.promise));
    let refreshing: Promise<void>;
    act(() => { refreshing = queryClient.refetchQueries({ queryKey: queryKeys.session }); });
    expect(await screen.findByText('Checking administrator access')).toBeInTheDocument();
    expect(screen.getByLabelText('Hostname')).not.toBeVisible();
    await act(async () => {
      pending.resolve(jsonResponse(SESSION));
      await refreshing;
    });
    await waitFor(() => expect(screen.getByLabelText('Hostname')).toBeVisible());
    expect(screen.getByLabelText('Hostname')).toHaveValue('unsaved-host');
    expect(globalThis.fetch).toHaveBeenCalledTimes(1);
  });

  it('pauses management refetches until an in-flight capability check completes', async () => {
    const { queryClient } = renderApp('/vms');
    await screen.findByRole('button', { name: 'Delete linux-host-01' });
    const pending = deferred<Response>();
    const baseFetch = stubFetch();
    vi.stubGlobal('fetch', vi.fn((input: RequestInfo | URL) => (
      String(input) === '/api/ui/session' ? pending.promise : baseFetch(input)
    )));
    let refreshing: Promise<void>;
    act(() => { refreshing = queryClient.refetchQueries({ queryKey: queryKeys.session }); });
    await screen.findByText('Checking administrator access');
    await act(async () => queryClient.invalidateQueries({ queryKey: queryKeys.vms }));
    expect(vi.mocked(fetch).mock.calls.map(([url]) => String(url))).toEqual(['/api/ui/session']);
    await act(async () => {
      pending.resolve(jsonResponse(SESSION));
      await refreshing;
    });
    expect(await screen.findByRole('button', { name: 'Delete linux-host-01' })).toBeInTheDocument();
  });

  it.each([true, false])('gates an open confirmation during capability revalidation (manage: %s)', async (manage) => {
    const { queryClient } = renderApp('/vms');
    await userEvent.click(await screen.findByRole('button', { name: 'Delete linux-host-01' }));
    await screen.findByRole('dialog');
    const pending = deferred<Response>();
    vi.stubGlobal('fetch', vi.fn(() => pending.promise));
    let refreshing: Promise<void>;
    act(() => { refreshing = queryClient.refetchQueries({ queryKey: queryKeys.session }); });
    await screen.findByText('Checking administrator access');
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    await act(async () => {
      pending.resolve(jsonResponse({ ...SESSION, capabilities: { manage, connect: false } }));
      await refreshing;
    });
    if (manage) {
      const dialog = await screen.findByRole('dialog');
      await userEvent.click(within(dialog).getByRole('button', { name: 'Cancel' }));
    } else {
      await screen.findByRole('heading', { name: 'Administrator access required' });
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    }
    expect(vi.mocked(fetch).mock.calls.map(([url]) => String(url))).toEqual(['/api/ui/session']);
  });

  it('clears the cache and CSRF token when signing out', async () => {
    const { queryClient } = renderApp('/vms');
    await screen.findByRole('button', { name: 'Delete linux-host-01' });
    const signOut = screen.getByRole('link', { name: 'Sign out' });
    signOut.addEventListener('click', (event) => event.preventDefault());
    await userEvent.click(signOut);
    expect(queryClient.getQueryCache().getAll()).toHaveLength(0);
    expect(queryClient.getMutationCache().getAll()).toHaveLength(0);
    expect(getCsrfToken()).toBeNull();
  });

  it.each([401, 403, 503])('blocks the portal and clears data after a business request returns %s', async (status) => {
    const { queryClient } = renderApp('/vms');
    await screen.findByRole('button', { name: 'Delete linux-host-01' });
    queryClient.setQueryData(queryKeys.hostSettings, HOST_SETTINGS);
    vi.stubGlobal('fetch', vi.fn(async () => jsonResponse({
      error: 'Administrator access could not be verified.',
      code: status === 503 ? 'authorization_unavailable' : undefined,
    }, status)));
    await act(async () => queryClient.refetchQueries({ queryKey: queryKeys.vms }));

    if (status === 401) {
      expect(await screen.findByText(/Your session has expired/)).toBeInTheDocument();
    } else if (status === 403) {
      expect(await screen.findByRole('heading', { name: 'Administrator access required' })).toBeInTheDocument();
    } else {
      expect(await screen.findByText('Administrator access could not be verified.')).toBeInTheDocument();
    }
    expect(queryClient.getQueryData(queryKeys.vms)).toBeUndefined();
    expect(queryClient.getQueryData(queryKeys.hostSettings)).toBeUndefined();
    expect(screen.queryByText('linux-host-01')).not.toBeInTheDocument();
    expect(screen.queryByRole('link', { name: 'VM Management' })).not.toBeInTheDocument();
    expect(getCsrfToken()).toBeNull();
  });

  it('also isolates data after a mutation loses authorization', async () => {
    const { queryClient } = renderApp('/vms');
    const deleteButton = await screen.findByRole('button', { name: 'Delete linux-host-01' });
    vi.stubGlobal('fetch', vi.fn(async () => jsonResponse({ error: 'Administrator access required.' }, 403)));
    await userEvent.click(deleteButton);
    const dialog = await screen.findByRole('dialog');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Delete' }));
    expect(await screen.findByRole('heading', { name: 'Administrator access required' })).toBeInTheDocument();
    expect(queryClient.getQueryData(queryKeys.vms)).toBeUndefined();
    expect(queryClient.getMutationCache().getAll()).toHaveLength(0);
    expect(screen.queryByText('linux-host-01')).not.toBeInTheDocument();
  });

  it('cannot repopulate management data from a late response after authorization loss', async () => {
    const late = deferred<Response>();
    const baseFetch = stubFetch();
    let holdVmList = false;
    vi.stubGlobal('fetch', vi.fn((input: RequestInfo | URL) => (
      holdVmList && String(input) === '/api/ui/vms' ? late.promise : baseFetch(input)
    )));
    const { queryClient } = renderApp('/vms');
    await screen.findByRole('button', { name: 'Delete linux-host-01' });
    holdVmList = true;
    let refreshing: Promise<void>;
    act(() => { refreshing = queryClient.refetchQueries({ queryKey: queryKeys.vms }); });

    session = { ...SESSION, capabilities: { manage: false, connect: true } };
    await act(async () => queryClient.refetchQueries({ queryKey: queryKeys.session }));
    await screen.findByRole('heading', { name: 'Administrator access required' });
    await act(async () => {
      late.resolve(jsonResponse(VMS));
      await refreshing;
    });
    expect(queryClient.getQueryData(queryKeys.vms)).toBeUndefined();
    expect(screen.queryByText('linux-host-01')).not.toBeInTheDocument();
  });

  it('ignores late authorization failures from a previous account mutation', async () => {
    const late = deferred<Response>();
    const baseFetch = stubFetch();
    vi.stubGlobal('fetch', vi.fn((input: RequestInfo | URL) => (
      String(input).endsWith('/delete') ? late.promise : baseFetch(input)
    )));
    const { queryClient } = renderApp('/vms');
    await userEvent.click(await screen.findByRole('button', { name: 'Delete linux-host-01' }));
    const dialog = await screen.findByRole('dialog');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Delete' }));
    const oldMutation = queryClient.getMutationCache().getAll()[0];
    expect(oldMutation.state.status).toBe('pending');

    session = {
      ...SESSION,
      subject: { ...SESSION.subject!, objectId: 'new-admin' },
      user: { ...SESSION.user!, objectId: 'new-admin', name: 'New Administrator' },
      csrfToken: 'new-admin-csrf',
    };
    vms = [{ ...VMS[0], VMID: 91, Hostname: 'new-admin-host' }];
    await act(async () => queryClient.refetchQueries({ queryKey: queryKeys.session }));
    await screen.findByRole('button', { name: 'Delete new-admin-host' });
    await act(async () => late.resolve(jsonResponse({ error: 'Old account authorization lost.' }, 403)));
    await waitFor(() => expect(oldMutation.state.status).toBe('error'));

    expect(screen.getByRole('button', { name: 'Delete new-admin-host' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'VM Management' })).toBeInTheDocument();
    expect(screen.queryByText('Old account authorization lost.')).not.toBeInTheDocument();
    expect(queryClient.getMutationCache().getAll()).toHaveLength(0);
    expect(getCsrfToken()).toBe('new-admin-csrf');
  });

  it.each([
    ['/vms', 'Release linux-host-02', 'Release', '/api/ui/vms/linux-host-02/release'],
    ['/vms', 'Return linux-host-02', 'Return', '/api/ui/vms/2/return'],
    ['/vms/2', 'Release', 'Release', '/api/ui/vms/linux-host-02/release'],
    ['/vms/2', 'Return', 'Return', '/api/ui/vms/2/return'],
  ])('%s sends current lease guards for %s', async (route, button, action, path) => {
    renderApp(route);
    await userEvent.click(await screen.findByRole('button', { name: button }));
    const dialog = await screen.findByRole('dialog');
    await userEvent.click(within(dialog).getByRole('button', { name: action }));
    await waitFor(() => {
      const call = vi.mocked(fetch).mock.calls.find(([url]) => String(url) === path);
      expect(call).toBeDefined();
      expect(JSON.parse(String(call?.[1]?.body))).toEqual({
        leaseId: VMS[1].LeaseId, leaseGeneration: VMS[1].LeaseGeneration,
      });
    });
  });

  it.each(['Release', 'Return'])('sends the maximum safe JSON generation exactly for %s', async (action) => {
    vms = [VMS[0], { ...VMS[1], LeaseGeneration: 9007199254740991 }];
    renderApp('/vms');
    await userEvent.click(await screen.findByRole('button', { name: `${action} linux-host-02` }));
    const dialog = await screen.findByRole('dialog');
    await userEvent.click(within(dialog).getByRole('button', { name: action }));
    await waitFor(() => {
      const call = vi.mocked(fetch).mock.calls.find(([url]) => String(url).endsWith(`/${action.toLowerCase()}`));
      expect(call?.[1]?.body).toBe(`{"leaseId":"${VMS[1].LeaseId}","leaseGeneration":9007199254740991}`);
    });
  });

  it.each([
    ['Release', 0], ['Return', 0],
    ['Release', 9007199254740992], ['Return', 9007199254740992],
    ['Release', Number('9223372036854775807')], ['Return', Number('9223372036854775807')],
  ] as const)('never sends %s with an invalid or unsafe generation %s', async (action, generation) => {
    vms = [VMS[0], { ...VMS[1], LeaseGeneration: generation }];
    const baseFetch = stubFetch();
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => (
      String(input) === '/api/ui/vms/2' ? jsonResponse(vms[1]) : baseFetch(input)
    )));
    renderApp('/vms');
    await userEvent.click(await screen.findByRole('button', { name: `${action} linux-host-02` }));
    const dialog = await screen.findByRole('dialog');
    await userEvent.click(within(dialog).getByRole('button', { name: action }));
    expect(await screen.findByText(/The current VM lease could not be verified/)).toBeInTheDocument();
    expect(vi.mocked(fetch).mock.calls.some(([, options]) => options?.method === 'POST')).toBe(false);
  });

  it('fetches the current VM rather than inventing missing lease guards', async () => {
    vms = [VMS[0], { ...VMS[1], LeaseId: null, LeaseGeneration: 0 }];
    renderApp('/vms');
    await userEvent.click(await screen.findByRole('button', { name: 'Return linux-host-02' }));
    const dialog = await screen.findByRole('dialog');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Return' }));
    await waitFor(() => {
      const call = vi.mocked(fetch).mock.calls.find(([url]) => String(url) === '/api/ui/vms/2/return');
      expect(JSON.parse(String(call?.[1]?.body))).toEqual({
        leaseId: VMS[1].LeaseId, leaseGeneration: 7,
      });
    });
    expect(requests.indexOf('/api/ui/vms/2')).toBeLessThan(requests.indexOf('/api/ui/vms/2/return'));
  });

  it('does not mutate a VM whose fresh record has no usable lease', async () => {
    vms = [VMS[0], { ...VMS[1], LeaseId: null }];
    const baseFetch = stubFetch();
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => (
      String(input) === '/api/ui/vms/2' ? jsonResponse(vms[1]) : baseFetch(input)
    )));
    renderApp('/vms');
    await userEvent.click(await screen.findByRole('button', { name: 'Return linux-host-02' }));
    const dialog = await screen.findByRole('dialog');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Return' }));
    expect(await screen.findByText(/The current VM lease could not be verified/)).toBeInTheDocument();
    expect(vi.mocked(fetch).mock.calls.some(([url]) => String(url).endsWith('/return'))).toBe(false);
  });

  it('explains a stale lease conflict, refreshes the assignment, and never retries the mutation', async () => {
    const baseFetch = stubFetch();
    const message = 'The VM lease changed. Refresh the VM and review its current assignment before trying again.';
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
      if (String(input) === '/api/ui/vms/2/return') {
        vms = [VMS[0], { ...VMS[1], Username: 'new-owner', LeaseGeneration: 8 }];
        return jsonResponse({ error: message }, 409);
      }
      return baseFetch(input);
    }));
    renderApp('/vms');
    await userEvent.click(await screen.findByRole('button', { name: 'Return linux-host-02' }));
    const dialog = await screen.findByRole('dialog');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Return' }));
    expect(await screen.findByText(message)).toBeInTheDocument();
    expect(await screen.findByText('new-owner')).toBeInTheDocument();
    expect(vi.mocked(fetch).mock.calls.filter(([url]) => String(url).endsWith('/return'))).toHaveLength(1);
  });

  it('creates only unassigned VM records without username or AVD host fields', async () => {
    renderApp('/vms/add');
    await screen.findByRole('heading', { name: 'Add virtual machine' });
    expect(screen.getByText(/Adding a VM creates an inventory record only/)).toHaveTextContent(
      'Azure Resource Manager (ARM) and enroll its host identity',
    );
    expect(screen.getByText(/Adding a VM creates an inventory record only/)).toHaveTextContent(
      'Setting Available, On, and Reachable here does not grant that trust.',
    );
    expect(screen.queryByLabelText(/Username/)).not.toBeInTheDocument();
    expect(screen.queryByLabelText(/AVD host/)).not.toBeInTheDocument();
    expect(screen.queryByRole('option', { name: 'Checked out' })).not.toBeInTheDocument();
    expect(screen.queryByRole('option', { name: 'Released' })).not.toBeInTheDocument();
    await userEvent.type(screen.getByLabelText('Hostname'), 'new-linux-host');
    await userEvent.type(screen.getByLabelText('IP address'), '10.0.0.10');
    await userEvent.click(screen.getByRole('button', { name: 'Add VM' }));
    await waitFor(() => {
      const call = vi.mocked(fetch).mock.calls.find(([url, options]) => (
        String(url) === '/api/ui/vms' && options?.method === 'POST'
      ));
      expect(JSON.parse(String(call?.[1]?.body))).toEqual({
        hostname: 'new-linux-host', ipaddress: '10.0.0.10', powerstate: 'On',
        networkstatus: 'Reachable', vmstatus: 'Available', description: '',
      });
    });
    expect(await screen.findByText(
      'VM added to inventory. Trusted deployment enrollment is required before checkout.',
    )).toBeInTheDocument();
  });

  it('explains trusted enrollment when the inventory is empty without removing Add VM', async () => {
    vms = [];
    renderApp('/vms');
    expect(await screen.findByText(
      'Add a Linux host to inventory, then complete trusted deployment enrollment before it can broker AVD sessions.',
    )).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Add your first VM' })).toHaveAttribute('href', '/vms/add');
  });

  it('offers only unassigned states when editing VM attributes', async () => {
    renderApp('/vms/1/update');
    await screen.findByRole('heading', { name: 'Update linux-host-01' });
    const status = screen.getByLabelText('VM status');
    expect(within(status).getAllByRole('option').map((option) => option.textContent)).toEqual([
      'Available', 'Maintenance',
    ]);
  });

  it('does not offer attribute editing for a leased VM', async () => {
    renderApp('/vms/2');
    await screen.findByRole('heading', { name: 'linux-host-02' });
    expect(screen.queryByRole('link', { name: 'Update attributes' })).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Return' })).toBeInTheDocument();
  });

  it('blocks direct attribute-edit URLs for leased VMs', async () => {
    renderApp('/vms/2/update');
    expect(await screen.findByText('VM attributes cannot be edited')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Save changes' })).not.toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Back to VM' })).toHaveAttribute('href', '/vms/2');
    expect(vi.mocked(fetch).mock.calls.some(([, options]) => options?.method === 'POST')).toBe(false);
  });
});
