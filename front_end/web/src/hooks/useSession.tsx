import { createContext, useContext, useEffect, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';

import { ApiError, fetchSession, isAuthorizationError, setCsrfToken } from '../lib/api';
import { canManage, clearManagementCache, queryKeys, sessionSubject } from '../lib/queryClient';
import type { SessionInfo } from '../types/broker';

type PortalSession = SessionInfo & { authorizationPending?: boolean };

export const SessionContext = createContext<PortalSession | null>(null);

/** The signed-in session. Only available inside the app shell, which fetches it. */
export function useSession(): PortalSession {
  const session = useContext(SessionContext);
  if (!session) {
    throw new Error('useSession must be used inside the app shell.');
  }
  return session;
}

export function useManagementAccess(): boolean {
  const session = useSession();
  return canManage(session) && !session.authorizationPending;
}

export function useSessionQuery() {
  const queryClient = useQueryClient();
  const [accessError, setAccessError] = useState<ApiError | null>(null);

  useEffect(() => {
    function deny(error: unknown) {
      if (!isAuthorizationError(error)) return;
      setAccessError(error);
      setCsrfToken(null);
      void queryClient.cancelQueries({ queryKey: queryKeys.session });
      clearManagementCache(queryClient);
    }

    const unsubscribeQueries = queryClient.getQueryCache().subscribe((event) => {
      if (event.type === 'updated' && event.action.type === 'error'
          && event.query.queryKey[0] !== 'session') {
        deny(event.query.state.error);
      }
    });
    const unsubscribeMutations = queryClient.getMutationCache().subscribe((event) => {
      // Removed mutations may still settle after logout or an account change.
      if (event.type === 'updated' && event.action.type === 'error'
          && queryClient.getMutationCache().getAll().includes(event.mutation)) {
        deny(event.mutation.state.error);
      }
    });
    return () => {
      unsubscribeQueries();
      unsubscribeMutations();
    };
  }, [queryClient]);

  const query = useQuery({
    queryKey: queryKeys.session,
    queryFn: async ({ signal }) => {
      void queryClient.cancelQueries({ predicate: (query) => query.queryKey[0] !== 'session' });
      try {
        const next = await fetchSession(signal);
        const previous = queryClient.getQueryData<SessionInfo>(queryKeys.session);
        if (!canManage(next) || !canManage(previous) || sessionSubject(previous) !== sessionSubject(next)) {
          clearManagementCache(queryClient);
        }
        return next;
      } catch (error) {
        if (!signal.aborted) {
          setCsrfToken(null);
          clearManagementCache(queryClient);
        }
        throw error;
      }
    },
    enabled: accessError === null,
    staleTime: 0,
    refetchOnMount: 'always',
    refetchOnWindowFocus: 'always',
    refetchOnReconnect: 'always',
    refetchInterval: 60_000,
    retry: false,
  });

  return {
    ...query,
    error: accessError ?? query.error,
    refetch: () => {
      setAccessError(null);
      return query.refetch();
    },
  };
}

export function useSignOut() {
  const queryClient = useQueryClient();
  return () => {
    setCsrfToken(null);
    queryClient.clear();
  };
}
