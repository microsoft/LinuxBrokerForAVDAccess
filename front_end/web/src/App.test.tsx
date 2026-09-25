import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';

import { App } from './App';
import { ToastProvider } from './components/ui/Toast';
import { setCsrfToken } from './lib/api';
import type { DashboardStats, SessionInfo } from './types/broker';

/*
 * Integration cover for the whole client: session bootstrap, the app shell, the
 * query layer, and the pages mounting against real (stubbed) BFF responses.
 *
 * The unit tests check components in isolation and TypeScript checks the types,
 * but neither catches a page that throws on mount, a missing provider, or a hook
 * used incorrectly. This does.
 */

const SESSION: SessionInfo = {
  authenticated: true,
  version: '0.115',
  csrfToken: 'test-csrf-token',
  user: {
    name: 'Test Operator',
    username: 'op@contoso.com',
    objectId: '0000-1111',
    tenantId: '2222-3333',
  },
  roles: ['FullAccess'],
  permissions: { read: true, operate: true, admin: true },
  legacyAccess: false,
  permissionsUnavailable: false,
};

const DASHBOARD = {
  stats: {
    total: 9, available: 4, checked_out: 3, maintenance: 1, released: 1, other: 0,
    unreachable: 2, powered_on: 7, powered_off: 2, ready: 3, cleanup_pending: 0, attention: 3,
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
    CreateDate: '2026-07-01 10:00:00', SysStartTime: '2026-08-01 10:00:00', SysEndTime: null, CleanupPending: false, ReleasedDate: null, CleanupUsername: null, PowerStateChangedDate: null,
  },
  {
    VMID: 2, Hostname: 'linux-host-02', IPAddress: '10.0.0.5', PowerState: 'On',
    NetworkStatus: 'Reachable', VmStatus: 'CheckedOut', Username: 'alice@contoso.com',
    AvdHost: 'avd-01', Description: '', LastUpdateDate: '2026-08-02 11:00:00',
    CreateDate: '2026-07-01 10:00:00', SysStartTime: '2026-08-02 11:00:00', SysEndTime: null, CleanupPending: false, ReleasedDate: null, CleanupUsername: null, PowerStateChangedDate: null,
  },
];

const RULES = [
  {
    RuleID: 1, MinVMs: 2, MaxVMs: 20, ScaleUpRatio: 80, ScaleUpIncrement: 2,
    ScaleDownRatio: 30, ScaleDownIncrement: 1, StopMode: 'PowerOff', IsActive: true,
  },
];

const HOST_SETTINGS = {
  settings: {
    GracePeriodSeconds: 1200, ReconcileIntervalSeconds: 60, WatcherDebounceSeconds: 10,
    WatcherSettleSeconds: 2, IdleTimeoutSeconds: 0, IdleWarningSeconds: 120,
    ScreenLockEnabled: false, DisableLockScreen: true, ScreenIdleDelaySeconds: 0,
    ScreenLockDelaySeconds: 0, ScreenLockSettingsLocked: true, PreserveSessionsOnDisconnect: false, SettingsVersion: 3,
  },
  hosts: VMS,
};

const EMPTY_PAGE = { items: [], page: 1, perPage: 10, total: 0, totalPages: 0 };

const FLEET_HEALTH = {
  ExpectedAgentVersion: '1.0.0',
  CurrentSettingsVersion: 3,
  StaleAfterSeconds: 180,
  Summary: {
    Total: 2, PoweredOn: 2, Reporting: 1, Healthy: 1, Attention: 1, Off: 0, NoHeartbeat: 1,
    Stale: 0, XrdpDown: 0, NfsUnreachable: 0, LowDisk: 0, AgentOutdated: 0, SettingsDrift: 0,
  },
  Hosts: [
    {
      VMID: 1, Hostname: 'linux-host-01', PowerState: 'On', NetworkStatus: 'Reachable', VmStatus: 'Available',
      DrainRequested: false, CleanupPending: false, Username: null, Status: 'healthy', Flags: [], Reporting: true,
      LastHeartbeatUtc: '2026-09-24T12:00:00.000Z', HeartbeatAgeSeconds: 30, AgentVersion: '1.0.0',
      ScriptVersions: { 'release-session.sh': '1.0.0' }, AppliedSettingsVersion: 3, CurrentSettingsVersion: 3,
      OsId: 'rhel', OsVersion: '9.4', OsName: 'Red Hat Enterprise Linux 9.4', KernelVersion: '5.14.0',
      Desktop: 'gnome', XrdpVersion: '0.10.1', XrdpActive: true, NfsReachable: true, NfsMountCount: 1,
      LoadAverage: 0.25, CpuCount: 4, MemoryAvailableMb: 8000, MemoryTotalMb: 16000, RootDiskFreePct: 70,
      UptimeSeconds: 3600, SessionCount: 0, Sessions: [],
    },
    {
      VMID: 2, Hostname: 'linux-host-02', PowerState: 'On', NetworkStatus: 'Reachable', VmStatus: 'CheckedOut',
      DrainRequested: false, CleanupPending: false, Username: 'alice@contoso.com', Status: 'attention',
      Flags: ['no-heartbeat'], Reporting: false, LastHeartbeatUtc: null, HeartbeatAgeSeconds: null,
      AgentVersion: null, ScriptVersions: null, AppliedSettingsVersion: 3, CurrentSettingsVersion: 3,
      OsId: null, OsVersion: null, OsName: null, KernelVersion: null, Desktop: null, XrdpVersion: null,
      XrdpActive: null, NfsReachable: null, NfsMountCount: null, LoadAverage: null, CpuCount: null,
      MemoryAvailableMb: null, MemoryTotalMb: null, RootDiskFreePct: null, UptimeSeconds: null,
      SessionCount: null, Sessions: [],
    },
  ],
};

const AUDIT_PAGE = {
  items: [
    {
      AuditId: 7, OccurredAtUtc: '2026-09-24T12:00:00.000Z', ActorOid: 'oid-alice', ActorName: 'alice@contoso.com',
      ActorType: 'user', Action: 'vm.stop', TargetType: 'vm', TargetId: 'linux-host-02', Outcome: 'success',
      Detail: { endedAssignment: true, status: 202 }, CorrelationId: 'abc123',
    },
    {
      AuditId: 6, OccurredAtUtc: '2026-09-24T11:00:00.000Z', ActorOid: 'oid-task', ActorName: 'task-linuxbroker',
      ActorType: 'service', Action: 'scaling.power_on', TargetType: 'vm', TargetId: 'linux-host-01', Outcome: 'failure',
      Detail: null, CorrelationId: null,
    },
  ],
  page: 1, perPage: 25, total: 2, totalPages: 1,
};

