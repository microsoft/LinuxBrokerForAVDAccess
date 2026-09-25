import { describe, expect, it } from 'vitest';
import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router-dom';

import { AttentionPanel, describeAttention } from './AttentionPanel';
import { describeCapacity } from './CapacityCard';
import { CheckoutHealthCard, formatMilliseconds, secondsSince } from './CheckoutHealthCard';
import { TimeSeriesChart } from '../charts/TimeSeriesChart';
import type { AttentionItems, CheckoutStats, UtilizationPoint } from '../../types/broker';

function point(values: Partial<UtilizationPoint>): UtilizationPoint {
  return {
    BucketStartUtc: '2026-07-13T10:00:00Z', Runs: 3, PoweredOn: 4, InUse: 2, Serviceable: 4, PeakInUse: 3,
    MinVMs: 2, MaxVMs: 6, Checkouts: 0, Denied: 0, Failed: 0, ...values,
  };
}

const STATS: CheckoutStats = {
  Total: 40, Assigned: 22, Reused: 16, NoneAvailable: 2, ProvisionFailed: 1, Errors: 1, P50Ms: 850, P95Ms: 8400,
  DeniedLastHour: 0, DeniedPercent: 5, LastDeniedUtc: null, HostStarts: 1, StartP50Seconds: 95, StartP95Seconds: 180,
};

describe('describeCapacity', () => {
  it('says what the chart shows', () => {
    const series = [point({ PeakInUse: 5, Serviceable: 3 }), point({ Serviceable: 6, Denied: 2 }), point({ Runs: 0, PoweredOn: null, InUse: null, Serviceable: null, PeakInUse: null, MaxVMs: null })];
    expect(describeCapacity(series, 168)).toBe(
      'Capacity over the last 7 days. At most 5 hosts were in use at once. Between 3 and 6 hosts could take a user. The scaling maximum was 6. 2 checkouts found no host.',
    );
  });

  it('says when every checkout found a host', () => {
    expect(describeCapacity([point({})], 24)).toContain('Every checkout found a host.');
  });
});

describe('CheckoutHealthCard', () => {
  it('shows demand the pool did not meet, wait times and host starts', () => {
    render(<CheckoutHealthCard stats={STATS} hours={24} />);

    expect(screen.getByText('the last 24 hours')).toBeInTheDocument();
    expect(screen.getByText('22 new · 16 reconnects')).toBeInTheDocument();
    expect(screen.getByText('5% of checkouts · last —')).toBeInTheDocument();
    expect(screen.getByText('850 ms')).toBeInTheDocument();
    expect(screen.getByText('Median · 95% within 8.4 s')).toBeInTheDocument();
    expect(screen.getByText('Median of 1 start · 95% within 3 min')).toBeInTheDocument();
    expect(screen.getByText('1 could not set up the user · 1 broker error')).toBeInTheDocument();
  });

  it('reads calmly when nothing went wrong', () => {
    render(<CheckoutHealthCard stats={{ ...STATS, NoneAvailable: 0, ProvisionFailed: 0, Errors: 0, P50Ms: null, P95Ms: null, HostStarts: 0 }} hours={168} />);
    expect(screen.getByText('Every checkout found a host')).toBeInTheDocument();
    expect(screen.getByText('No checkouts yet')).toBeInTheDocument();
    expect(screen.getByText('No host was started')).toBeInTheDocument();
    expect(screen.queryByText('Failed checkouts')).not.toBeInTheDocument();
  });

  it('formats times', () => {
    expect(formatMilliseconds(412.4)).toBe('412 ms');
    expect(formatMilliseconds(2150)).toBe('2.1 s');
    expect(formatMilliseconds(null)).toBe('—');
    expect(secondsSince('2026-07-13T10:00:00Z', Date.parse('2026-07-13T10:05:00Z'))).toBe(300);
    expect(secondsSince('junk')).toBeNull();
  });
});

