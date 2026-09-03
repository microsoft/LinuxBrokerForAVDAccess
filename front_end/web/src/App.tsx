import { Navigate, Route, Routes } from 'react-router-dom';

import { AppShell } from './components/layout/AppShell';
import { ErrorPanel, LoadingPanel } from './components/ui/Feedback';
import { SessionContext, useSessionQuery } from './hooks/useSession';
import { errorMessage } from './lib/api';
import type { SessionInfo } from './types/broker';

import { Dashboard } from './pages/Dashboard';
import { NotFound } from './pages/NotFound';
import { Profile } from './pages/Profile';
import { SignIn } from './pages/SignIn';
import { AddVm } from './pages/vm/AddVm';
import { CheckoutVm } from './pages/vm/CheckoutVm';
import { UpdateVmAttributes } from './pages/vm/UpdateVmAttributes';
import { VmDetails } from './pages/vm/VmDetails';
import { VmHistory } from './pages/vm/VmHistory';
import { VmList } from './pages/vm/VmList';
import { ActivityLog } from './pages/scaling/ActivityLog';
import { CreateRule } from './pages/scaling/CreateRule';
import { RuleDetails } from './pages/scaling/RuleDetails';
import { RuleHistory } from './pages/scaling/RuleHistory';
import { RuleList } from './pages/scaling/RuleList';
import { UpdateRule } from './pages/scaling/UpdateRule';
import { HostSettingsPage } from './pages/settings/HostSettings';

/**
 * Routes deliberately mirror the URLs the Jinja portal served, so existing
 * bookmarks and links in runbooks keep resolving after the rewrite.
 */
function AuthenticatedRoutes() {
  return (
    <Routes>
      <Route path="/" element={<Dashboard />} />
      <Route path="/profile" element={<Profile />} />

      <Route path="/vms" element={<VmList />} />
      <Route path="/vms/add" element={<AddVm />} />
      <Route path="/vms/checkout" element={<CheckoutVm />} />
      <Route path="/vms/history" element={<VmHistory />} />
      <Route path="/vms/:vmid" element={<VmDetails />} />
      <Route path="/vms/:vmid/update" element={<UpdateVmAttributes />} />

      <Route path="/scaling/rules" element={<RuleList />} />
      <Route path="/scaling/rules/create" element={<CreateRule />} />
      <Route path="/scaling/rules/history" element={<RuleHistory />} />
      <Route path="/scaling/rules/:ruleid" element={<RuleDetails />} />
      <Route path="/scaling/rules/:ruleid/update" element={<UpdateRule />} />
      <Route path="/scaling/log" element={<ActivityLog />} />

      <Route path="/settings/hosts" element={<HostSettingsPage />} />

      <Route path="*" element={<NotFound />} />
    </Routes>
  );
}

export function App() {
  const { data: session, isPending, error, refetch } = useSessionQuery();

  if (isPending) {
    return (
      <div className="flex min-h-screen items-center justify-center p-6">
        <LoadingPanel label="Starting the portal" />
      </div>
    );
  }

  if (error || !session) {
    return (
      <div className="flex min-h-screen items-center justify-center p-6">
        <ErrorPanel
          title="The portal could not start"
          message={errorMessage(error, 'The management portal could not reach its own backend.')}
          action={
            <button type="button" className="lb-btn px-3.5 py-2 text-sm" onClick={() => void refetch()}>
              Try again
            </button>
          }
        />
      </div>
    );
  }

  return (
    <SessionContext.Provider value={session as SessionInfo}>
      <AppShell>
        {session.authenticated ? (
          <AuthenticatedRoutes />
        ) : (
          // Everything collapses to the landing page while signed out, rather than
          // rendering a page frame that cannot load any data.
          <Routes>
            <Route path="/" element={<SignIn />} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        )}
      </AppShell>
    </SessionContext.Provider>
  );
}
