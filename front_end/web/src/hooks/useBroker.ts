import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';

import { apiGet, apiPost } from '../lib/api';
import { queryKeys } from '../lib/queryClient';
import type {
  ActivityLogEntry,
  ApplySettingsResult,
  AuditEntry,
  BroadcastResult,
  BrokerUserDetails,
  Dashboard,
  DrainResult,
  FleetHealth,
  HostSettings,
  HostSettingsPage,
  HostSettingsVersion,
  MessageResult,
  Paged,
  PowerActionResult,
  PowerSyncResult,
  ProfileResetResult,
  SaveSettingsResult,
  ScalingRule,
  ScalingRuleInput,
  SessionsPage,
  SignOutResult,
  UserSearchResult,
  Vm,
  VmAttributesInput,
  VmInput,
} from '../types/broker';

/* -------------------------------------------------------------- dashboard */

export function useDashboard(refreshMs: number | false) {
  return useQuery({
    queryKey: queryKeys.dashboard,
    queryFn: ({ signal }) => apiGet<Dashboard>('/dashboard', signal),
    refetchInterval: refreshMs,
  });
}

/* -------------------------------------------------------------------- VMs */

export function useVms() {
  return useQuery({
    queryKey: queryKeys.vms,
    queryFn: ({ signal }) => apiGet<Vm[]>('/vms', signal),
  });
}

export function useVm(vmid: string | undefined) {
  return useQuery({
    queryKey: queryKeys.vm(vmid ?? ''),
    queryFn: ({ signal }) => apiGet<Vm>(`/vms/${vmid}`, signal),
    enabled: Boolean(vmid),
  });
}

export function useVmHistory(search: string) {
  return useQuery({
    queryKey: queryKeys.vmHistory(search),
    queryFn: ({ signal }) => apiGet<Paged<Vm>>(`/vms/history${search}`, signal),
    // Keeps the previous page on screen while the next one loads, instead of
    // collapsing the table to a spinner on every page change.
    placeholderData: (previous) => previous,
  });
}

/**
 * Invalidate everything derived from the VM list.
 *
 * Any VM mutation can change the dashboard counters, the host settings drift table and
 * fleet health as well as the list itself, so they are refreshed together.
 */
function useVmInvalidation() {
  const queryClient = useQueryClient();

  return () => {
    void queryClient.invalidateQueries({ queryKey: queryKeys.vms });
    void queryClient.invalidateQueries({ queryKey: queryKeys.dashboard });
    void queryClient.invalidateQueries({ queryKey: queryKeys.hostSettings });
    void queryClient.invalidateQueries({ queryKey: queryKeys.fleetHealth });
    void queryClient.invalidateQueries({ queryKey: queryKeys.sessions });
  };
}

export function useAddVm() {
  const invalidate = useVmInvalidation();

  return useMutation({
    mutationFn: (input: VmInput) => apiPost<Vm>('/vms', input),
    onSuccess: invalidate,
  });
}

export function useUpdateVmAttributes(vmid: string) {
  const invalidate = useVmInvalidation();

  return useMutation({
    mutationFn: (input: VmAttributesInput) =>
      apiPost<unknown>(`/vms/${vmid}/update-attributes`, input),
    onSuccess: invalidate,
  });
}

export function useDeleteVm() {
  const invalidate = useVmInvalidation();

  return useMutation({
    mutationFn: (vmid: number) => apiPost<unknown>(`/vms/${vmid}/delete`),
    onSuccess: invalidate,
  });
}

export function useReleaseVm() {
  const invalidate = useVmInvalidation();

  return useMutation({
    mutationFn: (hostname: string) =>
      apiPost<unknown>(`/vms/${encodeURIComponent(hostname)}/release`),
    onSuccess: invalidate,
  });
}

export function useReturnVm() {
  const invalidate = useVmInvalidation();

  return useMutation({
    mutationFn: (vmid: number) => apiPost<{ CleanupPending?: boolean; message?: string }>(`/vms/${vmid}/return`),
    onSuccess: invalidate,
  });
}

export function useCleanupVm() {
  const invalidate = useVmInvalidation();

  return useMutation({
    mutationFn: (vmid: number) => apiPost<{ message?: string }>(`/vms/${vmid}/cleanup`),
    onSuccess: invalidate,
  });
}

export function useSetVmMaintenance() {
  const invalidate = useVmInvalidation();

  return useMutation({
    mutationFn: (input: { vmid: number; enabled: boolean }) =>
      apiPost<{ message?: string; Result?: string }>(`/vms/${input.vmid}/maintenance`, { enabled: input.enabled }),
    onSuccess: invalidate,
  });
}

