import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';

import { App } from './App';
import { ToastProvider } from './components/ui/Toast';
import { setCsrfToken } from './lib/api';

/*
 * Integration cover for the whole client: session bootstrap, the app shell, the
 * query layer, and the pages mounting against real (stubbed) BFF responses.
 *
 * The unit tests check components in isolation and TypeScript checks the types,
 * but neither catches a page that throws on mount, a missing provider, or a hook
 * used incorrectly. This does.
 */

const SESSION = {
  authenticated: true,
  version: '0.114',
  csrfToken: 'test-csrf-token',
  user: {
    name: 'Test Operator',
    username: 'op@contoso.com',
    objectId: '0000-1111',
    tenantId: '2222-3333',
  },
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

const VMS = [
  {
    VMID: 1, Hostname: 'linux-host-01', IPAddress: '10.0.0.4', PowerState: 'On',
    NetworkStatus: 'Reachable', VmStatus: 'Available', Username: null, AvdHost: null,
    Description: 'Pool host', LastUpdateDate: '2026-08-01 10:00:00',
    CreateDate: '2026-07-01 10:00:00', SysStartTime: '2026-08-01 10:00:00', SysEndTime: null,
  },
  {
    VMID: 2, Hostname: 'linux-host-02', IPAddress: '10.0.0.5', PowerState: 'On',
    NetworkStatus: 'Reachable', VmStatus: 'CheckedOut', Username: 'alice@contoso.com',
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

let session: typeof SESSION | { authenticated: false; version: string; csrfToken: string; user: null } =
  SESSION;
const requests: string[] = [];

function stubFetch() {
  return vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input);
    requests.push(url);

    if (url.startsWith('/api/ui/session')) return jsonResponse(session);
    if (url.startsWith('/api/ui/dashboard')) return jsonResponse(DASHBOARD);
    if (url.startsWith('/api/ui/vms/history')) return jsonResponse(EMPTY_PAGE);
    if (url.startsWith('/api/ui/vms/')) return jsonResponse(VMS[0]);
    if (url.startsWith('/api/ui/vms')) return jsonResponse(VMS);
    if (url.startsWith('/api/ui/scaling/rules/history')) return jsonResponse(EMPTY_PAGE);
    if (url.startsWith('/api/ui/scaling/log')) return jsonResponse(EMPTY_PAGE);
    if (url.startsWith('/api/ui/scaling/rules')) return jsonResponse(RULES);
    if (url.startsWith('/api/ui/hosts/settings')) return jsonResponse(HOST_SETTINGS);

    return jsonResponse({ error: 'Unexpected request' }, 404);
  });
}

function renderApp(route: string) {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });

  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter initialEntries={[route]}>
        <ToastProvider>
          <App />
        </ToastProvider>
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

beforeEach(() => {
  session = SESSION;
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
    expect(screen.getByText('On, reachable and unassigned')).toBeInTheDocument();
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

  it('sends the session cookie on every BFF call', async () => {
    renderApp('/');
    await screen.findByText('33% of the pool in use');

    const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0];
    expect(call[1]).toMatchObject({ credentials: 'same-origin' });
  });

  it('shows the sign-in landing page when signed out', async () => {
    session = { authenticated: false, version: '0.114', csrfToken: 'anon-token', user: null };
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
    session = { authenticated: false, version: '0.114', csrfToken: 'anon-token', user: null };
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
    // The session query retries once before giving up, so this needs longer than
    // the default assertion timeout.
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
    ['/vms/checkout', 'Checkout a virtual machine'],
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
});
