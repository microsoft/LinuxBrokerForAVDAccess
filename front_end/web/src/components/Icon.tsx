import type { ReactNode, SVGProps } from 'react';

/*
 * Icons are hand-authored inline SVG so the portal has no icon-font or sprite
 * dependency and renders identically in disconnected and sovereign clouds.
 * These are the same 37 glyphs the Jinja `ui.icon()` macro used to provide.
 */
const ICONS = {
  'check-circle': (
    <>
      <circle cx="8" cy="8" r="6.25" />
      <path d="M5.2 8.2 7.2 10.2 10.9 6" />
    </>
  ),
  'x-circle': (
    <>
      <circle cx="8" cy="8" r="6.25" />
      <path d="M5.8 5.8 10.2 10.2M10.2 5.8 5.8 10.2" />
    </>
  ),
  'dash-circle': (
    <>
      <circle cx="8" cy="8" r="6.25" />
      <path d="M5.3 8h5.4" />
    </>
  ),
  'info-circle': (
    <>
      <circle cx="8" cy="8" r="6.25" />
      <path d="M8 7.4v3.6" />
      <path d="M8 5.1h.01" />
    </>
  ),
  'alert-triangle': (
    <>
      <path d="M8 2.2 14.4 13.4H1.6z" />
      <path d="M8 6.4v3" />
      <path d="M8 11.4h.01" />
    </>
  ),
  power: (
    <>
      <path d="M4.9 3.9a5 5 0 1 0 6.2 0" />
      <path d="M8 1.6v6.1" />
    </>
  ),
  person: (
    <>
      <circle cx="8" cy="5.2" r="2.6" />
      <path d="M2.9 13.7a5.2 5.2 0 0 1 10.2 0" />
    </>
  ),
  wifi: (
    <>
      <path d="M1.6 6.1a9 9 0 0 1 12.8 0" />
      <path d="M4.1 8.7a5.5 5.5 0 0 1 7.8 0" />
      <path d="M8 11.8h.01" />
    </>
  ),
  'wifi-off': (
    <>
      <path d="M1.6 6.1a9 9 0 0 1 4-2.3" />
      <path d="M10.2 3.9a9 9 0 0 1 4.2 2.2" />
      <path d="M8 11.8h.01" />
      <path d="M1.8 1.8 14.2 14.2" />
    </>
  ),
  wrench: (
    <path d="M10.6 1.9a3.7 3.7 0 0 0-4.2 4.8l-4.7 4.7 2.5 2.5 4.7-4.7a3.7 3.7 0 0 0 4.8-4.2L11.5 7 9 4.5z" />
  ),
  'arrow-up': (
    <>
      <path d="M8 13.2V3.2" />
      <path d="M4.2 7 8 3.2 11.8 7" />
    </>
  ),
  'arrow-down': (
    <>
      <path d="M8 2.8v10" />
      <path d="M4.2 9 8 12.8 11.8 9" />
    </>
  ),
  'arrow-return': (
    <>
      <path d="M13.2 3.6v2.9a3 3 0 0 1-3 3H3" />
      <path d="M6 6.5 3 9.5l3 3" />
    </>
  ),
  'box-arrow-right': (
    <>
      <path d="M9.4 2.4h4.2v11.2H9.4" />
      <path d="M2.4 8h7.6" />
      <path d="M7.2 5.2 10 8l-2.8 2.8" />
    </>
  ),
  clock: (
    <>
      <circle cx="8" cy="8" r="6.25" />
      <path d="M8 4.4V8l2.5 1.5" />
    </>
  ),
  search: (
    <>
      <circle cx="7.1" cy="7.1" r="4.6" />
      <path d="M10.5 10.5 14 14" />
    </>
  ),
  plus: <path d="M8 3.2v9.6M3.2 8h9.6" />,
  pencil: <path d="M11.1 2.2 13.8 4.9 5.4 13.3l-3.2.5.5-3.2z" />,
  trash: (
    <>
      <path d="M2.4 4.3h11.2" />
      <path d="M6 4.3V2.6h4v1.7" />
      <path d="M3.9 4.3 4.7 13.6h6.6l.8-9.3" />
    </>
  ),
  eye: (
    <>
      <path d="M1 8s2.7-4.4 7-4.4S15 8 15 8s-2.7 4.4-7 4.4S1 8 1 8Z" />
      <circle cx="8" cy="8" r="1.9" />
    </>
  ),
  sun: (
    <>
      <circle cx="8" cy="8" r="3.1" />
      <path d="M8 1.2v1.6M8 13.2v1.6M1.2 8h1.6M13.2 8h1.6M3.2 3.2l1.1 1.1M11.7 11.7l1.1 1.1M12.8 3.2l-1.1 1.1M4.3 11.7l-1.1 1.1" />
    </>
  ),
  moon: <path d="M13.2 9.7A5.6 5.6 0 1 1 6.4 2.9a4.6 4.6 0 0 0 6.8 6.8Z" />,
  gauge: (
    <>
      <path d="M2 11.8a6.6 6.6 0 1 1 12 0" />
      <path d="M8 11.2 11 6.6" />
    </>
  ),
  sliders: (
    <>
      <path d="M2 4.6h12M2 11.4h12" />
      <circle cx="6" cy="4.6" r="1.7" />
      <circle cx="10.6" cy="11.4" r="1.7" />
    </>
  ),
  server: (
    <>
      <rect x="1.9" y="2.4" width="12.2" height="4.6" rx="1.2" />
      <rect x="1.9" y="9" width="12.2" height="4.6" rx="1.2" />
      <path d="M4.4 4.7h.01M4.4 11.3h.01" />
    </>
  ),
  'chevron-up': <path d="M4 10 8 6l4 4" />,
  'chevron-down': <path d="M4 6l4 4 4-4" />,
  'chevron-left': <path d="M10 4 6 8l4 4" />,
  'chevron-right': <path d="M6 4l4 4-4 4" />,
  'chevron-expand': (
    <>
      <path d="M4.6 6.4 8 3l3.4 3.4" />
      <path d="M4.6 9.6 8 13l3.4-3.4" />
    </>
  ),
  funnel: <path d="M2 3h12L9.4 8.3V13L6.6 11.4V8.3z" />,
  refresh: (
    <>
      <path d="M13.6 8a5.6 5.6 0 1 1-1.7-4" />
      <path d="M13.9 1.6v2.9H11" />
    </>
  ),
  x: <path d="M3.6 3.6l8.8 8.8M12.4 3.6l-8.8 8.8" />,
  list: (
    <>
      <path d="M5.4 4.2h8.4M5.4 8h8.4M5.4 11.8h8.4" />
      <path d="M2.6 4.2h.01M2.6 8h.01M2.6 11.8h.01" />
    </>
  ),
  activity: <path d="M1.4 8h3l2-4.6L9.6 12l2-4h3.2" />,
  shield: <path d="M8 1.6 13.2 3.6v4c0 3.2-2.2 5.6-5.2 6.8-3-1.2-5.2-3.6-5.2-6.8v-4z" />,
  home: (
    <>
      <path d="M2.2 7.2 8 2.4l5.8 4.8" />
      <path d="M3.7 8v5.6h8.6V8" />
    </>
  ),
} satisfies Record<string, ReactNode>;

export type IconName = keyof typeof ICONS;

export const ICON_NAMES = Object.keys(ICONS) as IconName[];

const FALLBACK = <circle cx="8" cy="8" r="6.25" />;

export interface IconProps extends Omit<SVGProps<SVGSVGElement>, 'name'> {
  name: IconName;
  size?: number;
  /** Set when the icon is the only content of its control and carries meaning. */
  title?: string;
}

export function Icon({ name, size = 16, title, className, ...rest }: IconProps) {
  const decorative = title === undefined;

  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden={decorative || undefined}
      role={decorative ? undefined : 'img'}
      focusable="false"
      {...rest}
    >
      {title === undefined ? null : <title>{title}</title>}
      {ICONS[name] ?? FALLBACK}
    </svg>
  );
}
