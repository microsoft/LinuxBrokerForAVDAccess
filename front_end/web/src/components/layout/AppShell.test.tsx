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
    for (const label of ['Overview', 'Hosts', 'Sessions', 'Scaling', 'Settings', 'Audit']) {
      expect(screen.getByRole('link', { name: label })).toBeInTheDocument();
    }
    expect(screen.getByRole('link', { name: /Test Operator/ })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: /Sign out/ })).toHaveAttribute('href', '/logout');
  });

  it('offers only sign in when signed out', () => {
    renderShell('/', ANONYMOUS);
    expect(screen.queryByRole('link', { name: 'Hosts' })).not.toBeInTheDocument();
    // A full navigation to Flask, which starts the MSAL redirect.
    expect(screen.getByRole('link', { name: /Sign in/ })).toHaveAttribute('href', '/login');
  });

  it.each([
    ['/', 'Overview'],
    ['/vms', 'Hosts'],
    ['/vms/12/update', 'Hosts'],
    ['/vms/maintenance/3', 'Hosts'],
    ['/scaling/rules', 'Scaling'],
    ['/scaling/log', 'Scaling'],
    ['/scaling/rules/history', 'Scaling'],
    ['/settings/hosts', 'Settings'],
    ['/users/alice', 'Sessions'],
  ])('marks %s as the current page under %s', (route, label) => {
    renderShell(route);
    expect(screen.getByRole('link', { name: label })).toHaveAttribute('aria-current', 'page');
  });

  it('does not mark the overview current on a sub-page', () => {
    // '/' is a prefix of every path, so it needs an exact match rather than the
    // prefix match the other sections use.
    renderShell('/vms');
    expect(screen.getByRole('link', { name: 'Overview' })).not.toHaveAttribute('aria-current');
  });

  it.each([
    ['/vms', 'Hosts pages', 'All hosts'],
    ['/vms/12', 'Hosts pages', 'All hosts'],
    ['/vms/health', 'Hosts pages', 'Fleet health'],
    ['/vms/maintenance/new', 'Hosts pages', 'Maintenance'],
    ['/vms/history', 'Hosts pages', 'History'],
    ['/vms/import', 'Hosts pages', 'Import'],
    ['/scaling', 'Scaling pages', 'Policy'],
    ['/scaling/schedules/4', 'Scaling pages', 'Policy'],
    ['/scaling/rules/2', 'Scaling pages', 'Policy'],
    ['/scaling/log', 'Scaling pages', 'Activity log'],
    ['/scaling/rules/history', 'Scaling pages', 'Rule history'],
  ])('shows %s under the %s tab %s', (route, section, tab) => {
    renderShell(route);
    const tabs = screen.getByRole('navigation', { name: section });
    const current = Array.from(tabs.querySelectorAll('[aria-current="page"]')).map((link) => link.textContent);
    expect(current).toEqual([tab]);
  });

  it('shows no section tabs outside a section or when signed out', () => {
    renderShell('/sessions');
    expect(screen.queryByRole('navigation', { name: /pages$/ })).not.toBeInTheDocument();
    renderShell('/vms', ANONYMOUS);
    expect(screen.queryByRole('navigation', { name: 'Hosts pages' })).not.toBeInTheDocument();
  });

  it('falls back to a generic profile label when the account has no name', () => {
    renderShell('/', { ...TEST_SESSION, user: { ...TEST_SESSION.user!, name: null } });
    expect(screen.getByRole('link', { name: /Profile/ })).toBeInTheDocument();
  });
});
