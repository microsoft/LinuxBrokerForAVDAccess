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

/*
 * Sessions and users. A session's State is derived by the broker from its assignment and
 * the host's latest heartbeat.
 */
export type SessionState =
  | 'active'
  | 'disconnected'
  | 'released'
  | 'connecting'
  | 'not-connected'
  | 'cleanup-pending'
  | 'unmanaged'
  | 'unknown';

export interface BrokerSession {
  Hostname: string;
  VMID: number | null;
  Username: string;
  AvdHost: string | null;
  State: SessionState;
  VmStatus: string | null;
  PowerState: string | null;
  NetworkStatus: string | null;
  DrainRequested: boolean;
  HasAssignment: boolean;
  CleanupPending: boolean;
  ReportedState: 'active' | 'disconnected' | 'unknown' | null;
  SessionStartUtc: string | null;
  DisconnectedForSeconds: number | null;
  IdleSeconds: number | null;
  AssignedForSeconds: number | null;
  LastCheckoutAgeSeconds: number | null;
  GraceRemainingSeconds: number | null;
  GracePeriodSeconds: number | null;
  HeartbeatAgeSeconds: number | null;
  HeartbeatFresh: boolean;
}

export type SessionSummary = Record<SessionState, number> & { Total: number };

export interface SessionsPage {
  Sessions: BrokerSession[];
  Summary: SessionSummary;
}

export interface BrokerUserMatch {
  Username: string;
  Uid: number | null;
  ProfileResetPending: boolean;
  CurrentVMID: number | null;
  CurrentHostname: string | null;
  CurrentVmStatus: string | null;
}

export interface UserSearchResult {
  Users: BrokerUserMatch[];
  Query: string | null;
}

export interface UserAssignment {
  VMID: number;
  Hostname: string;
  VmStatus: string | null;
  PowerState: string | null;
  NetworkStatus: string | null;
  AvdHost: string | null;
  DrainRequested: boolean;
  CleanupPending: boolean;
  AssignedForSeconds: number | null;
  LastCheckoutAgeSeconds: number | null;
  ReleasedForSeconds: number | null;
}

export interface UserHostHistoryEntry {
  VMID: number;
  Hostname: string;
  FirstSeenUtc: string;
  LastSeenUtc: string;
  Assignments: number;
  IsCurrent: boolean;
}

export interface BrokerUserDetails {
  Username: string;
  Uid: number | null;
  FirstProvisionedDate: string | null;
  ProfileReset: { RequestedAtUtc: string; RequestedBy: string | null } | null;
  Assignments: UserAssignment[];
  Sessions: BrokerSession[];
  HostHistory: UserHostHistoryEntry[];
  RecentActivity: AuditEntry[];
}

export interface SignOutResult {
  Hostname: string;
  Username: string;
  Result: 'SignedOut' | 'NoSession';
  Released: boolean;
  Returned: boolean;
  CleanupResult: string | null;
  message: string;
}

export interface MessageResult {
  Hostname: string;
  Username: string;
  Sessions: number;
  Delivered: number;
  message: string;
}

export interface ProfileResetResult {
  Username: string;
  message: string;
  CurrentlyAssigned?: boolean;
  Result?: string;
}

export interface BroadcastResult {
  TargetCount: number;
  Delivered: number;
  Results: Array<{ Hostname: string; Result: 'Delivered' | 'NoSession' | 'AgentOutdated' | 'Failed'; Sessions: number; Delivered: number }>;
  NotAttempted: string[];
  UnknownHostnames: string[];
  SkippedHostnames: string[];
  message: string;
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
  /** In use out of serviceable when `utilization_basis` is 'serviceable'. */
  utilization: number;
  /** The scaler's counts. Null or absent from a broker API that predates them. */
  serviceable?: number | null;
  in_use?: number | null;
  /** 'serviceable' is the scaler's figure; 'total' the older checked-out share of every host. */
  utilization_basis?: 'serviceable' | 'total';
  pct: PoolComposition;
}

export interface Dashboard {
  stats: DashboardStats | null;
  recentActivity: ActivityLogEntry[];
  /** Null when the broker API predates host heartbeats or could not report them. */
  fleetHealth?: (FleetHealthSummary & { ExpectedAgentVersion?: string | null }) | null;
  apiError: boolean;
}

/** One bucket of the capacity chart. Averages over the scaling runs in it; null with none. */
export interface UtilizationPoint {
  BucketStartUtc: string;
  Runs: number;
  PoweredOn: number | null;
  InUse: number | null;
  Serviceable: number | null;
  PeakInUse: number | null;
  MinVMs: number | null;
  MaxVMs: number | null;
  Checkouts: number;
  Denied: number;
  Failed: number;
}

