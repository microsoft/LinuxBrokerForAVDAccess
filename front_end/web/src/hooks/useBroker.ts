import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';

import { apiGet, apiPost } from '../lib/api';
import { queryKeys } from '../lib/queryClient';
import type {
  ActivityLogEntry,
  ApplySettingsResult,
  Dashboard,
  HostSettings,
  HostSettingsPage,
  Paged,
  SaveSettingsResult,
  ScalingRule,
  ScalingRuleInput,
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
 * Any VM mutation can change the dashboard counters and the host settings drift
 * table as well as the list itself, so they are refreshed together.
 */
function useVmInvalidation() {
  const queryClient = useQueryClient();

  return () => {
    void queryClient.invalidateQueries({ queryKey: queryKeys.vms });
    void queryClient.invalidateQueries({ queryKey: queryKeys.dashboard });
    void queryClient.invalidateQueries({ queryKey: queryKeys.hostSettings });
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
    mutationFn: (vmid: number) => apiPost<unknown>(`/vms/${vmid}/return`),
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