export function useCheckoutVm() {
  const invalidate = useVmInvalidation();

  return useMutation({
    mutationFn: (input: { username: string; avdhost: string }) =>
      apiPost<Vm>('/vms/checkout', input),
    onSuccess: invalidate,
  });
}

/* ----------------------------------------------------------- host actions */

export type PowerAction = 'start' | 'stop' | 'restart';

export interface PowerActionInput {
  vmid: number;
  action: PowerAction;
  /** The hostname, typed by an administrator acting on a host that is in use. */
  confirm?: string;
  mode?: 'PowerOff' | 'Deallocate';
}

export function usePowerAction() {
  const invalidate = useVmInvalidation();

  return useMutation({
    mutationFn: ({ vmid, action, confirm, mode }: PowerActionInput) =>
      apiPost<PowerActionResult>(`/vms/${vmid}/${action}`, {
        ...(confirm ? { confirm } : {}),
        ...(mode ? { mode } : {}),
      }),
    onSuccess: invalidate,
  });
}

export function useSetVmDrain() {
  const invalidate = useVmInvalidation();

  return useMutation({
    mutationFn: (input: { vmid: number; enabled: boolean }) =>
      apiPost<DrainResult>(`/vms/${input.vmid}/${input.enabled ? 'drain' : 'undrain'}`),
    onSuccess: invalidate,
  });
}

export function useSyncPowerStates() {
  const invalidate = useVmInvalidation();

  return useMutation({
    mutationFn: () => apiPost<PowerSyncResult>('/vms/sync'),
    onSuccess: invalidate,
  });
}

/* ------------------------------------------------------------ fleet health */

export function useFleetHealth(refreshMs: number | false = false) {
  return useQuery({
    queryKey: queryKeys.fleetHealth,
    queryFn: ({ signal }) => apiGet<FleetHealth>('/hosts/health', signal),
    refetchInterval: refreshMs,
  });
}

/** One host's heartbeat, for the host agent card on its details page. */
export function useHostHealth(hostname: string | undefined) {
  return useQuery({
    queryKey: queryKeys.hostHealth(hostname ?? ''),
    queryFn: ({ signal }) =>
      apiGet<FleetHealth>(`/hosts/health?hostname=${encodeURIComponent(hostname ?? '')}`, signal),
    enabled: Boolean(hostname),
  });
}

/* --------------------------------------------------------------- audit log */

export function useAuditLog(search: string) {
  return useQuery({
    queryKey: queryKeys.audit(search),
    queryFn: ({ signal }) => apiGet<Paged<AuditEntry>>(`/audit${search}`, signal),
    placeholderData: (previous) => previous,
  });
}

/* ------------------------------------------------------ sessions and users */

export function useSessions(refreshMs: number | false = false) {
  return useQuery({
    queryKey: queryKeys.sessions,
    queryFn: ({ signal }) => apiGet<SessionsPage>('/sessions', signal),
    refetchInterval: refreshMs,
  });
}

/** Broker users whose name contains the query. Waits for two characters. */
export function useUserSearch(query: string) {
  const trimmed = query.trim();
  return useQuery({
    queryKey: queryKeys.userSearch(trimmed),
    queryFn: ({ signal }) =>
      apiGet<UserSearchResult>(`/users?q=${encodeURIComponent(trimmed)}&limit=8`, signal),
    enabled: trimmed.length >= 2,
    placeholderData: (previous) => previous,
  });
}

export function useUserDetails(username: string | undefined) {
  return useQuery({
    queryKey: queryKeys.user(username ?? ''),
    queryFn: ({ signal }) => apiGet<BrokerUserDetails>(`/users/${encodeURIComponent(username ?? '')}`, signal),
    enabled: Boolean(username),
  });
}

/** A session action changes the sessions, the user, and everything derived from the VM list. */
function useSessionInvalidation() {
  const queryClient = useQueryClient();
  const invalidateVms = useVmInvalidation();

  return () => {
    invalidateVms();
    void queryClient.invalidateQueries({ queryKey: queryKeys.sessions });
    void queryClient.invalidateQueries({ queryKey: queryKeys.users });
  };
}

export interface SessionTarget {
  hostname: string;
  username: string;
}

export function useSignOutSession() {
  const invalidate = useSessionInvalidation();

  return useMutation({
    mutationFn: ({ hostname, username, returnHost }: SessionTarget & { returnHost?: boolean }) =>
      apiPost<SignOutResult>(
        `/sessions/${encodeURIComponent(hostname)}/${encodeURIComponent(username)}/signout`,
        returnHost ? { returnHost: true } : {},
      ),
    onSuccess: invalidate,
  });
}

