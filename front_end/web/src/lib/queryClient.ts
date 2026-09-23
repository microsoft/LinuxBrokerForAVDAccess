import { QueryClient } from '@tanstack/react-query';

import { ApiError, isAuthorizationError } from './api';
import type { SessionInfo } from '../types/broker';

export function canManage(session: SessionInfo | null | undefined): boolean {
  return session?.authenticated === true && !!session.subject && session.capabilities?.manage === true;
}

export function sessionSubject(session: SessionInfo | undefined): string | null {
  return session?.authenticated && session.subject
    ? JSON.stringify([session.subject.tenantId.toLowerCase(), session.subject.objectId.toLowerCase()])
    : null;
}

export function clearManagementCache(queryClient: QueryClient) {
  // Removal also cancels query fetches; a late response cannot repopulate the cache.
  queryClient.removeQueries({ predicate: (query) => query.queryKey[0] !== 'session' });
  queryClient.getMutationCache().clear();
}

export function createQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: {
        // Broker state changes behind the portal's back, so a short staleness
        // window plus refetch-on-focus keeps a long-lived tab honest without
        // hammering the API.
        staleTime: 15_000,
        // The session revalidates first on focus. Management queries remount only
        // after that check succeeds, rather than racing it with stale authority.
        refetchOnWindowFocus: false,
        refetchOnReconnect: false,
        retry: (failureCount, error) => {
          // A rejected request will keep being rejected; only retry transport and
          // upstream failures, and only briefly.
          if (isAuthorizationError(error) || (error instanceof ApiError && error.status < 500)) {
            return false;
          }
          return failureCount < 2;
        },
      },
      mutations: {
        retry: false,
      },
    },
  });
}

export const queryKeys = {
  session: ['session'] as const,
  dashboard: ['dashboard'] as const,
  vms: ['vms'] as const,
  vm: (vmid: number | string) => ['vms', String(vmid)] as const,
  vmHistory: (search: string) => ['vms', 'history', search] as const,
  rules: ['scaling', 'rules'] as const,
  rule: (ruleid: number | string) => ['scaling', 'rules', String(ruleid)] as const,
  ruleHistory: (search: string) => ['scaling', 'rules', 'history', search] as const,
  activityLog: (search: string) => ['scaling', 'log', search] as const,
  hostSettings: ['hosts', 'settings'] as const,
};
