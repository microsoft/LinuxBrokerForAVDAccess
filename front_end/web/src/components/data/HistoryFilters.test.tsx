import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';

import { HistoryFilters } from './HistoryFilters';
import { useHistoryQuery } from '../../hooks/useHistoryQuery';

/**
 * Exercises the filter bar wired to the URL exactly as the history pages wire it.
 *
 * Ports the Jinja round-trip assertions: the operator's typed values must survive
 * being applied, and the ignore switches must mark a filter as omitted without
 * discarding what was typed. The Jinja version needed `readOnly` rather than
 * `disabled` for this, because disabled controls are dropped from a form
 * submission; the same requirement applies here.
 */
function Harness() {
  const query = useHistoryQuery();

  return (
    <>
      <HistoryFilters value={query.filters} onApply={query.setFilters} />
      <output data-testid="search">{query.search}</output>
      <output data-testid="page">{query.page}</output>
    </>
  );
}

function renderHarness(route = '/vms/history') {
  return render(
    <MemoryRouter initialEntries={[route]}>
      <Harness />
    </MemoryRouter>,
  );
}

const startDate = () => screen.getByLabelText('Start date') as HTMLInputElement;
const endDate = () => screen.getByLabelText('End date') as HTMLInputElement;
const limit = () => screen.getByLabelText('Limit') as HTMLInputElement;
const search = () => screen.getByTestId('search').textContent ?? '';

describe('history filters', () => {
  it('round-trips typed values through the URL', async () => {
    renderHarness();

    await userEvent.type(startDate(), '2026-01-15');
    await userEvent.type(endDate(), '2026-02-20');
    await userEvent.type(limit(), '37');
    await userEvent.click(screen.getByRole('button', { name: /Apply filter/ }));

    expect(startDate().value).toBe('2026-01-15');
    expect(endDate().value).toBe('2026-02-20');
    expect(limit().value).toBe('37');

    expect(search()).toContain('startdate=2026-01-15');
    expect(search()).toContain('enddate=2026-02-20');
    expect(search()).toContain('limit=37');
  });

  it('reads its initial state from the URL, so a filtered view can be shared', () => {
    renderHarness('/vms/history?startdate=2026-03-01&enddate=2026-03-31&limit=42&page=4');

    expect(startDate().value).toBe('2026-03-01');
    expect(endDate().value).toBe('2026-03-31');
    expect(limit().value).toBe('42');
    expect(screen.getByTestId('page').textContent).toBe('4');
  });

  it('keeps the typed values when the ignore switches are on', async () => {
    renderHarness('/vms/history?startdate=2026-03-01&enddate=2026-03-31&limit=42');

    await userEvent.click(screen.getByLabelText('All dates'));
    await userEvent.click(screen.getByLabelText('No limit'));
    await userEvent.click(screen.getByRole('button', { name: /Apply filter/ }));

    // The values are still there and still submitted, so unticking restores them.
    expect(startDate().value).toBe('2026-03-01');
    expect(endDate().value).toBe('2026-03-31');
    expect(limit().value).toBe('42');
    expect(screen.getByLabelText('All dates')).toBeChecked();
    expect(screen.getByLabelText('No limit')).toBeChecked();
  });

  it('makes ignored inputs read-only rather than disabled', async () => {
    renderHarness('/vms/history?ignore_dates=1&ignore_limit=1');

    // A disabled control would be dropped from submission and the value lost.
    expect(startDate()).toHaveAttribute('readonly');
    expect(startDate()).not.toBeDisabled();
    expect(limit()).toHaveAttribute('readonly');
    expect(limit()).not.toBeDisabled();
  });

  it('omits ignored filters from the request', async () => {
    renderHarness('/vms/history?startdate=2026-03-01&enddate=2026-03-31&limit=42');

    await userEvent.click(screen.getByLabelText('All dates'));
    await userEvent.click(screen.getByLabelText('No limit'));
    await userEvent.click(screen.getByRole('button', { name: /Apply filter/ }));

    const query = search();
    expect(query).toContain('ignore_dates=1');
    expect(query).toContain('ignore_limit=1');
    expect(query).not.toContain('startdate=');
    expect(query).not.toContain('enddate=');
    expect(query).not.toContain('limit=42');
  });

  it('returns to the first page when the filter changes', async () => {
    renderHarness('/vms/history?page=7');
    expect(screen.getByTestId('page').textContent).toBe('7');

    await userEvent.type(limit(), '5');
    await userEvent.click(screen.getByRole('button', { name: /Apply filter/ }));

    expect(screen.getByTestId('page').textContent).toBe('1');
  });

  it('always sends page and per_page', () => {
    renderHarness();
    expect(search()).toContain('page=1');
    expect(search()).toContain('per_page=10');
  });

  it('clamps a hostile per_page rather than passing it through', () => {
    renderHarness('/vms/history?per_page=-3');
    // Clamped to the same bounds the BFF applies, so the two never disagree.
    expect(search()).toContain('per_page=1');
    expect(search()).not.toContain('per_page=-3');
  });

  it('caps an excessive per_page at the server limit', () => {
    renderHarness('/vms/history?per_page=100000');
    expect(search()).toContain('per_page=200');
  });

  it('clamps a hostile page rather than passing it through', () => {
    renderHarness('/vms/history?page=abc');
    expect(search()).toContain('page=1');
  });
});
