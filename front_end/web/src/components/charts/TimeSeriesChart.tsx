import { useId, useMemo, useRef, useState } from 'react';
import type { PointerEvent } from 'react';

import { formatBucket, isolatedPoints, linePath, niceScale, stepPath, timeAxisLabels } from '../../lib/chart';
import { Icon } from '../Icon';

export interface ChartSeries {
  key: string;
  label: string;
  values: Array<number | null>;
  /** A CSS colour, normally one of the --lb-*-fg tokens. */
  colour: string;
  /** SVG stroke-dasharray. Every series gets its own, so no line is told apart by colour alone. */
  dash?: string;
  /** Level across each bucket, for a limit such as the phase's maximum. */
  step?: boolean;
  width?: number;
}

export interface ChartMarker {
  index: number;
  count: number;
}

export interface TimeSeriesChartProps {
  /** Bucket starts, ISO-8601 UTC. */
  times: string[];
  bucketMinutes: number;
  series: ChartSeries[];
  /** Buckets where something went wrong, drawn along the top of the plot. */
  markers?: ChartMarker[];
  /** What a marker counts, such as "checkouts found no host". */
  markerLabel?: string;
  /** What the chart shows, for screen readers. */
  summary: string;
  /** The table view's caption. */
  caption: string;
  formatValue?: (value: number) => string;
  className?: string;
}

const WIDTH = 1000;
const HEIGHT = 240;
const LEFT = 40;
const RIGHT = 12;
const TOP = 22;
const BOTTOM = 26;
const PLOT_WIDTH = WIDTH - LEFT - RIGHT;
const PLOT_HEIGHT = HEIGHT - TOP - BOTTOM;

function defaultFormat(value: number) {
  return Number.isInteger(value) ? String(value) : value.toFixed(1);
}

/**
 * A line chart drawn inline, without a charting library: one line per series, markers for
 * problem buckets, a readout under the pointer, and a table view for keyboard and screen
 * reader users.
 */
