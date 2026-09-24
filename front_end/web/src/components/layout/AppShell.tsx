import type { ReactNode } from 'react';
import { useLocation } from 'react-router-dom';

import { useSession } from '../../hooks/useSession';
import { Notice } from '../ui/Feedback';
import { NavBar } from './NavBar';

export function AppShell({ children }: { children: ReactNode }) {
  const { pathname } = useLocation();
  const session = useSession();

  return (
    <div className="flex min-h-screen flex-col">
      <a
        href="#main-content"
        className="sr-only rounded-br-[var(--radius-glass-sm)] bg-[var(--lb-brand)] px-4 py-2.5 font-semibold text-[var(--lb-on-brand)] focus:not-sr-only focus:absolute focus:top-0 focus:left-0 focus:z-50"
      >
        Skip to main content
      </a>

      <NavBar pathname={pathname} />

      <main id="main-content" tabIndex={-1} className="flex-1 focus:outline-none">
        <div className="mx-auto w-full max-w-[1400px] px-4 py-8">
          {session.authenticated && session.permissions.read && !session.permissions.operate ? (
            <Notice tone="info" className="mb-4">
              Read-only access: your role can view portal data but cannot operate hosts or save changes.
            </Notice>
          ) : null}
          {session.authenticated && session.legacyAccess ? (
            <Notice tone="warning" className="mb-4">
              Access is currently granted by the legacy scope setting. Assign Linux Broker API roles and turn off ALLOW_LEGACY_SCOPE_ACCESS.
            </Notice>
          ) : null}
          {children}
        </div>
      </main>

      <footer className="mt-auto border-t border-[var(--lb-hairline)] py-4">
        <div className="mx-auto flex max-w-[1400px] flex-wrap items-center justify-between gap-2 px-4 text-xs text-muted">
          <span>Linux Broker Management Portal</span>
          <span>v{session.version}</span>
        </div>
      </footer>
    </div>
  );
}
