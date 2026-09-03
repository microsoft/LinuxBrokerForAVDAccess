import { useState } from 'react';
import { Link } from 'react-router-dom';

import { classNames } from '../../lib/format';
import { useSession } from '../../hooks/useSession';
import { Icon } from '../Icon';
import type { IconName } from '../Icon';
import { ThemeToggle } from './ThemeToggle';

interface NavItem {
  to: string;
  label: string;
  icon: IconName;
  /** Additional path prefixes that belong to this section. */
  match?: string[];
}

const NAV_ITEMS: NavItem[] = [
  { to: '/', label: 'Dashboard', icon: 'gauge' },
  { to: '/vms', label: 'VM Management', icon: 'server' },
  { to: '/scaling/rules', label: 'Scaling Management', icon: 'sliders', match: ['/scaling'] },
  { to: '/settings/hosts', label: 'Host Settings', icon: 'wrench' },
];

/**
 * Whether a nav item owns the current path.
 *
 * A section covers more than the page it links to: Scaling Management points at
 * /scaling/rules but also owns /scaling/log, which is why `match` exists. This is
 * deliberately not React Router's `NavLink`, whose matching is limited to the `to`
 * path and which overrides any `aria-current` passed to it.
 */
function isActive(item: NavItem, pathname: string) {
  if (item.to === '/') {
    // Every path starts with '/', so the dashboard needs an exact match.
    return pathname === '/';
  }
  const prefixes = item.match ?? [item.to];
  return prefixes.some((prefix) => pathname === prefix || pathname.startsWith(`${prefix}/`));
}

const LINK_BASE =
  'flex items-center gap-1.5 rounded-[var(--radius-glass-sm)] px-3 py-2 text-sm font-medium no-underline transition-colors';

export function NavBar({ pathname }: { pathname: string }) {
  const session = useSession();
  const [open, setOpen] = useState(false);

  const linkClass = (active: boolean) =>
    classNames(LINK_BASE, active ? 'bg-white/20 text-white' : 'text-white/85 hover:bg-white/12 hover:text-white');

  return (
    <nav
      aria-label="Main navigation"
      className="sticky top-0 z-30 border-b border-white/10 bg-[var(--lb-brand)] shadow-lg backdrop-blur-md dark:bg-[#0d1e33]"
    >
      <div className="mx-auto flex max-w-[1400px] flex-wrap items-center gap-2 px-4 py-2">
        <Link
          to="/"
          className="flex items-center gap-2 text-base font-semibold tracking-tight text-white no-underline"
        >
          <Icon name="server" size={20} />
          <span>Linux Broker</span>
        </Link>

        <button
          type="button"
          className="ml-auto rounded-[var(--radius-glass-sm)] border border-white/25 p-2 text-white lg:hidden"
          aria-expanded={open}
          aria-controls="lb-nav"
          aria-label="Toggle navigation"
          onClick={() => setOpen((current) => !current)}
        >
          <Icon name={open ? 'x' : 'list'} size={16} />
        </button>

        <div
          id="lb-nav"
          className={classNames(
            'w-full flex-col gap-1 lg:ml-4 lg:flex lg:w-auto lg:flex-1 lg:flex-row lg:items-center',
            open ? 'flex' : 'hidden',
          )}
        >
          {session.authenticated ? (
            <ul className="m-0 flex list-none flex-col gap-1 p-0 lg:flex-row lg:items-center">
              {NAV_ITEMS.map((item) => {
                const active = isActive(item, pathname);
                return (
                  <li key={item.to}>
                    <Link
                      to={item.to}
                      className={linkClass(active)}
                      aria-current={active ? 'page' : undefined}
                      onClick={() => setOpen(false)}
                    >
                      <Icon name={item.icon} size={16} />
                      {item.label}
                    </Link>
                  </li>
                );
              })}
            </ul>
          ) : null}

          <ul className="m-0 flex list-none flex-col gap-1 p-0 lg:ml-auto lg:flex-row lg:items-center">
            <li className="flex items-center px-1 py-1">
              <ThemeToggle />
            </li>

            {session.authenticated ? (
              <>
                <li>
                  <Link
                    to="/profile"
                    className={linkClass(pathname === '/profile')}
                    aria-current={pathname === '/profile' ? 'page' : undefined}
                    onClick={() => setOpen(false)}
                  >
                    <Icon name="person" size={16} />
                    <span className="max-w-[16ch] truncate">
                      {session.user?.name ?? 'Profile'}
                    </span>
                  </Link>
                </li>
                <li>
                  {/* A full navigation: Flask clears the session and redirects to Entra ID. */}
                  <a href="/logout" className={linkClass(false)}>
                    <Icon name="box-arrow-right" size={16} />
                    Sign out
                  </a>
                </li>
              </>
            ) : (
              <li>
                <a href="/login" className={linkClass(false)}>
                  <Icon name="box-arrow-right" size={16} />
                  Sign in
                </a>
              </li>
            )}
          </ul>
        </div>
      </div>
    </nav>
  );
}