export function TimeSeriesChart({
  times,
  bucketMinutes,
  series,
  markers = [],
  markerLabel = 'events',
  summary,
  caption,
  formatValue = defaultFormat,
  className,
}: TimeSeriesChartProps) {
  const [showTable, setShowTable] = useState(false);
  const [active, setActive] = useState<number | null>(null);
  const svgRef = useRef<SVGSVGElement>(null);
  const tableId = useId();

  const count = times.length;
  const bucketWidth = count ? PLOT_WIDTH / count : PLOT_WIDTH;
  const scale = useMemo(() => {
    const values = series.flatMap((line) => line.values.filter((value): value is number => value !== null));
    return niceScale(values.length ? Math.max(...values) : 0);
  }, [series]);
  const axis = useMemo(() => timeAxisLabels(times, bucketMinutes), [times, bucketMinutes]);
  const markerCounts = useMemo(() => new Map(markers.map((marker) => [marker.index, marker.count])), [markers]);

  const centre = (index: number) => LEFT + (index + 0.5) * bucketWidth;
  const start = (index: number) => LEFT + index * bucketWidth;
  const end = (index: number) => LEFT + (index + 1) * bucketWidth;
  const y = (value: number) => TOP + PLOT_HEIGHT - (value / scale.top) * PLOT_HEIGHT;
  const shown = (value: number | null | undefined) =>
    value === null || value === undefined ? '—' : formatValue(value);

  function track(event: PointerEvent<SVGRectElement>) {
    const svg = svgRef.current;
    if (!svg || !count) return;
    const box = svg.getBoundingClientRect();
    const svgX = ((event.clientX - box.left) / (box.width || 1)) * WIDTH;
    setActive(Math.min(count - 1, Math.max(0, Math.floor((svgX - LEFT) / bucketWidth))));
  }

  return (
    <div className={className}>
      <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
        <ul className="m-0 flex list-none flex-wrap gap-x-4 gap-y-1 p-0 text-xs text-muted">
          {series.map((line) => (
            <li key={line.key} className="flex items-center gap-1.5">
              <svg aria-hidden width={26} height={10} className="shrink-0">
                <line
                  x1={2}
                  x2={24}
                  y1={5}
                  y2={5}
                  stroke={line.colour}
                  strokeWidth={line.width ?? 2}
                  strokeDasharray={line.dash}
                  strokeLinecap="round"
                />
              </svg>
              {line.label}
            </li>
          ))}
          {markers.length ? (
            <li className="flex items-center gap-1.5">
              <svg aria-hidden width={12} height={10} className="shrink-0">
                <path d="M1 1 L11 1 L6 9 Z" fill="var(--lb-danger-fg)" />
              </svg>
              <span className="first-letter:uppercase">{markerLabel}</span>
            </li>
          ) : null}
        </ul>
        <button
          type="button"
          aria-pressed={showTable}
          aria-controls={showTable ? tableId : undefined}
          onClick={() => setShowTable((value) => !value)}
          className={
            showTable
              ? 'lb-btn border-transparent bg-[var(--lb-brand)] px-2.5 py-1 text-xs text-[var(--lb-on-brand)]'
              : 'lb-btn border-[var(--lb-hairline)] bg-[var(--lb-glass-bg-strong)] px-2.5 py-1 text-xs text-ink hover:border-[var(--lb-brand)]'
          }
        >
          <Icon name="list" size={13} />
          View as table
        </button>
      </div>

      {showTable ? (
        <div id={tableId} className="max-h-72 overflow-auto rounded-md border border-[var(--lb-hairline)]">
          <table className="lb-table">
            <caption className="sr-only">{caption}</caption>
            <thead>
              <tr>
                <th scope="col">Time (your time zone)</th>
                {series.map((line) => (
                  <th key={line.key} scope="col" className="text-right">
                    {line.label}
                  </th>
                ))}
                {markers.length ? (
                  <th scope="col" className="text-right first-letter:uppercase">
                    {markerLabel}
                  </th>
                ) : null}
              </tr>
            </thead>
            <tbody>
              {times.map((time, index) => (
                <tr key={time}>
                  <th scope="row" className="font-normal whitespace-nowrap">
                    {formatBucket(time)}
                  </th>
                  {series.map((line) => (
                    <td key={line.key} className="text-right tabular-nums">
                      {shown(line.values[index])}
                    </td>
                  ))}
                  {markers.length ? (
                    <td className="text-right tabular-nums">{markerCounts.get(index) ?? 0}</td>
                  ) : null}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <>
          <svg
            ref={svgRef}
            viewBox={`0 0 ${WIDTH} ${HEIGHT}`}
            role="img"
            aria-label={summary}
            className="block h-auto w-full touch-pan-y select-none"
          >
            {scale.ticks.map((tick) => (
              <g key={tick}>
                <line
                  x1={LEFT}
                  x2={WIDTH - RIGHT}
                  y1={y(tick)}
                  y2={y(tick)}
                  stroke="var(--lb-hairline)"
                  strokeWidth={tick === 0 ? 1.2 : 0.8}
                />
                <text x={LEFT - 8} y={y(tick) + 4} fontSize={11} textAnchor="end" fill="var(--lb-ink-subtle)">
                  {tick}
                </text>
              </g>
            ))}

            {axis.map((label) => (
              <g key={label.index}>
                <line
                  x1={start(label.index)}
                  x2={start(label.index)}
                  y1={TOP}
                  y2={TOP + PLOT_HEIGHT + 4}
                  stroke="var(--lb-hairline)"
                  strokeWidth={0.8}
                />
                <text x={start(label.index)} y={HEIGHT - 8} fontSize={11} textAnchor="middle" fill="var(--lb-ink-subtle)">
                  {label.label}
                </text>
              </g>
            ))}

            {series.map((line) => (
              <g key={line.key}>
                <path
                  d={line.step ? stepPath(line.values, start, end, y) : linePath(line.values, centre, y)}
                  fill="none"
                  stroke={line.colour}
                  strokeWidth={line.width ?? 2}
                  strokeDasharray={line.dash}
                  strokeLinejoin="round"
                  strokeLinecap="round"
                />
                {line.step
                  ? null
                  : isolatedPoints(line.values).map((index) => (
                      <circle key={index} cx={centre(index)} cy={y(line.values[index] ?? 0)} r={2.5} fill={line.colour} />
                    ))}
              </g>
            ))}

            {markers.map((marker) => (
              <path
                key={marker.index}
                d={`M${centre(marker.index) - 5} ${TOP - 15} L${centre(marker.index) + 5} ${TOP - 15} L${centre(marker.index)} ${TOP - 6} Z`}
                fill="var(--lb-danger-fg)"
              >
                <title>{`${marker.count} ${markerLabel} · ${formatBucket(times[marker.index] ?? '')}`}</title>
              </path>
            ))}

            {active !== null ? (
              <g aria-hidden>
                <line
                  x1={centre(active)}
                  x2={centre(active)}
                  y1={TOP}
                  y2={TOP + PLOT_HEIGHT}
                  stroke="var(--lb-ink-muted)"
                  strokeWidth={1}
                  strokeDasharray="3 3"
                />
                {series.map((line) => {
                  const value = line.values[active];
                  return value === null || value === undefined ? null : (
                    <circle key={line.key} cx={centre(active)} cy={y(value)} r={3.5} fill={line.colour} />
                  );
                })}
              </g>
            ) : null}

            <rect
              data-testid="chart-pointer-area"
              x={LEFT}
              y={0}
              width={PLOT_WIDTH}
              height={TOP + PLOT_HEIGHT}
              fill="transparent"
              onPointerMove={track}
              onPointerDown={track}
              onPointerLeave={() => setActive(null)}
            />
          </svg>
          <p aria-hidden className="m-0 mt-1 flex min-h-5 flex-wrap gap-x-3 text-xs text-muted tabular-nums">
            {active !== null ? (
              <>
                <span className="font-medium text-ink">{formatBucket(times[active])}</span>
                {series.map((line) => (
                  <span key={line.key}>
                    {line.label} {shown(line.values[active])}
                  </span>
                ))}
                {markerCounts.get(active) ? (
                  <span className="text-[var(--lb-danger-fg)]">
                    {markerCounts.get(active)} {markerLabel}
                  </span>
                ) : null}
              </>
            ) : (
              <span>Point at the chart to read a time.</span>
            )}
          </p>
        </>
      )}
    </div>
  );
}