export function useMessageSession() {
  const invalidate = useSessionInvalidation();

  return useMutation({
    mutationFn: ({ hostname, username, message }: SessionTarget & { message: string }) =>
      apiPost<MessageResult>(
        `/sessions/${encodeURIComponent(hostname)}/${encodeURIComponent(username)}/message`,
        { message },
      ),
    onSuccess: invalidate,
  });
}

export function useProfileReset() {
  const invalidate = useSessionInvalidation();

  return useMutation({
    mutationFn: ({ username, cancel }: { username: string; cancel?: boolean }) =>
      apiPost<ProfileResetResult>(
        `/users/${encodeURIComponent(username)}/reset-profile${cancel ? '/cancel' : ''}`,
        cancel ? undefined : { confirm: username },
      ),
    onSuccess: invalidate,
  });
}

/** A message for every session, or for every session on the named hosts. */
export function useBroadcast() {
  return useMutation({
    mutationFn: ({ message, hostnames }: { message: string; hostnames?: string[] }) =>
      apiPost<BroadcastResult>('/sessions/broadcast', hostnames ? { message, hostnames } : { message }),
  });
}

/* ---------------------------------------------------------------- scaling */

export function useScalingRules() {
  return useQuery({
    queryKey: queryKeys.rules,
    queryFn: ({ signal }) => apiGet<ScalingRule[]>('/scaling/rules', signal),
  });
}

export function useScalingRule(ruleid: string | undefined) {
  return useQuery({
    queryKey: queryKeys.rule(ruleid ?? ''),
    queryFn: ({ signal }) => apiGet<ScalingRule>(`/scaling/rules/${ruleid}`, signal),
    enabled: Boolean(ruleid),
  });
}

export function useActivityLog(search: string) {
  return useQuery({
    queryKey: queryKeys.activityLog(search),
    queryFn: ({ signal }) => apiGet<Paged<ActivityLogEntry>>(`/scaling/log${search}`, signal),
    placeholderData: (previous) => previous,
  });
}

export function useRuleHistory(search: string) {
  return useQuery({
    queryKey: queryKeys.ruleHistory(search),
    queryFn: ({ signal }) => apiGet<Paged<ScalingRule>>(`/scaling/rules/history${search}`, signal),
    placeholderData: (previous) => previous,
  });
}

function useRuleInvalidation() {
  const queryClient = useQueryClient();
  return () => {
    void queryClient.invalidateQueries({ queryKey: queryKeys.rules });
  };
}

export function useCreateScalingRule() {
  const invalidate = useRuleInvalidation();

  return useMutation({
    mutationFn: (input: ScalingRuleInput) => apiPost<unknown>('/scaling/rules', input),
    onSuccess: invalidate,
  });
}

export function useUpdateScalingRule(ruleid: string) {
  const invalidate = useRuleInvalidation();

  return useMutation({
    mutationFn: (input: ScalingRuleInput) =>
      apiPost<unknown>(`/scaling/rules/${ruleid}/update`, input),
    onSuccess: invalidate,
  });
}

export function useDeleteScalingRule() {
  const invalidate = useRuleInvalidation();

  return useMutation({
    mutationFn: (ruleid: number) => apiPost<unknown>(`/scaling/rules/${ruleid}/delete`),
    onSuccess: invalidate,
  });
}

/* --------------------------------------------------------- host settings */

export function useHostSettings() {
  return useQuery({
    queryKey: queryKeys.hostSettings,
    queryFn: ({ signal }) => apiGet<HostSettingsPage>('/hosts/settings', signal),
  });
}

export function useHostSettingsHistory() {
  return useQuery({
    queryKey: queryKeys.hostSettingsHistory,
    queryFn: ({ signal }) => apiGet<HostSettingsVersion[]>('/hosts/settings/history', signal),
  });
}

export function useSaveHostSettings() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (input: Partial<HostSettings>) =>
      apiPost<SaveSettingsResult>('/hosts/settings', input),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.hostSettings });
    },
  });
}

export function useApplyHostSettings() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (hostname?: string) =>
      apiPost<ApplySettingsResult>('/hosts/settings/apply', hostname ? { hostname } : {}),
    onSuccess: () => {
      // The push updates each host's applied version, which the drift table shows.
      void queryClient.invalidateQueries({ queryKey: queryKeys.hostSettings });
    },
  });
}
