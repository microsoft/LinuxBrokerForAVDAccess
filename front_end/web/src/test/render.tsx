import type { ReactElement, ReactNode } from 'react';
import { render } from '@testing-library/react';
import type { RenderOptions } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';

import { ToastProvider } from '../components/ui/Toast';
import { SessionContext } from '../hooks/useSession';
import type { SessionInfo } from '../types/broker';

export const TEST_SESSION: SessionInfo = {
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

interface Options extends Omit<RenderOptions, 'wrapper'> {
  route?: string;
  session?: SessionInfo;
}

/** Render a component inside the providers the real app supplies. */
export function renderWithProviders(ui: ReactElement, options: Options = {}) {
  const { route = '/', session = TEST_SESSION, ...rest } = options;

  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });

  function Wrapper({ children }: { children: ReactNode }) {
    return (
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={[route]}>
          <SessionContext.Provider value={session}>
            <ToastProvider>{children}</ToastProvider>
          </SessionContext.Provider>
        </MemoryRouter>
      </QueryClientProvider>
    );
  }

  return render(ui, { wrapper: Wrapper, ...rest });
}
