/*
 * Shapes returned by the Flask BFF. The broker's own PascalCase field names are
 * preserved end to end rather than remapped, so a payload can be traced from the
 * stored procedure through the API to the component without a rename in between.
 */

export interface SessionUser {
  name: string | null;
  username: string | null;
  objectId: string | null;
  tenantId: string | null;
}

export interface Permissions {
  read: boolean;
  operate: boolean;
  admin: boolean;
}

export interface SessionInfo {
  authenticated: boolean;
  version: string;
  csrfToken: string;
  user: SessionUser | null;
  roles: string[];
  permissions: Permissions;
  legacyAccess: boolean;
  permissionsUnavailable: boolean;
}

export type VmStatus = 'Available' | 'CheckedOut' | 'Maintenance' | 'Released';
export type PowerState = 'On' | 'Off';
export type NetworkStatus = 'Reachable' | 'Unreachable';

/** Values are constrained by the VmStatus CHECK constraint on virtual_machines. */
export const VM_STATUSES: VmStatus[] = ['Available', 'CheckedOut', 'Maintenance', 'Released'];
export const POWER_STATES: PowerState[] = ['On', 'Off'];
export const NETWORK_STATUSES: NetworkStatus[] = ['Reachable', 'Unreachable'];

export interface Vm {
  VMID: number;
  Hostname: string;
  IPAddress: string | null;
  PowerState: string | null;
  NetworkStatus: string | null;
  VmStatus: string | null;
  Username: string | null;
  AvdHost: string | null;
  Description: string | null;
  LastUpdateDate: string | null;
  CreateDate: string | null;
  SysStartTime: string | null;
  SysEndTime: string | null;
  SettingsVersion?: number | null;
  SettingsAppliedDate?: string | null;
  ReleasedDate?: string | null;
  CleanupPending?: boolean | null;
  CleanupUsername?: string | null;
  PowerStateChangedDate?: string | null;
  /** The host takes no new users and moves to maintenance when its assignment ends. */
  DrainRequested?: boolean | null;
  DrainRequestedDate?: string | null;
}

/** What a start, stop or restart request returned. The Azure operation runs on. */
export interface PowerActionResult {
  VMID: number;
  Hostname: string;
  Action: 'Start' | 'Stop' | 'Restart';
  Mode?: 'PowerOff' | 'Deallocate';
  EndedAssignment?: boolean;
  message: string;
}

export interface DrainResult {
  VMID: number;
  Hostname: string;
  VmStatus: string | null;
  DrainRequested: boolean;
  Result: 'Draining' | 'Drained' | 'ReturnedToService' | 'Unchanged';
  message: string;
}

export interface PowerSyncResult {
  PowerStateCorrections: Array<{ Hostname: string; PowerState: string }>;
  PowerSyncFailed: boolean;
  message: string;
}

export type HealthFlag =
  | 'no-heartbeat'
  | 'stale'
  | 'xrdp-down'
  | 'nfs-unreachable'
  | 'low-disk'
  | 'agent-outdated'
  | 'settings-drift';

export interface HostSession {
  username: string;
  state: 'active' | 'disconnected' | 'unknown';
  sessionStart?: number | null;
  disconnectedSince?: number | null;
  idleSeconds?: number | null;
}

/** One host in GET /api/hosts/health: its latest heartbeat and what needs attention. */
export interface HostHealth {
  VMID: number;
  Hostname: string;
  PowerState: string | null;
  NetworkStatus: string | null;
  VmStatus: string | null;
  DrainRequested: boolean;
  CleanupPending: boolean;
  Username: string | null;
  Status: 'healthy' | 'attention' | 'off';
  Flags: HealthFlag[];
  Reporting: boolean;
  LastHeartbeatUtc: string | null;
  HeartbeatAgeSeconds: number | null;
  AgentVersion: string | null;
  ScriptVersions: Record<string, string | null> | null;
  AppliedSettingsVersion: number | null;
  CurrentSettingsVersion: number | null;
  OsId: string | null;
  OsVersion: string | null;
  OsName: string | null;
  KernelVersion: string | null;
  Desktop: string | null;
  XrdpVersion: string | null;
  XrdpActive: boolean | null;
  NfsReachable: boolean | null;
  NfsMountCount: number | null;
  LoadAverage: number | null;
  CpuCount: number | null;
  MemoryAvailableMb: number | null;
  MemoryTotalMb: number | null;
  RootDiskFreePct: number | null;
  UptimeSeconds: number | null;
  SessionCount: number | null;
  Sessions: HostSession[];
}

export interface FleetHealthSummary {
  Total: number;
  PoweredOn: number;
  Reporting: number;
  Healthy: number;
  Attention: number;
  Off: number;
  NoHeartbeat: number;
  Stale: number;
  XrdpDown: number;
  NfsUnreachable: number;
  LowDisk: number;
  AgentOutdated: number;
  SettingsDrift: number;
}