const SETTINGS_HISTORY = [
  { ...HOST_SETTINGS.settings, SettingsVersion: 3, UpdatedBy: 'alice@contoso.com', ValidFromUtc: '2026-09-01T10:00:00Z', ValidToUtc: null, IsCurrent: true },
  { ...HOST_SETTINGS.settings, SettingsVersion: 2, GracePeriodSeconds: 600, UpdatedBy: null, ValidFromUtc: '2026-08-01T10:00:00Z', ValidToUtc: '2026-09-01T10:00:00Z', IsCurrent: false },
];

const SESSION_BASE = {
  AvdHost: 'avd-01', VmStatus: 'CheckedOut', PowerState: 'On', NetworkStatus: 'Reachable', DrainRequested: false,
  HasAssignment: true, CleanupPending: false, ReportedState: null, SessionStartUtc: null, DisconnectedForSeconds: null,
  IdleSeconds: null, AssignedForSeconds: 3600, LastCheckoutAgeSeconds: 3600, GraceRemainingSeconds: null,
  GracePeriodSeconds: 1200, HeartbeatAgeSeconds: 20, HeartbeatFresh: true,
};

const SESSIONS = {
  Sessions: [
    { ...SESSION_BASE, Hostname: 'linux-host-02', VMID: 2, Username: 'alice', State: 'active', ReportedState: 'active', IdleSeconds: 720 },
    { ...SESSION_BASE, Hostname: 'linux-host-04', VMID: 4, Username: 'bob', State: 'released', VmStatus: 'Released', GraceRemainingSeconds: 600 },
    { ...SESSION_BASE, Hostname: 'linux-host-01', VMID: 1, Username: 'carol', State: 'not-connected', LastCheckoutAgeSeconds: 5400 },
  ],
  Summary: {
    Total: 3, active: 1, disconnected: 0, released: 1, connecting: 0, 'not-connected': 1,
    'cleanup-pending': 0, unmanaged: 0, unknown: 0,
  },
};

let userDetails: Record<string, unknown> = {};

const SCHEDULE_BASE = {
  Enabled: true, DaysOfWeek: 31, Days: ['mon', 'tue', 'wed', 'thu', 'fri'], CrossesMidnight: false, MinVMs: 4, MaxVMs: 20,
  ScaleUpRatio: 70, ScaleUpIncrement: 2, ScaleDownRatio: 30, ScaleDownIncrement: 1, StopMode: null,
  UpdatedBy: 'op@contoso.com', UpdatedAtUtc: '2026-09-20T10:00:00Z',
};

const SCALING_POLICY = {
  TimeZone: 'UTC', UpdatedBy: null, UpdatedAtUtc: '2026-09-01T10:00:00Z', NowUtc: '2026-09-24T10:15:00Z',
  LocalTime: '2026-09-24T10:15:00',
  ActivePhase: { Source: 'Schedule', ScheduleID: 1, Name: 'Business hours', MinVMs: 4, MaxVMs: 20, ScaleUpRatio: 70, ScaleUpIncrement: 2, ScaleDownRatio: 30, ScaleDownIncrement: 1, StopMode: 'PowerOff' },
  DefaultRule: RULES[0],
  Schedules: [{ ...SCHEDULE_BASE, ScheduleID: 1, Name: 'Business hours', StartTime: '08:00', EndTime: '18:00' }],
  NextChange: { InMinutes: 465, AtLocal: 'Thursday 18:00', PhaseName: 'Default rule', ScheduleID: null },
  LastRun: null,
};

let scalingPolicy: typeof SCALING_POLICY = SCALING_POLICY;

const PREVIEW = {
  Action: 'PowerOn', Summary: 'Start 2 hosts (linux-host-05, linux-host-06).', Reason: 'Serviceable hosts are below the minimum.',
  RequestCount: 2, Candidates: ['linux-host-05', 'linux-host-06'],
  Phase: SCALING_POLICY.ActivePhase, Counts: { PoweredOn: 7, Serviceable: 2, InUse: 1, Draining: 0, Utilization: 50 },
  TimeZone: 'UTC', LocalTime: '2026-09-24T10:15:00', AtUtc: '2026-09-24T10:15:00Z',
};

const PROPOSED_PREVIEW = { ...PREVIEW, Action: 'None', Summary: 'No change.', Reason: 'No scaling threshold was crossed.', Candidates: [] };

const TIME_ZONES = [
  { Name: 'UTC', CurrentUtcOffset: '+00:00', IsCurrentlyDst: false },
  { Name: 'Eastern Standard Time', CurrentUtcOffset: '-04:00', IsCurrentlyDst: true },
];

function freshUserDetails() {
  return {
    Username: 'alice', Uid: 2001, FirstProvisionedDate: null, ProfileReset: null,
    Assignments: [{ VMID: 2, Hostname: 'linux-host-02', VmStatus: 'CheckedOut', PowerState: 'On', NetworkStatus: 'Reachable', AvdHost: 'avd-01', DrainRequested: false, CleanupPending: false, AssignedForSeconds: 3600, LastCheckoutAgeSeconds: 3600, ReleasedForSeconds: null }],
    Sessions: [SESSIONS.Sessions[0]],
    HostHistory: [{ VMID: 2, Hostname: 'linux-host-02', FirstSeenUtc: '2026-09-20T10:00:00Z', LastSeenUtc: '2026-09-24T12:00:00Z', Assignments: 3, IsCurrent: true }],
    RecentActivity: [
      { AuditId: 9, OccurredAtUtc: '2026-09-24T12:30:00.000Z', ActorOid: 'oid-op', ActorName: 'op@contoso.com', ActorType: 'user', Action: 'session.message', TargetType: 'user', TargetId: 'alice', Outcome: 'success', Detail: null, CorrelationId: null },
    ],
  };
}

function utilizationFixture(hours: 24 | 168) {
  const bucket = hours === 24 ? 15 : 60;
  const count = (hours * 60) / bucket;
  const end = Date.UTC(2026, 6, 13, 12, 0, 0);
  const Series = Array.from({ length: count }, (_, index) => {
    const idle = index < 4;
    return {
      BucketStartUtc: new Date(end - (count - index) * bucket * 60_000).toISOString().replace('.000Z', 'Z'),
      Runs: idle ? 0 : 3,
      PoweredOn: idle ? null : 4,
      InUse: idle ? null : 2 + (index % 2),
      Serviceable: idle ? null : 4,
      PeakInUse: idle ? null : 3,
      MinVMs: idle ? null : 2,
      MaxVMs: idle ? null : 6,
      Checkouts: index % 10 === 0 ? 2 : 0,
      Denied: index === 50 ? 2 : 0,
      Failed: 0,
    };
  });
  return {
    Available: true, Hours: hours, BucketMinutes: bucket, Series,
    Checkouts: {
      Total: 40, Assigned: 22, Reused: 16, NoneAvailable: 2, ProvisionFailed: 0, Errors: 0, P50Ms: 2100, P95Ms: 8400,
      DeniedLastHour: 0, DeniedPercent: 5, LastDeniedUtc: '2026-07-13T09:30:00Z', HostStarts: 3, StartP50Seconds: 95,
      StartP95Seconds: 180,
    },
  };
}

