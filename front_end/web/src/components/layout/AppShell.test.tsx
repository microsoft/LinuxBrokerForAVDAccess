import { describe, expect, it } from 'vitest';
import { screen } from '@testing-library/react';

import { AppShell } from './AppShell';
import { renderWithProviders, TEST_SESSION } from '../../test/render';

const ANONYMOUS = { ...TEST_SESSION, authenticated: false, user: null };

function renderShell(route: string, session = TEST_SESSION) {
  return renderWithProviders(<AppShell>page body</AppShell>, { route, session });
}

describe('AppShell', () => {
  it('exposes a skip link before the navigation', () => {
    renderShell('/');
    const skip = screen.getByRole('link', { name: 'Skip to main content' });
    expect(skip).toHaveAttribute('href', '#main-content');
  });

  it('renders the page inside a focusable main landmark', () => {
    renderShell('/');
    const main = screen.getByRole('main');
    expect(main).toHaveAttribute('id', 'main-content');
    expect(main).toHaveTextContent('page body');
  });

  it('shows the portal version in the footer', () => {
    renderShell('/');
    expect(screen.getByText(`v${TEST_SESSION.version}`)).toBeInTheDocument();
  });

  it('offers the management sections and the signed-in account when authenticated', () => {
    renderShell('/');
    for (const label of ['Dashboard', 'VM Management', 'Scaling Management', 'Host Settings']) {
      expect(screen.getByRole('link', { name: label })).toBeInTheDocument();
    }
    expect(screen.getByRole('link', { name: /Test Operator/ })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /Sign out/ })).toHaveAttribute('href', '/logout');
  });

  it('offers only sign in when signed out', () => {
    renderShell('/', ANONYMOUS);
    expect(screen.queryByRole('link', { name: 'VM Management' })).not.toBeInTheDocument();
    // A full navigation to Flask, which starts the MSAL redirect.
    expect(screen.getByRole('link', { name: /Sign in/ })).toHaveAttribute('href', '/login');
  });

  it.each([
    ['/', 'Dashboard'],
    ['/vms', 'VM Management'],
    ['/vms/12/update', 'VM Management'],
    ['/scaling/rules', 'Scaling Management'],
    ['/scaling/log', 'Scaling Management'],
    ['/scaling/rules/history', 'Scaling Management'],
    ['/settings/hosts', 'Host Settings'],
  ])('marks %s as the current page under %s', (route, label) => {
    renderShell(route);
    expect(screen.getByRole('link', { name: label })).toHaveAttribute('aria-current', 'page');
  });

  it('does not mark the dashboard current on a sub-page', () => {
    // '/' is a prefix of every path, so it needs an exact match rather than the
    // prefix match the other sections use.
    renderShell('/vms');
    expect(screen.getByRole('link', { name: 'Dashboard' })).not.toHaveAttribute('aria-current');
  });

  it('falls back to a generic profile label when the account has no name', () => {
    renderShell('/', { ...TEST_SESSION, user: { ...TEST_SESSION.user!, name: null } });
    expect(screen.getByRole('link', { name: /Profile/ })).toBeInTheDocument();
  });
});
