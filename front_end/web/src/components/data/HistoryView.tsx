import type { ReactNode } from 'react';

import type { Paged } from '../../types/broker';
import type { HistoryQuery } from '../../hooks/useHistoryQuery';
import { EmptyState, ErrorPanel, LoadingPanel, Spinner } from '../ui/Feedback';
import { DataTable } from './DataTable';
import type { Column } from './DataTable';
import { HistoryFilters } from './HistoryFilters';
import { Pagination, PerPageSelect } from './Pagination';

export interface HistoryViewProps<T> {
  query: HistoryQuery;
  data: Paged<T> | undefined;
  isPending: boolean;
  isFetching: boolean;
  error: unknown;
  errorText: string;
  columns: Array<Column<T>>;
  rowKey: (row: T) => string | number;
  emptyTitle: string;
  emptyMessage: string;
  emptyIcon?: 'clock' | 'list' | 'activity';
  noun: string;
  caption: string;
  children?: ReactNode;
}

/**
 * Filter bar, table and pager for the three history views.
 *
 * VM history, the scaling activity log and rule history differ only by their
 * columns, so the surrounding plumbing lives here rather than being repeated.
 */
export function HistoryView<T>({
  query,
  data,
  isPending,
  isFetching,
  error,
  errorText,
  columns,
  rowKey,
  emptyTitle,
  emptyMessage,
  emptyIcon = 'clock',
  noun,
  caption,
}: HistoryViewProps<T>) {
  const rows = data?.items ?? [];

  return (
    <>
      <HistoryFilters value={query.filters} onApply={query.setFilters} />

      {isPending ? <LoadingPanel label={`Loading ${noun}`} /> : null}

      {error ? <ErrorPanel message={errorText} /> : null}

      {!isPending && !error && rows.length === 0 ? (
        <EmptyState title={emptyTitle} message={emptyMessage} icon={emptyIcon} />
      ) : null}

      {rows.length > 0 ? (
        <>
          <DataTable
            columns={columns}
            rows={rows}
            rowKey={rowKey}
            searchable
            searchPlaceholder="Search this page…"
            noun={noun}
            emptyMessage="No matching records on this page. Try a different search term or page."
            caption={caption}
          />

          <div className="mt-4 flex flex-wrap items-center justify-between gap-3">
            <div className="flex items-center gap-3">
              <PerPageSelect perPage={query.perPage} onPerPageChange={query.setPerPage} />
              <span className="text-xs text-muted">
                {data ? `${data.total} ${noun} total` : null}
              </span>
              {isFetching ? <Spinner label="" /> : null}
            </div>
            <Pagination
              page={query.page}
              totalPages={data?.totalPages ?? 0}
              onPageChange={query.setPage}
            />
          </div>
        </>
      ) : null}
    </>
  );
}
