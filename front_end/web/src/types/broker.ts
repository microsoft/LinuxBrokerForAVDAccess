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

export interface SessionInfo {
  authenticated: boolean;
  version: string;
  csrfToken: string;
  user: SessionUser | null;
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
}

export interface ScalingRule {
  RuleID: number;
  MinVMs: number;
  MaxVMs: number;
  ScaleUpRatio: number;
  ScaleUpIncrement: number;
  ScaleDownRatio: number;
  ScaleDownIncrement: number;
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
  attention: number;
  utilization: number;
  pct: PoolComposition;
}

export interface Dashboard {
  stats: DashboardStats | null;
  recentActivity: ActivityLogEntry[];
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
}
