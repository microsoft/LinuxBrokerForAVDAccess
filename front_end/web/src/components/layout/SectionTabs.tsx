import { Link } from 'react-router-dom';

import { useCan } from '../../hooks/useSession';
import { classNames } from '../../lib/format';

interface Tab {
  to: string;
  label: string;
  /** Whether the tab owns the path; by default the path is the tab's or below it. */
  owns?: (pathname: string) => boolean;
  /** Shown only to administrators. */
  admin?: boolean;
}

interface Section {
  name: string;
  prefix: string;
  tabs: Tab[];
}

const HOST_PAGES = /^\/vms\/(health|maintenance|history|import)(\/|$)/;

/** The pages of each section, shown as tabs under the main navigation. */
export const SECTIONS: Section[] = [
  {
    name: 'Hosts',
    prefix: '/vms',
    tabs: [
      { to: '/vms', label: 'All hosts', owns: (pathname) => !HOST_PAGES.test(pathname) },
      { to: '/vms/health', label: 'Fleet health' },
      { to: '/vms/maintenance', label: 'Maintenance' },
      { to: '/vms/history', label: 'History' },
      { to: '/vms/import', label: 'Import', admin: true },
    ],
  },
  {
    name: 'Scaling',
    prefix: '/scaling',
    tabs: [
      {
        to: '/scaling',
        label: 'Policy',
        owns: (pathname) => !/^\/scaling\/(log|rules\/history)(\/|$)/.test(pathname),
      },
      { to: '/scaling/log', label: 'Activity log' },
      { to: '/scaling/rules/history', label: 'Rule history' },
    ],
  },
];

function owns(tab: Tab, pathname: string) {
  return tab.owns ? tab.owns(pathname) : pathname === tab.to || pathname.startsWith(`${tab.to}/`);
}

export function sectionFor(pathname: string) {
  return SECTIONS.find((section) => pathname === section.prefix || pathname.startsWith(`${section.prefix}/`)) ?? null;
}

/** Tabs for the pages of the current section, so each is one click away. */
export function SectionTabs({ pathname }: { pathname: string }) {
  const can = useCan();
  const section = sectionFor(pathname);
  if (!section) {
    return null;
  }

  return (
    <nav aria-label={`${section.name} pages`} className="mb-5 overflow-x-auto border-b border-[var(--lb-hairline)]">
      <ul className="m-0 flex list-none gap-1 p-0">
        {section.tabs.filter((tab) => !tab.admin || can.admin).map((tab) => {
          const active = owns(tab, pathname);
          return (
            <li key={tab.to}>
              <Link
                to={tab.to}
                aria-current={active ? 'page' : undefined}
                className={classNames(
                  '-mb-px block border-b-2 px-3 py-2 text-sm font-medium whitespace-nowrap no-underline transition-colors',
                  active
                    ? 'border-[var(--lb-brand)] text-ink'
                    : 'border-transparent text-muted hover:border-[var(--lb-hairline)] hover:text-ink',
                )}
              >
                {tab.label}
              </Link>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