describe('AttentionPanel', () => {
  const items: AttentionItems = {
    Available: true,
    Incomplete: false,
    Summary: { Total: 4, Critical: 1, Warning: 3, Info: 0 },
    Items: [
      { Kind: 'no-ready-hosts', Severity: 'critical' },
      { Kind: 'unreachable', Severity: 'warning', VMID: 2, Hostname: 'linux-host-02', AgeSeconds: 1500 },
      { Kind: 'never-connected', Severity: 'warning', VMID: 3, Hostname: 'linux-host-03', Username: 'erin', AgeSeconds: 2700 },
      { Kind: 'health', Severity: 'warning', Flag: 'xrdp-down', Count: 12, Hostnames: ['linux-host-04', 'linux-host-05'] },
    ],
  };

  it('lists each item with where to act on it', () => {
    render(<AttentionPanel data={items} />, { wrapper: MemoryRouter });

    const panel = screen.getByRole('region', { name: 'Needs attention now' });
    expect(within(panel).getByText('4 items · 1 critical')).toBeInTheDocument();
    const rows = within(panel).getAllByRole('listitem');
    expect(rows[0]).toHaveTextContent('Critical: No host can take a new user');
    expect(rows[1]).toHaveTextContent('linux-host-02 is powered on but has not been reachable for 25 min.');
    expect(within(rows[1]).getByRole('link', { name: 'Open host' })).toHaveAttribute('href', '/vms/2');
    expect(within(rows[2]).getByRole('link', { name: 'Open user' })).toHaveAttribute('href', '/users/erin');
    expect(rows[3]).toHaveTextContent('12 hosts xrdp down: linux-host-04, linux-host-05 and 10 more.');
    expect(within(rows[3]).getByRole('link', { name: 'Fleet health' })).toHaveAttribute('href', '/vms/health?show=xrdp-down');
  });

  it('renders nothing when all is well or the broker cannot say', () => {
    const { container, rerender } = render(<AttentionPanel data={{ ...items, Items: [] }} />, { wrapper: MemoryRouter });
    expect(container).toBeEmptyDOMElement();
    rerender(<AttentionPanel data={{ ...items, Available: false }} />);
    expect(container).toBeEmptyDOMElement();
  });

  it('says when only host health could be checked', () => {
    render(<AttentionPanel data={{ ...items, Incomplete: true }} />, { wrapper: MemoryRouter });
    expect(screen.getByText(/Only host health is shown/)).toBeInTheDocument();
  });

  it('describes stuck cleanups and denied checkouts', () => {
    const cleanup = describeAttention({ Kind: 'cleanup-stuck', Severity: 'warning', VMID: 7, Hostname: 'h7', Username: 'dave', AgeSeconds: 1200 });
    render(<p>{cleanup.text}</p>);
    expect(screen.getByText(/after 20 min/)).toHaveTextContent('h7 has not removed dave after 20 min');
    expect(describeAttention({ Kind: 'denied-checkouts', Severity: 'critical', Count: 1, AgeSeconds: 30 }).to).toBe('/scaling');
  });
});

describe('TimeSeriesChart', () => {
  const times = ['2026-07-13T10:00:00Z', '2026-07-13T10:15:00Z', '2026-07-13T10:30:00Z'];

  it('offers the numbers as a table', async () => {
    render(
      <TimeSeriesChart
        times={times}
        bucketMinutes={15}
        series={[{ key: 'in-use', label: 'In use', values: [1, null, 2.5], colour: 'red' }]}
        markers={[{ index: 1, count: 2 }]}
        markerLabel="checkouts found no host"
        summary="Capacity summary"
        caption="Capacity by interval"
      />,
    );

    expect(screen.getByRole('img', { name: 'Capacity summary' })).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: 'View as table' }));

    expect(screen.getByRole('button', { name: 'View as table' })).toHaveAttribute('aria-pressed', 'true');
    const table = screen.getByRole('table', { name: 'Capacity by interval' });
    const rows = within(table).getAllByRole('row');
    expect(rows).toHaveLength(4);
    expect(within(rows[2]).getAllByRole('cell').map((cell) => cell.textContent)).toEqual(['—', '2']);
    expect(within(rows[3]).getAllByRole('cell').map((cell) => cell.textContent)).toEqual(['2.5', '0']);
  });
});
