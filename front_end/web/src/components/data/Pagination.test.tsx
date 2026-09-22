import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

import { Pagination, paginationWindow } from './Pagination';

describe('paginationWindow', () => {
  it('keeps first, last and a window of two around the current page', () => {
    // Pinned exactly, matching the Jinja macro this replaced: rendering every page
    // number produced hundreds of links once the "No limit" filter was used.
    const items = paginationWindow(6, 12, 2).filter((item) => item !== 'gap');
    expect(items).toEqual([1, 4, 5, 6, 7, 8, 12]);
  });

  it('inserts a gap marker only where pages were skipped', () => {
    expect(paginationWindow(6, 12, 2)).toEqual([1, 'gap', 4, 5, 6, 7, 8, 'gap', 12]);
  });

  it('does not insert a gap when the window already reaches the ends', () => {
    expect(paginationWindow(3, 5, 2)).toEqual([1, 2, 3, 4, 5]);
  });

  it('returns nothing when there are no pages', () => {
    expect(paginationWindow(1, 0)).toEqual([]);
  });
});

describe('Pagination', () => {
  it('renders nothing for a single page', () => {
    const { container } = render(
      <Pagination page={1} totalPages={1} onPageChange={() => {}} />,
    );
    expect(container).toBeEmptyDOMElement();
  });

  it('marks the current page for assistive technology', () => {
    render(<Pagination page={3} totalPages={9} onPageChange={() => {}} />);
    expect(screen.getByRole('button', { name: 'Page 3' })).toHaveAttribute('aria-current', 'page');
  });

  it('disables the step buttons at each end', () => {
    const { rerender } = render(
      <Pagination page={1} totalPages={9} onPageChange={() => {}} />,
    );
    expect(screen.getByRole('button', { name: 'Previous page' })).toBeDisabled();

    rerender(<Pagination page={9} totalPages={9} onPageChange={() => {}} />);
    expect(screen.getByRole('button', { name: 'Next page' })).toBeDisabled();
  });

  it('reports the requested page', async () => {
    const onPageChange = vi.fn();
    render(<Pagination page={3} totalPages={9} onPageChange={onPageChange} />);

    await userEvent.click(screen.getByRole('button', { name: 'Page 5' }));
    expect(onPageChange).toHaveBeenCalledWith(5);

    await userEvent.click(screen.getByRole('button', { name: 'Next page' }));
    expect(onPageChange).toHaveBeenCalledWith(4);
  });
});
