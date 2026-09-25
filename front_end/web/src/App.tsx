import type { ReactNode } from 'react';
import { Navigate, Route, Routes } from 'react-router-dom';

import { AppShell } from './components/layout/AppShell';
import { ButtonAnchor } from './components/ui/Button';
import { ErrorPanel, LoadingPanel } from './components/ui/Feedback';
import { SessionContext, useSession, useSessionQuery } from './hooks/useSession';
import { errorMessage } from './lib/api';
import type { SessionInfo } from './types/broker';

import { Dashboard } from './pages/Dashboard';
import { NotFound } from './pages/NotFound';
import { Profile } from './pages/Profile';
import { SignIn } from './pages/SignIn';
import { AddVm } from './pages/vm/AddVm';
import { CheckoutVm } from './pages/vm/CheckoutVm';
import { ImportHosts } from './pages/vm/ImportHosts';
import { FleetHealth } from './pages/vm/FleetHealth';
import { UpdateVmAttributes } from './pages/vm/UpdateVmAttributes';
import { VmDetails } from './pages/vm/VmDetails';
import { VmHistory } from './pages/vm/VmHistory';
import { VmList } from './pages/vm/VmList';
import { ActivityLog } from './pages/scaling/ActivityLog';
import { CreateRule } from './pages/scaling/CreateRule';
import { RuleDetails } from './pages/scaling/RuleDetails';
import { RuleHistory } from './pages/scaling/RuleHistory';
import { RuleList } from './pages/scaling/RuleList';
import { ScalingPolicy } from './pages/scaling/ScalingPolicy';
import { ScheduleForm } from './pages/scaling/ScheduleForm';
import { UpdateRule } from './pages/scaling/UpdateRule';
import { HostSettingsPage } from './pages/settings/HostSettings';
import { AuditLog } from './pages/audit/AuditLog';
import { SessionList } from './pages/sessions/SessionList';
import { UserDetails } from './pages/sessions/UserDetails';
import { MaintenanceRunDetails } from './pages/maintenance/MaintenanceRunDetails';
import { MaintenanceRuns } from './pages/maintenance/MaintenanceRuns';
import { NewMaintenanceRun } from './pages/maintenance/NewMaintenanceRun';

/**
 * Routes deliberately mirror the URLs the Jinja portal served, so existing
 * bookmarks and links in runbooks keep resolving after the rewrite.
 */
function NoAccessPage() {
  return (
    <ErrorPanel
      title="No access"
      message="Your account needs the Reader, Operator or Admin role for the Linux Broker API. Ask an administrator to assign a portal role."
      action={
        <ButtonAnchor href="/logout" variant="primary" icon="box-arrow-right">
          Sign out
        </ButtonAnchor>
      }
    />
  );
}

export function NoPermissionPanel({ action = 'use this page' }: { action?: string }) {
  return (
    <ErrorPanel
      title="Permission required"
      message={`Your current Linux Broker API role does not allow you to ${action}.`}
    />
  );
}

function RequireAdmin({ children }: { children: ReactNode }) {
  const session = useSession();
  return session.permissions.admin ? <>{children}</> : <NoPermissionPanel />;
}

function AuthenticatedRoutes() {
  return (
    <Routes>
      <Route path="/" element={<Dashboard />} />
      <Route path="/profile" element={<Profile />} />

      <Route path="/vms" element={<VmList />} />
      <Route path="/vms/add" element={<RequireAdmin><AddVm /></RequireAdmin>} />
      <Route path="/vms/checkout" element={<RequireAdmin><CheckoutVm /></RequireAdmin>} />
      <Route path="/vms/import" element={<RequireAdmin><ImportHosts /></RequireAdmin>} />
      <Route path="/vms/history" element={<VmHistory />} />
      <Route path="/vms/health" element={<FleetHealth />} />
      <Route path="/vms/maintenance" element={<MaintenanceRuns />} />
      <Route path="/vms/maintenance/new" element={<RequireAdmin><NewMaintenanceRun /></RequireAdmin>} />
      <Route path="/vms/maintenance/:runid" element={<MaintenanceRunDetails />} />
      <Route path="/vms/:vmid" element={<VmDetails />} />
      <Route path="/vms/:vmid/update" element={<RequireAdmin><UpdateVmAttributes /></RequireAdmin>} />

      <Route path="/scaling" element={<ScalingPolicy />} />
      <Route path="/scaling/schedules/new" element={<RequireAdmin><ScheduleForm /></RequireAdmin>} />
      <Route path="/scaling/schedules/:scheduleid" element={<RequireAdmin><ScheduleForm /></RequireAdmin>} />
      <Route path="/scaling/rules" element={<RuleList />} />
      <Route path="/scaling/rules/create" element={<RequireAdmin><CreateRule /></RequireAdmin>} />
      <Route path="/scaling/rules/history" element={<RuleHistory />} />
      <Route path="/scaling/rules/:ruleid" element={<RuleDetails />} />
      <Route path="/scaling/rules/:ruleid/update" element={<RequireAdmin><UpdateRule /></RequireAdmin>} />
      <Route path="/scaling/log" element={<ActivityLog />} />

      <Route path="/settings/hosts" element={<HostSettingsPage />} />

      <Route path="/sessions" element={<SessionList />} />
      <Route path="/users/:username" element={<UserDetails />} />

      <Route path="/audit" element={<AuditLog />} />

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
        {session.authenticated && session.permissionsUnavailable ? (
          <ErrorPanel
            title="Permissions unavailable"
            message="The portal could not verify your Linux Broker API roles. Try again; if this persists, ask an administrator to check the Broker API."
            action={
              <button type="button" className="lb-btn px-3.5 py-2 text-sm" onClick={() => void refetch()}>
                Retry
              </button>
            }
          />
        ) : session.authenticated && !session.permissions.read ? (
          <NoAccessPage />
        ) : session.authenticated ? (
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