function maintenanceRun(overrides: Record<string, unknown> = {}) {
  return {
    RunID: 7, Name: 'October patching', Status: 'Active', EndStatus: null, PatchMode: 'Security', BatchSize: 1,
    MinReadyOverride: null, SignOutDeadlineMinutes: 60, WarningMinutes: 15, WarningMessage: null, IncludePoweredOff: false,
    MaxFailures: 1, CanaryCount: 0, CanaryReached: false, SurgeRequested: true,
    WaitReason: 'Waiting for a spare ready host: taking linux-host-03 now would leave fewer than 2 ready. Scaling is keeping one more host on.',
    StatusReason: null, CreatedBy: 'op@contoso.com', UpdatedBy: null, CreatedAtUtc: '2026-09-24T22:00:00.000Z',
    UpdatedAtUtc: null, EndedAtUtc: null, LastTickAtUtc: '2026-09-24T22:10:00.000Z', LastTickAgeSeconds: 40,
    Counts: { Total: 3, Pending: 1, InProgress: 1, Succeeded: 1, Failed: 0, Skipped: 0, Cancelled: 0 },
    MinReadyInForce: 2, PhaseMinVMs: 2, ReadyNow: 2,
    ...overrides,
  };
}

function maintenanceHost(overrides: Record<string, unknown>) {
  return {
    RunHostID: 1, VMID: 1, Hostname: 'linux-host-01', Position: 1, State: 'Pending', Attempts: 0, Detail: null,
    RebootRequired: null, AdmittedAtUtc: null, WarningSentAtUtc: null, SignOutRequestedAtUtc: null, PatchStartedAtUtc: null,
    PatchFinishedAtUtc: null, RestartRequestedAtUtc: null, VerifiedAtUtc: null, CompletedAtUtc: null, StepAgeSeconds: null,
    PowerState: 'On', NetworkStatus: 'Reachable', VmStatus: 'Maintenance', Username: null, AgentVersion: '1.1.0',
    HeartbeatAgeSeconds: 20, WasDrained: false, WasMaintenance: false, WasPoweredOff: false, Registered: true,
    DrainRequested: false, XrdpActive: true, AgentCanPatch: true,
    ...overrides,
  };
}

const MAINTENANCE_DETAILS = {
  Run: maintenanceRun(),
  Hosts: [
    maintenanceHost({ State: 'Succeeded', Detail: 'Patched and restarted.', CompletedAtUtc: '2026-09-24T22:08:00.000Z' }),
    maintenanceHost({ RunHostID: 2, VMID: 2, Hostname: 'linux-host-02', Position: 2, State: 'Draining', VmStatus: 'CheckedOut',
                      Detail: 'Waiting for alice to sign out.', Username: 'alice', StepAgeSeconds: 300 }),
    maintenanceHost({ RunHostID: 3, VMID: 3, Hostname: 'linux-host-03', Position: 3, State: 'Pending', VmStatus: 'Available',
                      AgentVersion: '1.0.0', AgentCanPatch: false }),
  ],
};

function maintenancePage(active: ReturnType<typeof maintenanceRun> | null = maintenanceRun()) {
  return {
    Available: true,
    Active: active,
    Runs: [
      ...(active ? [active] : []),
      maintenanceRun({ RunID: 6, Name: null, Status: 'Completed', EndStatus: 'Completed', SurgeRequested: false, WaitReason: null,
                       EndedAtUtc: '2026-09-20T23:00:00.000Z', Counts: { Total: 4, Pending: 0, InProgress: 0, Succeeded: 4, Failed: 0, Skipped: 0, Cancelled: 0 } }),
    ],
  };
}

const NO_TRENDS = { Available: false, Hours: 24 };
const NOTHING_NEEDS_ATTENTION = { Available: true, Items: [], Summary: { Total: 0 }, Incomplete: false };
const ATTENTION = {
  Available: true,
  Incomplete: false,
  Summary: { Total: 3, Critical: 1, Warning: 2, Info: 0 },
  Items: [
    { Kind: 'no-ready-hosts', Severity: 'critical' },
    { Kind: 'unreachable', Severity: 'warning', VMID: 2, Hostname: 'linux-host-02', AgeSeconds: 1500, Count: null },
    { Kind: 'health', Severity: 'warning', Flag: 'xrdp-down', Count: 1, Hostnames: ['linux-host-01'] },
  ],
};

function jsonResponse(body: unknown, status = 200) {
  return {
    ok: status < 400,
    status,
    json: async () => body,
  } as Response;
}

let session: typeof SESSION = SESSION;
let dashboard: Omit<typeof DASHBOARD, 'stats'> & { stats: DashboardStats; fleetHealth?: unknown } = DASHBOARD;
let trends: 'off' | 'on' = 'off';
let attention: unknown = NOTHING_NEEDS_ATTENTION;
let maintenance: unknown = maintenancePage();
const requests: string[] = [];

