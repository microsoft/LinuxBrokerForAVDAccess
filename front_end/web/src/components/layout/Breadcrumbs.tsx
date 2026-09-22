import type { ReactNode } from 'react';
import { Link } from 'react-router-dom';

import { Icon } from '../Icon';

export interface Crumb {
  label: string;
  to?: string;
}

export function Breadcrumbs({ items }: { items: Crumb[] }) {
  return (
    <nav aria-label="Breadcrumb" className="mb-3">
      <ol className="m-0 flex list-none flex-wrap items-center gap-1 p-0 text-xs text-muted">
        {items.map((item, index) => {
          const last = index === items.length - 1;
          return (
            <li key={`${item.label}-${index}`} className="flex items-center gap-1">
              {index > 0 ? <Icon name="chevron-right" size={12} className="opacity-60" /> : null}
              {item.to && !last ? (
                <Link to={item.to} className="no-underline hover:underline">
                  {item.label}
                </Link>
              ) : (
                <span aria-current={last ? 'page' : undefined} className="text-ink">
                  {item.label}
                </span>
              )}
            </li>
          );
        })}
      </ol>
    </nav>
  );
}

export interface DetailListProps {
  items: Array<{ label: string; value: ReactNode }>;
}

export function DetailList({ items }: DetailListProps) {
  return (
    <dl className="m-0 divide-y divide-[var(--lb-hairline)]">
      {items.map((item) => (
        <div key={item.label} className="grid grid-cols-1 gap-1 py-3 sm:grid-cols-3 sm:gap-4">
          <dt className="text-sm text-muted">{item.label}</dt>
          <dd className="m-0 text-sm sm:col-span-2">{item.value}</dd>
        </div>
      ))}
    </dl>
  );
}
