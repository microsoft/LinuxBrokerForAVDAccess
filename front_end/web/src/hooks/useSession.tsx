import { createContext, useContext } from 'react';
import { useQuery } from '@tanstack/react-query';

import { fetchSession } from '../lib/api';
import { queryKeys } from '../lib/queryClient';
import type { SessionInfo } from '../types/broker';

export const SessionContext = createContext<SessionInfo | null>(null);

/** The signed-in session. Only available inside the app shell, which fetches it. */
export function useSession(): SessionInfo {
  const session = useContext(SessionContext);
  if (!session) {
    throw new Error('useSession must be used inside the app shell.');
  }
  return session;
}

export function useSessionQuery() {
  return useQuery({
    queryKey: queryKeys.session,
    queryFn: ({ signal }) => fetchSession(signal),
    // The CSRF token is tied to the Flask session, so it is refreshed periodically
    // to stay usable on a page that has been open for a long time.
    staleTime: 5 * 60_000,
    retry: 1,
  });
}