function stubFetch() {
  return vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    const method = init?.method ?? 'GET';
    requests.push(url);

    if (url === '/api/ui/session' || url.startsWith('/api/ui/session?')) return jsonResponse(session);
    if (url.startsWith('/api/ui/dashboard')) return jsonResponse(dashboard);
    if (url.startsWith('/api/ui/metrics/utilization')) {
      return jsonResponse(trends === 'off' ? NO_TRENDS : utilizationFixture(url.includes('hours=168') ? 168 : 24));
    }
    if (url.startsWith('/api/ui/metrics/attention')) return jsonResponse(attention);
    if (url === '/api/ui/maintenance/runs' && method === 'POST') {
      return jsonResponse({ RunID: 8, HostCount: 1, message: 'Maintenance run 8 started for 1 host.' }, 201);
    }
    const runAction = /^\/api\/ui\/maintenance\/runs\/(\d+)\/(pause|resume|cancel)$/.exec(url);
    if (runAction) {
      return jsonResponse({ Run: maintenanceRun(), Result: 'Updated', message: `Done: ${runAction[2]} run ${runAction[1]}.` });
    }
    if (/^\/api\/ui\/maintenance\/runs\/\d+$/.test(url)) return jsonResponse(MAINTENANCE_DETAILS);
    if (url.startsWith('/api/ui/maintenance/runs')) return jsonResponse(maintenance);
    if (url.startsWith('/api/ui/vms/history')) return jsonResponse(EMPTY_PAGE);
    const action = /^\/api\/ui\/vms\/(\d+)\/(start|stop|restart|drain|undrain)$/.exec(url);
    if (action) return jsonResponse({ VMID: Number(action[1]), Hostname: 'linux-host-02', message: `${action[2]} requested.` });
    if (url.startsWith('/api/ui/vms/')) return jsonResponse(VMS[0]);
    if (url.startsWith('/api/ui/vms')) return jsonResponse(VMS);
    if (url.startsWith('/api/ui/scaling/rules/history')) return jsonResponse(EMPTY_PAGE);
    if (url.startsWith('/api/ui/scaling/log')) return jsonResponse(EMPTY_PAGE);
    if (url.startsWith('/api/ui/scaling/rules')) return jsonResponse(RULES);
    if (url.startsWith('/api/ui/scaling/policy')) {
      return method === 'POST'
        ? jsonResponse({ TimeZone: 'Eastern Standard Time', message: 'Schedules are now read in Eastern Standard Time.' })
        : jsonResponse(scalingPolicy);
    }
    if (url.startsWith('/api/ui/scaling/preview')) return jsonResponse(method === 'POST' ? PROPOSED_PREVIEW : PREVIEW);
    if (url.startsWith('/api/ui/scaling/timezones')) return jsonResponse(TIME_ZONES);
    if (url.startsWith('/api/ui/scaling/schedules')) {
      return jsonResponse({ ScheduleID: 5, message: "Saved 'Evening'. It applies from the next scaling run." });
    }
    if (url.startsWith('/api/ui/hosts/health')) return jsonResponse(FLEET_HEALTH);
    if (url.startsWith('/api/ui/hosts/settings/history')) return jsonResponse(SETTINGS_HISTORY);
    if (url.startsWith('/api/ui/hosts/settings')) return jsonResponse(HOST_SETTINGS);
    if (url.startsWith('/api/ui/audit')) return jsonResponse(AUDIT_PAGE);
    if (/^\/api\/ui\/sessions\/[^/]+\/[^/]+\/signout$/.test(url)) {
      return jsonResponse({ Result: 'SignedOut', Released: true, Returned: false, message: 'Signed alice out of linux-host-02.' });
    }
    if (/^\/api\/ui\/sessions\/[^/]+\/[^/]+\/message$/.test(url)) {
      return jsonResponse({ Delivered: 1, Sessions: 1, message: 'Sent to alice on linux-host-02.' });
    }
    if (url === '/api/ui/sessions/broadcast') {
      return jsonResponse({ TargetCount: 2, Delivered: 2, Results: [{ Hostname: 'linux-host-02', Result: 'Delivered', Sessions: 1, Delivered: 1 }, { Hostname: 'linux-host-04', Result: 'Delivered', Sessions: 1, Delivered: 1 }], NotAttempted: [], UnknownHostnames: [], SkippedHostnames: [], message: 'Shown in 2 session(s) on 2 of 2 host(s).' });
    }
    if (url.startsWith('/api/ui/sessions')) return jsonResponse(SESSIONS);
    if (/^\/api\/ui\/users\/[^/]+\/reset-profile/.test(url)) {
      return jsonResponse({ Username: 'alice', message: 'alice gets a fresh profile at their next sign-in.' });
    }
    if (url.startsWith('/api/ui/users/')) return jsonResponse(userDetails);
    if (url.startsWith('/api/ui/users')) {
      return jsonResponse({
        Users: [{ Username: 'alice', Uid: 2001, ProfileResetPending: false, CurrentVMID: 2, CurrentHostname: 'linux-host-02', CurrentVmStatus: 'CheckedOut' }],
        Query: 'al',
      });
    }

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
  dashboard = DASHBOARD;
  trends = 'off';
  attention = NOTHING_NEEDS_ATTENTION;
  maintenance = maintenancePage();
  userDetails = freshUserDetails();
  scalingPolicy = SCALING_POLICY;
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
    expect(screen.getByText('2 unreachable \u00b7 1 maintenance \u00b7 0 cleanup pending')).toBeInTheDocument();
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
    session = { ...SESSION, authenticated: false, version: '0.115', csrfToken: 'anon-token', user: null, roles: [], permissions: { read: false, operate: false, admin: false }, legacyAccess: false, permissionsUnavailable: false };
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
    session = { ...SESSION, authenticated: false, version: '0.115', csrfToken: 'anon-token', user: null, roles: [], permissions: { read: false, operate: false, admin: false }, legacyAccess: false, permissionsUnavailable: false };
    renderApp('/vms');

    // Rendering a page frame that cannot load any data would be worse than the
    // landing page, so everything collapses to it while signed out.
    expect(
      await screen.findByRole('heading', { name: 'Linux Broker Management Portal', level: 1 }),
    ).toBeInTheDocument();
    expect(screen.queryByRole('heading', { name: 'Hosts' })).not.toBeInTheDocument();
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
    ['/vms', 'Hosts'],
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
    ['/vms/health', 'Fleet health'],
    ['/audit', 'Audit log'],
    ['/sessions', 'Sessions'],
    ['/users/alice', 'alice'],
    ['/scaling', 'Scaling policy'],
    ['/scaling/schedules/new', 'Add a scaling window'],
    ['/scaling/schedules/1', 'Edit Business hours'],
    ['/vms/maintenance', 'Rolling maintenance'],
    ['/vms/maintenance/7', 'October patching (run 7)'],
  ])('mounts %s', async (route, heading) => {
    renderApp(route);
    expect(await screen.findByRole('heading', { name: heading, level: 1 })).toBeInTheDocument();
  });



  it('shows the pages of the current section as tabs', async () => {
    renderApp('/vms/maintenance/7');
    const tabs = await screen.findByRole('navigation', { name: 'Hosts pages' });
    expect(within(tabs).getByRole('link', { name: 'Maintenance' })).toHaveAttribute('aria-current', 'page');
    expect(within(tabs).getByRole('link', { name: 'All hosts' })).not.toHaveAttribute('aria-current');
    expect(screen.getByRole('link', { name: 'Hosts' })).toHaveAttribute('aria-current', 'page');
  });

  it('moves between sections and searches from the keyboard', async () => {
    renderApp('/vms');
    await screen.findByRole('heading', { name: 'Hosts', level: 1 });

    await userEvent.keyboard('/');
    expect(screen.getByRole('searchbox')).toHaveFocus();
    await userEvent.keyboard('g');
    expect(screen.getByRole('searchbox')).toHaveValue('g');

    (document.activeElement as HTMLElement).blur();
    await userEvent.keyboard('gs');
    expect(await screen.findByRole('heading', { name: 'Sessions', level: 1 })).toBeInTheDocument();

    await userEvent.keyboard('?');
    const help = screen.getByRole('dialog', { name: 'Keyboard shortcuts' });
    expect(within(help).getByText('Go to Maintenance')).toBeInTheDocument();
    await userEvent.keyboard('{Escape}');
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
  });

  it('lets shortcuts and compact tables be turned off and on in the profile', async () => {
    renderApp('/profile');
    const shortcuts = await screen.findByRole('switch', { name: /Keyboard shortcuts/ });
    expect(shortcuts).toBeChecked();
    await userEvent.click(shortcuts);
    expect(window.localStorage.getItem('lb-shortcuts')).toBe('off');

    await userEvent.keyboard('?');
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();

    await userEvent.click(screen.getByRole('switch', { name: /Compact tables/ }));
    expect(document.documentElement).toHaveAttribute('data-density', 'compact');
    expect(window.localStorage.getItem('lb-density')).toBe('compact');
  });

  it('shows no-access page for authenticated users without read permission', async () => {
    session = { ...SESSION, roles: [], permissions: { read: false, operate: false, admin: false } };
    renderApp('/');

    expect(await screen.findByText('No access')).toBeInTheDocument();
    expect(screen.getAllByRole('link', { name: 'Sign out' }).some((link) => link.getAttribute('href') === '/logout')).toBe(true);
    expect(requests.every((url) => url.startsWith('/api/ui/session'))).toBe(true);
  });

  it('shows a retry panel when permissions are unavailable', async () => {
    session = { ...SESSION, permissionsUnavailable: true, permissions: { read: false, operate: false, admin: false } };
    renderApp('/');

    expect(await screen.findByText('Permissions unavailable')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Retry' })).toBeInTheDocument();
  });

  it('shows read-only and legacy access banners', async () => {
    session = { ...SESSION, legacyAccess: true, roles: ['Reader'], permissions: { read: true, operate: false, admin: false } };
    renderApp('/profile');

    expect(await screen.findByText(/Read-only access/)).toBeInTheDocument();
    expect(screen.getByText(/legacy scope setting/)).toBeInTheDocument();
  });

  it('gates VM actions for reader and operator roles', async () => {
    session = { ...SESSION, roles: ['Reader'], permissions: { read: true, operate: false, admin: false } };
    const { unmount } = renderApp('/vms');
    await screen.findByRole('heading', { name: 'Hosts' });
    expect(screen.queryByRole('button', { name: 'Release linux-host-02' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Delete linux-host-01' })).not.toBeInTheDocument();
    expect(screen.queryByRole('link', { name: 'Add VM' })).not.toBeInTheDocument();
    unmount();

    session = { ...SESSION, roles: ['Operator'], permissions: { read: true, operate: true, admin: false } };
    renderApp('/vms');
    expect(await screen.findByRole('button', { name: 'Release linux-host-02' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Delete linux-host-01' })).not.toBeInTheDocument();
    expect(screen.queryByRole('link', { name: 'Add VM' })).not.toBeInTheDocument();
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

  it('stops a host in use only after the administrator types its hostname', async () => {
    renderApp('/vms');
    await userEvent.click(await screen.findByRole('button', { name: 'Host actions for linux-host-02' }));
    await userEvent.click(screen.getByRole('menuitem', { name: 'Stop' }));

    const dialog = await screen.findByRole('dialog');
    expect(within(dialog).getByText(/alice@contoso.com is signed in to linux-host-02/)).toBeInTheDocument();
    const stop = within(dialog).getByRole('button', { name: 'Stop' });
    expect(stop).toBeDisabled();

    await userEvent.type(within(dialog).getByLabelText(/to confirm/), 'linux-host-02');
    await userEvent.click(stop);

    await waitFor(() => {
      const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls.find(
        ([url]) => String(url) === '/api/ui/vms/2/stop',
      );
      expect(call).toBeDefined();
      expect(JSON.parse(String(call?.[1]?.body))).toEqual({ confirm: 'linux-host-02' });
    });
    expect(await screen.findByText('stop requested.')).toBeInTheDocument();
  });

  it('lets an operator drain a host in use but not stop it', async () => {
    session = { ...SESSION, roles: ['Operator'], permissions: { read: true, operate: true, admin: false } };
    renderApp('/vms');

    await userEvent.click(await screen.findByRole('button', { name: 'Host actions for linux-host-02' }));
    const inUse = screen.getAllByRole('menuitem').map((item) => item.textContent);
    expect(inUse).toEqual(['Drain']);
    await userEvent.keyboard('{Escape}');

    await userEvent.click(screen.getByRole('button', { name: 'Host actions for linux-host-01' }));
    expect(screen.getAllByRole('menuitem').map((item) => item.textContent)).toEqual([
      'Restart', 'Stop', 'Stop and deallocate', 'Drain',
    ]);

    await userEvent.click(screen.getByRole('menuitem', { name: 'Drain' }));
    const dialog = await screen.findByRole('dialog');
    expect(within(dialog).getByText(/It has no user, so it moves to maintenance now/)).toBeInTheDocument();
    await userEvent.click(within(dialog).getByRole('button', { name: 'Drain' }));
    await waitFor(() => expect(requests).toContain('/api/ui/vms/1/drain'));
  });

  it('hides host actions from readers', async () => {
    session = { ...SESSION, roles: ['Reader'], permissions: { read: true, operate: false, admin: false } };
    renderApp('/vms');
    await screen.findByRole('link', { name: 'linux-host-01' });
    expect(screen.queryByRole('button', { name: /Host actions for/ })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Sync power state' })).not.toBeInTheDocument();
  });

  it('summarises fleet health on the dashboard when the broker reports it', async () => {
    dashboard = { ...DASHBOARD, fleetHealth: { ...FLEET_HEALTH.Summary, ExpectedAgentVersion: '1.0.0' } };
    renderApp('/');

    expect(await screen.findByText('1 of 2 powered-on hosts reporting')).toBeInTheDocument();
    expect(screen.getByRole('link', { name: '1 no heartbeat' })).toHaveAttribute('href', '/vms/health?show=no-heartbeat');
  });

  it('charts capacity and checkout health over a day or a week', async () => {
    trends = 'on';
    renderApp('/');

    const chart = await screen.findByRole('img', { name: /^Capacity over the last 24 hours\./ });
    expect(chart).toHaveAccessibleName(
      'Capacity over the last 24 hours. At most 3 hosts were in use at once. About 4 hosts could take a user. The scaling maximum was 6. 2 checkouts found no host.',
    );
    const health = screen.getByRole('heading', { name: 'Checkout health' }).closest('.lb-glass') as HTMLElement;
    expect(within(health).getByText('2.1 s')).toBeInTheDocument();
    expect(within(health).getByText(/^5% of checkouts · last /)).toBeInTheDocument();
    expect(within(health).getByText('Median of 3 starts · 95% within 3 min')).toBeInTheDocument();

    await userEvent.click(screen.getByRole('button', { name: '7 days' }));
    expect(await screen.findByRole('img', { name: /^Capacity over the last 7 days\./ })).toBeInTheDocument();
    expect(requests).toContain('/api/ui/metrics/utilization?hours=168');
    expect(screen.getByRole('button', { name: '7 days' })).toHaveAttribute('aria-pressed', 'true');

    await userEvent.click(screen.getByRole('button', { name: 'View as table' }));
    const table = screen.getByRole('table', { name: 'Capacity over the last 7 days, by 60-minute interval' });
    expect(within(table).getAllByRole('row')).toHaveLength(169);
  });

  it('puts what needs attention first on the dashboard', async () => {
    attention = ATTENTION;
    renderApp('/');

    const panel = await screen.findByRole('region', { name: 'Needs attention now' });
    expect(within(panel).getByText(/No host can take a new user/)).toBeInTheDocument();
    expect(within(panel).getByRole('link', { name: 'Open host' })).toHaveAttribute('href', '/vms/2');
    expect(within(panel).getByRole('link', { name: 'Fleet health' })).toHaveAttribute('href', '/vms/health?show=xrdp-down');
  });

  it('leaves the trends out when the broker predates them', async () => {
    attention = { Available: false, Items: [], Summary: { Total: 0 }, Incomplete: true };
    renderApp('/');

    await screen.findByText('33% of the pool in use');
    await waitFor(() => expect(requests).toContain('/api/ui/metrics/utilization?hours=24'));
    expect(screen.queryByRole('heading', { name: 'Capacity' })).not.toBeInTheDocument();
    expect(screen.queryByRole('region', { name: 'Needs attention now' })).not.toBeInTheDocument();
  });

  it('reports utilization as the scaler sees it when the broker counts serviceable hosts', async () => {
    dashboard = {
      ...DASHBOARD,
      stats: { ...DASHBOARD.stats, utilization: 75, utilization_basis: 'serviceable', serviceable: 4, in_use: 3 },
    };
    renderApp('/');

    expect(await screen.findByText('75% of the hosts that can take a user are in use')).toBeInTheDocument();
    expect(screen.getByText('3 of 4 in use')).toBeInTheDocument();
  });

  it('shows the active maintenance run and pauses it', async () => {
    renderApp('/vms/maintenance');

    const [activeLink] = await screen.findAllByRole('link', { name: 'October patching (run 7)' });
    expect(activeLink).toHaveAttribute('href', '/vms/maintenance/7');
    expect(screen.getByText(/taking linux-host-03 now would leave fewer than 2 ready/)).toBeInTheDocument();
    expect(screen.getByText(/hosts ready for users now; the run keeps at/)).toHaveTextContent(
      '2 hosts ready for users now; the run keeps at least 2 (the scaling minimum). Last advanced just now.',
    );
    expect(screen.getByRole('link', { name: 'Maintenance run 6' })).toBeInTheDocument();
    expect(screen.queryByRole('link', { name: 'New run' })).not.toBeInTheDocument();

    await userEvent.click(screen.getByRole('button', { name: 'Pause' }));
    await waitFor(() => expect(requests).toContain('/api/ui/maintenance/runs/7/pause'));
    expect(await screen.findByText('Done: pause run 7.')).toBeInTheDocument();
  });

  it('cancels a maintenance run only after confirming', async () => {
    renderApp('/vms/maintenance');
    await userEvent.click(await screen.findByRole('button', { name: 'Cancel run' }));

    const dialog = screen.getByRole('dialog', { name: 'Cancel October patching (run 7)?' });
    expect(requests).not.toContain('/api/ui/maintenance/runs/7/cancel');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Cancel the run' }));
    await waitFor(() => expect(requests).toContain('/api/ui/maintenance/runs/7/cancel'));
  });

  it('warns when a run is not being advanced', async () => {
    maintenance = maintenancePage(maintenanceRun({ LastTickAgeSeconds: 900 }));
    renderApp('/vms/maintenance');
    expect(await screen.findByText(/has not been advanced for 15 min/)).toBeInTheDocument();
  });

  it('shows each host of a maintenance run and what it is waiting for', async () => {
    renderApp('/vms/maintenance/7');

    const table = await screen.findByRole('table', { name: /Each host in October patching/ });
    const rows = within(table).getAllByRole('row');
    expect(rows[1]).toHaveTextContent('linux-host-01');
    expect(rows[1]).toHaveTextContent('Done');
    expect(rows[2]).toHaveTextContent('Waiting for alice to sign out.');
    expect(within(rows[3]).getByText('Too old to patch')).toBeInTheDocument();
    expect(screen.getByText(/linux-host-03 run a host agent older than 1.1.0 and will fail/)).toBeInTheDocument();
    expect(screen.getByText('Warned, then signed out after 60 min')).toBeInTheDocument();
  });

  it('starts a maintenance run from the hosts chosen', async () => {
    maintenance = maintenancePage(null);
    renderApp('/vms/maintenance/new');

    await userEvent.click(await screen.findByRole('checkbox', { name: 'Include linux-host-01' }));
    expect(screen.getByText(/linux-host-01 run a host agent older than 1.1.0 and\s+cannot be patched/)).toBeInTheDocument();

    await userEvent.click(screen.getByRole('radio', { name: /Restart only/ }));
    expect(screen.queryByText(/cannot be patched/)).not.toBeInTheDocument();

    const batch = screen.getByLabelText('Hosts at a time');
    await userEvent.clear(batch);
    await userEvent.type(batch, '2');
    await userEvent.click(screen.getByRole('switch', { name: /Sign users out after a deadline/ }));
    await userEvent.click(screen.getByRole('button', { name: 'Start the run' }));

    await waitFor(() => expect(requests).toContain('/api/ui/maintenance/runs/8'));
    const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls.find(
      ([url, init]) => String(url) === '/api/ui/maintenance/runs' && init?.method === 'POST',
    );
    expect(JSON.parse(String(call?.[1]?.body))).toEqual({
      hostnames: ['linux-host-01'], patchMode: 'RebootOnly', batchSize: 2, minReady: null, signOutDeadlineMinutes: 60,
      warningMinutes: 15, includePoweredOff: false, maxFailures: 1, canaryCount: 0,
    });
  });

  it('asks for a host before starting a run', async () => {
    maintenance = maintenancePage(null);
    renderApp('/vms/maintenance/new');
    await userEvent.click(await screen.findByRole('button', { name: 'Start the run' }));
    expect(screen.getByText('Choose at least one host.')).toBeInTheDocument();
    expect(requests).not.toContain('/api/ui/maintenance/runs/8');
  });

  it('allows one maintenance run at a time', async () => {
    renderApp('/vms/maintenance/new');
    expect(await screen.findByText('A run is already active')).toBeInTheDocument();
  });

  it('keeps maintenance read-only for readers', async () => {
    session = { ...SESSION, roles: ['Reader'], permissions: { read: true, operate: false, admin: false } };
    renderApp('/vms/maintenance');
    await screen.findAllByRole('link', { name: 'October patching (run 7)' });
    expect(screen.queryByRole('button', { name: 'Pause' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Cancel run' })).not.toBeInTheDocument();
  });

  it('says when the broker has no rolling maintenance yet', async () => {
    maintenance = { Available: false, Runs: [], Active: null };
    renderApp('/vms/maintenance');
    expect(await screen.findByText(/Rolling maintenance needs the broker API and database from this release/)).toBeInTheDocument();
  });

  it('filters fleet health by flag', async () => {
    renderApp('/vms/health');

    expect(await screen.findByRole('link', { name: 'linux-host-02' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'linux-host-01' })).toBeInTheDocument();

    await userEvent.click(screen.getByRole('button', { name: /No heartbeat/ }));

    expect(screen.getByRole('button', { name: /No heartbeat/ })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.queryByRole('link', { name: 'linux-host-01' })).not.toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'linux-host-02' })).toBeInTheDocument();
  });

  it('shows the host agent card on a host page', async () => {
    renderApp('/vms/1');
    expect(await screen.findByText('Red Hat Enterprise Linux 9.4')).toBeInTheDocument();
    expect(requests).toContain('/api/ui/hosts/health?hostname=linux-host-01');
  });

  it('lists audit entries with filters that can be exported', async () => {
    renderApp('/audit?action=vm.&outcome=success');

    expect(await screen.findByText('vm.stop')).toBeInTheDocument();
    expect(screen.getByText('Service identity')).toBeInTheDocument();
    expect(requests.some((url) => url.startsWith('/api/ui/audit?action=vm.&outcome=success&page=1&per_page=25'))).toBe(true);
    expect(screen.getByRole('link', { name: 'Export CSV' })).toHaveAttribute(
      'href',
      '/api/ui/audit/export.csv?action=vm.&outcome=success',
    );
  });

  it('shows what changed in each settings version', async () => {
    renderApp('/settings/hosts');

    expect(await screen.findByRole('heading', { name: 'Version history' })).toBeInTheDocument();
    expect(await screen.findByText('Saved by alice@contoso.com', { exact: false })).toBeInTheDocument();
    expect(screen.getByText('600 s (10 minutes)', { exact: false })).toBeInTheDocument();
  });

  it('lists sessions with what an operator needs to know', async () => {
    renderApp('/sessions');

    expect(await screen.findByRole('link', { name: 'alice' })).toHaveAttribute('href', '/users/alice');
    expect(screen.getByText('In use, idle 12 min')).toBeInTheDocument();
    expect(screen.getByText('Grace ends in 10 min')).toBeInTheDocument();
    expect(screen.getByText('Checked out 1 h 30 min ago; no session since')).toBeInTheDocument();

    await userEvent.click(screen.getByRole('button', { name: /Never connected/ }));
    expect(screen.getByRole('button', { name: /Never connected/ })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.queryByRole('link', { name: 'alice' })).not.toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'carol' })).toBeInTheDocument();
  });

  it('finds a user who may not have a session', async () => {
    renderApp('/sessions');
    await userEvent.type(await screen.findByLabelText('Find a user'), 'al');

    const result = await screen.findByText('On linux-host-02');
    expect(within(result.closest('li') as HTMLElement).getByRole('link', { name: 'alice' })).toHaveAttribute('href', '/users/alice');
    expect(requests.some((url) => url.startsWith('/api/ui/users?q=al'))).toBe(true);
  });

  it('messages a user from the sessions page', async () => {
    renderApp('/sessions');
    await userEvent.click(await screen.findByRole('button', { name: 'Session actions for alice on linux-host-02' }));
    await userEvent.click(screen.getByRole('menuitem', { name: 'Send message' }));

    const dialog = await screen.findByRole('dialog');
    const send = within(dialog).getByRole('button', { name: 'Send message' });
    expect(send).toBeDisabled();
    await userEvent.type(within(dialog).getByLabelText('Message'), 'Please save your work');
    await userEvent.click(send);

    await waitFor(() => {
      const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls.find(
        ([url]) => String(url) === '/api/ui/sessions/linux-host-02/alice/message',
      );
      expect(JSON.parse(String(call?.[1]?.body))).toEqual({ message: 'Please save your work' });
    });
    expect(await screen.findByText('Sent to alice on linux-host-02.')).toBeInTheDocument();
  });

  it('signs a user out only after confirming', async () => {
    renderApp('/sessions');
    await userEvent.click(await screen.findByRole('button', { name: 'Session actions for alice on linux-host-02' }));
    expect(screen.getAllByRole('menuitem').map((item) => item.textContent)).toEqual([
      'Send message', 'Sign out', 'Sign out and return host',
    ]);
    await userEvent.click(screen.getByRole('menuitem', { name: 'Sign out and return host' }));

    const dialog = await screen.findByRole('dialog');
    expect(within(dialog).getByText(/The assignment ends now/)).toBeInTheDocument();
    await userEvent.click(within(dialog).getByRole('button', { name: 'Sign out and return' }));

    await waitFor(() => {
      const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls.find(
        ([url]) => String(url) === '/api/ui/sessions/linux-host-02/alice/signout',
      );
      expect(JSON.parse(String(call?.[1]?.body))).toEqual({ returnHost: true });
    });
  });

  it('gives readers no session actions', async () => {
    session = { ...SESSION, roles: ['Reader'], permissions: { read: true, operate: false, admin: false } };
    renderApp('/sessions');
    await screen.findByRole('link', { name: 'alice' });
    expect(screen.queryByRole('button', { name: /Session actions for/ })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Message everyone' })).not.toBeInTheDocument();
  });

  it('messages everyone on the hosts in use', async () => {
    renderApp('/sessions');
    await userEvent.click(await screen.findByRole('button', { name: 'Message everyone' }));

    const dialog = await screen.findByRole('dialog');
    expect(within(dialog).getByText(/every session on the 3 hosts in use/)).toBeInTheDocument();
    await userEvent.type(within(dialog).getByLabelText('Message'), 'Hosts restart at 18:00');
    await userEvent.click(within(dialog).getByRole('button', { name: 'Send to all' }));

    await waitFor(() => {
      const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls.find(
        ([url]) => String(url) === '/api/ui/sessions/broadcast',
      );
      expect(JSON.parse(String(call?.[1]?.body))).toEqual({ message: 'Hosts restart at 18:00' });
    });
    expect(await screen.findByText('Shown in 2 session(s) on 2 of 2 host(s).')).toBeInTheDocument();
  });

  it('resets a profile only after the administrator types the username', async () => {
    renderApp('/users/alice');

    expect(await screen.findByRole('heading', { name: 'alice', level: 1 })).toBeInTheDocument();
    expect(screen.getByText('Linux user ID 2001')).toBeInTheDocument();
    expect(screen.getByText('session.message')).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: 'Reset profile' }));

    const dialog = await screen.findByRole('dialog');
    const reset = within(dialog).getByRole('button', { name: 'Reset profile' });
    expect(reset).toBeDisabled();
    await userEvent.type(within(dialog).getByLabelText(/to confirm/), 'alice');
    await userEvent.click(reset);

    await waitFor(() => {
      const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls.find(
        ([url]) => String(url) === '/api/ui/users/alice/reset-profile',
      );
      expect(JSON.parse(String(call?.[1]?.body))).toEqual({ confirm: 'alice' });
    });
  });

  it('shows a pending profile reset and lets an administrator cancel it', async () => {
    userDetails = { ...freshUserDetails(), ProfileReset: { RequestedAtUtc: '2026-09-24T10:00:00Z', RequestedBy: 'admin@contoso.com' } };
    renderApp('/users/alice');

    expect(await screen.findByText(/admin@contoso.com asked for a fresh profile/)).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: 'Cancel profile reset' }));
    await userEvent.click(within(await screen.findByRole('dialog')).getByRole('button', { name: 'Cancel the reset' }));
    await waitFor(() => expect(requests).toContain('/api/ui/users/alice/reset-profile/cancel'));
  });

  it('hides profile resets from operators', async () => {
    session = { ...SESSION, roles: ['Operator'], permissions: { read: true, operate: true, admin: false } };
    renderApp('/users/alice');
    await screen.findByRole('heading', { name: 'alice', level: 1 });
    expect(screen.queryByRole('button', { name: 'Reset profile' })).not.toBeInTheDocument();
  });

  it('shows what is in force, what happens next and the week', async () => {
    renderApp('/scaling');

    expect(await screen.findByText('Start 2 hosts (linux-host-05, linux-host-06).')).toBeInTheDocument();
    expect(screen.getAllByText('Business hours').length).toBeGreaterThan(0);
    expect(screen.getByText(/takes over on Thursday 18:00, in 7 h 45 min/)).toBeInTheDocument();
    expect(screen.getByRole('img', { name: /Business hours: Mon\u2013Fri 08:00 to 18:00\. The default rule applies at all other times/ })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Edit Business hours' })).toBeInTheDocument();
  });

  it('keeps the scaling policy read-only for operators', async () => {
    session = { ...SESSION, roles: ['Operator'], permissions: { read: true, operate: true, admin: false } };
    renderApp('/scaling');
    await screen.findByText('Start 2 hosts (linux-host-05, linux-host-06).');
    expect(screen.queryByRole('link', { name: 'Add a window' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Edit Business hours' })).not.toBeInTheDocument();
    expect(screen.queryByLabelText('Time zone')).not.toBeInTheDocument();
  });

  it('changes the policy time zone', async () => {
    renderApp('/scaling');
    const zone = await screen.findByLabelText('Time zone');
    await waitFor(() => expect(within(zone).getAllByRole('option')).toHaveLength(2));
    await userEvent.selectOptions(zone, 'Eastern Standard Time');
    await userEvent.click(screen.getByRole('button', { name: 'Use this time zone' }));

    await waitFor(() => {
      const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls.find(
        ([url, init]) => String(url) === '/api/ui/scaling/policy' && init?.method === 'POST',
      );
      expect(JSON.parse(String(call?.[1]?.body))).toEqual({ timezone: 'Eastern Standard Time' });
    });
  });

  it('refuses a window that overlaps another before saving', async () => {
    renderApp('/scaling/schedules/new');
    const name = await screen.findByLabelText('Name');
    await userEvent.type(name, 'Lunch peak');
    const starts = screen.getByLabelText('Starts');
    const ends = screen.getByLabelText('Ends');
    await userEvent.clear(starts);
    await userEvent.type(starts, '11:00');
    await userEvent.clear(ends);
    await userEvent.type(ends, '14:00');

    expect(await screen.findByText(/This window overlaps Business hours \(Mon\u2013Fri 08:00\u201318:00\)/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Add window' })).toBeDisabled();

    // Moving it into the evening clears the clash, and it saves with the default rule's values.
    await userEvent.clear(starts);
    await userEvent.type(starts, '18:00');
    await userEvent.clear(ends);
    await userEvent.type(ends, '22:00');
    await userEvent.click(screen.getByRole('button', { name: 'Add window' }));

    await waitFor(() => {
      const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls.find(
        ([url]) => String(url) === '/api/ui/scaling/schedules',
      );
      expect(JSON.parse(String(call?.[1]?.body))).toEqual({
        name: 'Lunch peak', days: ['mon', 'tue', 'wed', 'thu', 'fri'], start: '18:00', end: '22:00', enabled: true,
        minvms: '2', maxvms: '20', scaleupratio: '80', scaleupincrement: '2', scaledownratio: '30', scaledownincrement: '1',
      });
    });
  });

  it('previews proposed window values without saving them', async () => {
    renderApp('/scaling/schedules/1');
    await userEvent.click(await screen.findByRole('button', { name: 'Preview with these values' }));

    expect(await screen.findByText('No scaling threshold was crossed.')).toBeInTheDocument();
    const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls.find(
      ([url, init]) => String(url) === '/api/ui/scaling/preview' && init?.method === 'POST',
    );
    expect(JSON.parse(String(call?.[1]?.body)).rule).toMatchObject({ minvms: '4', name: 'Business hours' });
    expect(requests.some((url) => url.startsWith('/api/ui/scaling/schedules'))).toBe(false);
  });
});
