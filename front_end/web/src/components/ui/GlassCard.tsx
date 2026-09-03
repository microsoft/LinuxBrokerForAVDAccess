import type { HTMLAttributes, ReactNode } from 'react';

import { classNames } from '../../lib/format';

type Elevation = 'default' | 'strong' | 'soft';

export interface GlassCardProps extends HTMLAttributes<HTMLDivElement> {
  elevation?: Elevation;
  /** Adds a lift on hover. Only for cards that are themselves a link or button. */
  interactive?: boolean;
  children?: ReactNode;
}

const ELEVATION_CLASS: Record<Elevation, string> = {
  default: '',
  strong: 'lb-glass-strong',
  soft: 'lb-glass-soft',
};

export function GlassCard({
  elevation = 'default',
  interactive = false,
  className,
  children,
  ...rest
}: GlassCardProps) {
  return (
    <div
      className={classNames(
        'lb-glass',
        ELEVATION_CLASS[elevation],
        interactive && 'lb-interactive',
        className,
      )}
      {...rest}
    >
      {children}
    </div>
  );
}

/**
 * A flat panel for content nested inside a GlassCard.
 *
 * Nesting a second blurred surface inside the first compounds the backdrop and
 * turns the text background to mush, so inner panels share the palette without
 * stacking another blur.
 */
export function InsetPanel({ className, children, ...rest }: HTMLAttributes<HTMLDivElement>) {
  return (
    <div className={classNames('lb-inset', className)} {...rest}>
      {children}
    </div>
  );
}