export interface CheckoutStats {
  Total: number;
  Assigned: number;
  Reused: number;
  NoneAvailable: number;
  ProvisionFailed: number;
  Errors: number;
  P50Ms: number | null;
  P95Ms: number | null;
  DeniedLastHour: number;
  DeniedPercent: number | null;
  LastDeniedUtc: string | null;
  HostStarts: number;
  StartP50Seconds: number | null;
  StartP95Seconds: number | null;
}

export type UtilizationHours = 24 | 168;

/** Available is false while the broker or its database predates the trends. */
export interface UtilizationMetrics {
  Available: boolean;
  Hours: UtilizationHours;
  BucketMinutes?: number;
  FromUtc?: string;
  ToUtc?: string;
  Series?: UtilizationPoint[];
  Checkouts?: CheckoutStats;
}

export type AttentionSeverity = 'critical' | 'warning' | 'info';

export type AttentionKind =
  | 'no-ready-hosts'
  | 'denied-checkouts'
  | 'unreachable'
  | 'cleanup-stuck'
  | 'never-connected'
  | 'health';

export interface AttentionItem {
  Kind: AttentionKind;
  Severity: AttentionSeverity;
  VMID?: number | null;
  Hostname?: string | null;
  Username?: string | null;
  AgeSeconds?: number | null;
  Count?: number | null;
  /** For a health item: the flag, and the first hosts that have it. */
  Flag?: HealthFlag;
  Hostnames?: string[];
}

export interface AttentionItems {
  Available: boolean;
  Items: AttentionItem[];
  Summary: { Total: number; Critical?: number; Warning?: number; Info?: number };
  /** True while the database cannot report the broker's own conditions yet. */
  Incomplete: boolean;
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

export type ScheduleDay = 'mon' | 'tue' | 'wed' | 'thu' | 'fri' | 'sat' | 'sun';

/** A window that overrides the default scaling rule on some days and times. */
export interface ScalingSchedule {
  ScheduleID: number;
  Name: string;
  Enabled: boolean;
  Days: ScheduleDay[];
  DaysOfWeek: number;
  StartTime: string;
  EndTime: string;
  CrossesMidnight: boolean;
  MinVMs: number;
  MaxVMs: number;
  ScaleUpRatio: number;
  ScaleUpIncrement: number;
  ScaleDownRatio: number;
  ScaleDownIncrement: number;
  StopMode: 'PowerOff' | 'Deallocate' | null;
  UpdatedBy: string | null;
  UpdatedAtUtc: string | null;
}

export interface ScalingPhase {
  Source: 'Schedule' | 'Rule' | 'Proposed' | null;
  ScheduleID: number | null;
  Name: string | null;
  MinVMs: number | null;
  MaxVMs: number | null;
  ScaleUpRatio: number | null;
  ScaleUpIncrement: number | null;
  ScaleDownRatio: number | null;
  ScaleDownIncrement: number | null;
  StopMode: 'PowerOff' | 'Deallocate' | null;
}

export interface ScalingPolicy {
  TimeZone: string;
  UpdatedBy: string | null;
  UpdatedAtUtc: string | null;
  NowUtc: string | null;
  LocalTime: string | null;
  ActivePhase: ScalingPhase | null;
  DefaultRule: ScalingRule | null;
  Schedules: ScalingSchedule[];
  NextChange: { InMinutes: number; AtLocal: string; PhaseName: string; ScheduleID: number | null } | null;
  LastRun: ActivityLogEntry | null;
}

export interface ScalingPreview {
  Action: 'PowerOn' | 'PowerOff' | 'None';
  Summary: string;
  Reason: string | null;
  RequestCount: number | null;
  Candidates: string[];
  Phase: ScalingPhase;
  Counts: { PoweredOn: number; Serviceable: number; InUse: number; Draining: number; Utilization: number | null };
  TimeZone: string | null;
  LocalTime: string | null;
  AtUtc: string | null;
}

export interface TimeZoneOption {
  Name: string;
  CurrentUtcOffset: string;
  IsCurrentlyDst: boolean;
}

export interface ScheduleInput extends Omit<ScalingRuleInput, 'stopmode'> {
  name: string;
  days: ScheduleDay[];
  start: string;
  end: string;
  enabled: boolean;
  /** Empty uses the default rule's. */
  stopmode: 'PowerOff' | 'Deallocate' | '';
}
