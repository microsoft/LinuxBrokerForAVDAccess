import { Navigate, Outlet, Route, Routes, useParams } from 'react-router-dom';

import { AppShell } from './components/layout/AppShell';
import { Button, ButtonAnchor } from './components/ui/Button';
import { ErrorPanel, LoadingPanel } from './components/ui/Feedback';
import { ToastProvider } from './components/ui/Toast';
import { SessionContext, useSessionQuery, useSignOut } from './hooks/useSession';
import { ApiError, errorMessage } from './lib/api';
import { canManage, sessionSubject } from './lib/queryClient';

import { AccessDenied } from './pages/AccessDenied';
import { Dashboard } from './pages/Dashboard';
import { NotFound } from './pages/NotFound';
import { Profile } from './pages/Profile';
import { SignIn } from './pages/SignIn';
import { AddVm } from './pages/vm/AddVm';
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
      <Route path="/vms/history" element={<VmHistory />} />
      <Route path="/vms/:vmid" element={<VmRoute />}>
        <Route index element={<VmDetails />} />
        <Route path="update" element={<UpdateVmAttributes />} />
      </Route>

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

function VmRoute() {
  const { vmid = '' } = useParams<{ vmid: string }>();
  return /^[1-9]\d*$/.test(vmid) && Number.isSafeInteger(Number(vmid)) ? <Outlet /> : <NotFound />;
}

export function App() {
  const { data: session, isPending, isFetching, isFetchedAfterMount, error, refetch } = useSessionQuery();
  const signOut = useSignOut();

  if (error) {
    return (
      <main className="flex min-h-screen items-center justify-center p-6">
        {error instanceof ApiError && error.status === 401 ? (
          <SignIn expired />
        ) : error instanceof ApiError && error.status === 403 ? (
          <AccessDenied />
        ) : (
          <ErrorPanel
            title="The portal could not start"
            message={errorMessage(error, 'The management portal could not reach its own backend.')}
            action={
              <div className="flex flex-wrap justify-center gap-2">
                <Button onClick={() => void refetch()}>Try again</Button>
                <ButtonAnchor href="/logout" onClick={signOut}>Sign out or switch account</ButtonAnchor>
              </div>
            }
          />
        )}
      </main>
    );
  }

  if (isPending || !isFetchedAfterMount || !session) {
    return (
      <main className="flex min-h-screen items-center justify-center p-6">
        <LoadingPanel label="Starting the portal" />
      </main>
    );
  }

  return (
    <SessionContext.Provider value={{ ...session, authorizationPending: isFetching }}>
      <ToastProvider key={sessionSubject(session)}>
        <AppShell>
          {isFetching ? <LoadingPanel label="Checking administrator access" /> : null}
          {/* Keep unsaved forms mounted during revalidation; their queries are paused. */}
          <div hidden={isFetching}>
            {canManage(session) ? (
              <AuthenticatedRoutes key={sessionSubject(session)} />
            ) : session.authenticated ? (
              <AccessDenied />
            ) : (
              <Routes>
                <Route path="/" element={<SignIn />} />
                <Route path="*" element={<Navigate to="/" replace />} />
              </Routes>
            )}
          </div>
        </AppShell>
      </ToastProvider>
    </SessionContext.Provider>
  );
}