export interface FleetHealth {
  ExpectedAgentVersion: string;
  CurrentSettingsVersion: number | null;
  StaleAfterSeconds: number;
  Summary: FleetHealthSummary;
  Hosts: HostHealth[];
}

export type AuditOutcome = 'success' | 'failure' | 'denied';

export interface AuditEntry {
  AuditId: number;
  OccurredAtUtc: string;
  ActorOid: string | null;
  ActorName: string | null;
  ActorType: 'user' | 'service' | 'system';
  Action: string;
  TargetType: string | null;
  TargetId: string | null;
  Outcome: AuditOutcome;
  Detail: Record<string, unknown> | unknown[] | null;
  CorrelationId: string | null;
}

/** The audit page's filters, held in the URL like the history filters. */
export interface AuditFilterValues {
  from: string;
  to: string;
  actor: string;
  action: string;
  target: string;
  outcome: '' | AuditOutcome;
}

/** One saved version of the host settings profile. */
export interface HostSettingsVersion extends HostSettings {
  UpdatedBy: string | null;
  ValidFromUtc: string | null;
  ValidToUtc: string | null;
  IsCurrent: boolean;
}

export interface ScalingRule {
  RuleID: number;
  MinVMs: number;
  MaxVMs: number;
  ScaleUpRatio: number;
  ScaleUpIncrement: number;
  ScaleDownRatio: number;
  ScaleDownIncrement: number;
  StopMode?: 'PowerOff' | 'Deallocate' | null;
  IsActive?: boolean | null;
  SysStartTime?: string | null;
  SysEndTime?: string | null;
}

export interface ActivityLogEntry {
  ActivityID: number;
  CheckTimestamp: string | null;
  CurrentRunningVMs: number | null;
  CurrentInUseVMs: number | null;
  ActionTaken: string | null;
  VMsPoweredOn: number | null;
  VMsPoweredOff: number | null;
  NewTotalVMs: number | null;
  Outcome: string | null;
  Notes: string | null;
}

export interface HostSettings {
  GracePeriodSeconds: number;
  ReconcileIntervalSeconds: number;
  WatcherDebounceSeconds: number;
  WatcherSettleSeconds: number;
  IdleTimeoutSeconds: number;
  IdleWarningSeconds: number;
  ScreenLockEnabled: boolean;
  DisableLockScreen: boolean;
  ScreenIdleDelaySeconds: number;
  ScreenLockDelaySeconds: number;
  ScreenLockSettingsLocked: boolean;
  PreserveSessionsOnDisconnect: boolean;
  SettingsVersion: number;
}

export interface HostSettingsPage {
  settings: HostSettings;
  hosts: Vm[];
}

export interface ApplySettingsResult {
  settingsVersion: number | null;
  targetCount: number;
  succeededCount: number;
  unreachable: string[];
  message: string;
  tone: 'success' | 'warning' | 'info';
  notAttempted?: string[];
}

export interface SaveSettingsResult {
  settings: HostSettings;
  message: string;
  tone: 'success' | 'warning' | 'info';
}

/** Percentage of the pool each status accounts for. */
export interface PoolComposition {
  available: number;
  checked_out: number;
  released: number;
  maintenance: number;
  other: number;
}

export interface DashboardStats {
  total: number;
  available: number;
  checked_out: number;
  maintenance: number;
  released: number;
  other: number;
  unreachable: number;
  powered_on: number;
  powered_off: number;
  ready: number;
  cleanup_pending: number;
  /** Absent from BFF builds that predate drain. */
  draining?: number;
  attention: number;
  utilization: number;
  pct: PoolComposition;
}

export interface Dashboard {
  stats: DashboardStats | null;
  recentActivity: ActivityLogEntry[];
  /** Null when the broker API predates host heartbeats or could not report them. */
  fleetHealth?: (FleetHealthSummary & { ExpectedAgentVersion?: string | null }) | null;
  apiError: boolean;
}

export interface Paged<T> {
  items: T[];
  page: number;
  perPage: number;
  total: number;
  totalPages: number;
}

/** The filter bar shared by VM history, the activity log and rule history. */
export interface HistoryFilterValues {
  startdate: string;
  enddate: string;
  limit: string;
  ignore_dates: boolean;
  ignore_limit: boolean;
}

export interface VmInput {
  hostname: string;
  ipaddress: string;
  powerstate: string;
  networkstatus: string;
  vmstatus: string;
  username?: string;
  avdhost?: string;
  description?: string;
}

export interface VmAttributesInput {
  powerstate: string;
  networkstatus: string;
  vmstatus: string;
}

export interface ScalingRuleInput {
  minvms: string;
  maxvms: string;
  scaleupratio: string;
  scaleupincrement: string;
  scaledownratio: string;
  scaledownincrement: string;
  stopmode: 'PowerOff' | 'Deallocate';
}
