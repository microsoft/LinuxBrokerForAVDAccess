import { classNames } from '../../lib/format';
import { Icon } from '../Icon';

export type PageItem = number | 'gap';

/**
 * Windowed page list: first, current +/- `window`, last, with gaps collapsed.
 *
 * Rendering every page number produced hundreds of links once the "No limit"
 * filter was used, so the window is deliberately small and pinned by a test.
 */
export function paginationWindow(page: number, totalPages: number, window = 2): PageItem[] {
  if (!totalPages || totalPages < 1) {
    return [];
  }

  const pages: number[] = [];
  for (let candidate = 1; candidate <= totalPages; candidate += 1) {
    if (
      candidate === 1 ||
      candidate === totalPages ||
      (candidate >= page - window && candidate <= page + window)
    ) {
      pages.push(candidate);
    }
  }

  const items: PageItem[] = [];
  let previous = 0;
  for (const candidate of pages) {
    if (previous && candidate > previous + 1) {
      items.push('gap');
    }
    items.push(candidate);
    previous = candidate;
  }

  return items;
}

export interface PaginationProps {
  page: number;
  totalPages: number;
  onPageChange: (page: number) => void;
  window?: number;
}

export function Pagination({ page, totalPages, onPageChange, window = 2 }: PaginationProps) {
  if (!totalPages || totalPages <= 1) {
    return null;
  }

  const items = paginationWindow(page, totalPages, window);
  const atStart = page <= 1;
  const atEnd = page >= totalPages;

  const stepClass =
    'lb-btn border-[var(--lb-hairline)] bg-[var(--lb-glass-bg-strong)] px-2 py-1.5 text-xs disabled:opacity-40';

  return (
    <nav aria-label="Pagination">
      <ul className="m-0 flex list-none flex-wrap items-center gap-1 p-0">
        <li>
          <button
            type="button"
            className={stepClass}
            onClick={() => onPageChange(page - 1)}
            disabled={atStart}
            aria-label="Previous page"
          >
            <Icon name="chevron-left" size={14} />
          </button>
        </li>

        {items.map((item, index) =>
          item === 'gap' ? (
            <li key={`gap-${index}`} className="px-1.5 text-xs text-subtle" aria-hidden>
              &hellip;
            </li>
          ) : (
            <li key={item}>
              <button
                type="button"
                onClick={() => onPageChange(item)}
                aria-current={item === page ? 'page' : undefined}
                aria-label={`Page ${item}`}
                className={classNames(
                  'lb-btn min-w-8 px-2 py-1.5 text-xs',
                  item === page
                    ? 'border-transparent bg-[var(--lb-brand)] text-[var(--lb-on-brand)]'
                    : 'border-[var(--lb-hairline)] bg-[var(--lb-glass-bg-strong)] text-ink hover:border-[var(--lb-brand)]',
                )}
              >
                {item}
              </button>
            </li>
          ),
        )}

        <li>
          <button
            type="button"
            className={stepClass}
            onClick={() => onPageChange(page + 1)}
            disabled={atEnd}
            aria-label="Next page"
          >
            <Icon name="chevron-right" size={14} />
          </button>
        </li>
      </ul>
    </nav>
  );
}

export const PER_PAGE_OPTIONS = [10, 25, 50, 100];

export interface PerPageSelectProps {
  perPage: number;
  onPerPageChange: (perPage: number) => void;
  options?: number[];
}

export function PerPageSelect({
  perPage,
  onPerPageChange,
  options = PER_PAGE_OPTIONS,
}: PerPageSelectProps) {
  // Include the current value when it is not a preset, so a hand-edited
  // ?per_page= does not leave the control showing nothing.
  const choices = options.includes(perPage) ? options : [...options, perPage].sort((a, b) => a - b);

  return (
    <div className="flex items-center gap-2">
      <label htmlFor="lb-per-page" className="text-xs whitespace-nowrap text-muted">
        Rows per page
      </label>
      <select
        id="lb-per-page"
        className="lb-field w-auto py-1 text-xs"
        value={perPage}
        onChange={(event) => onPerPageChange(Number(event.target.value))}
      >
        {choices.map((option) => (
          <option key={option} value={option}>
            {option}
          </option>
        ))}
      </select>
    </div>
  );
}
