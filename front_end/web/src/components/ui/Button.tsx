import { forwardRef } from 'react';
import type { AnchorHTMLAttributes, ButtonHTMLAttributes } from 'react';
import { Link } from 'react-router-dom';
import type { LinkProps } from 'react-router-dom';

import { classNames } from '../../lib/format';
import { Icon } from '../Icon';
import type { IconName } from '../Icon';

export type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'danger' | 'warning';
export type ButtonSize = 'sm' | 'md';

const VARIANT_CLASS: Record<ButtonVariant, string> = {
  primary:
    'bg-[var(--lb-brand)] text-[var(--lb-on-brand)] border-transparent hover:bg-[var(--lb-brand-strong)]',
  secondary:
    'bg-[var(--lb-glass-bg-strong)] text-ink border-[var(--lb-hairline)] hover:border-[var(--lb-brand)] hover:text-[var(--lb-brand)]',
  ghost: 'bg-transparent text-muted border-transparent hover:bg-[var(--lb-hover)] hover:text-ink',
  danger:
    'bg-[var(--lb-danger-bg)] text-[var(--lb-danger-fg)] border-[var(--lb-danger-bd)] hover:brightness-110',
  warning:
    'bg-[var(--lb-warn-bg)] text-[var(--lb-warn-fg)] border-[var(--lb-warn-bd)] hover:brightness-110',
};

const SIZE_CLASS: Record<ButtonSize, string> = {
  sm: 'text-xs px-2.5 py-1.5',
  md: 'text-sm px-3.5 py-2',
};

function buttonClass(variant: ButtonVariant, size: ButtonSize, className?: string) {
  return classNames('lb-btn', VARIANT_CLASS[variant], SIZE_CLASS[size], className);
}

function iconSize(size: ButtonSize) {
  return size === 'sm' ? 14 : 15;
}

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant;
  size?: ButtonSize;
  icon?: IconName;
}

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { variant = 'secondary', size = 'md', icon, className, children, type = 'button', ...rest },
  ref,
) {
  return (
    <button ref={ref} type={type} className={buttonClass(variant, size, className)} {...rest}>
      {icon ? <Icon name={icon} size={iconSize(size)} /> : null}
      {children}
    </button>
  );
});

export interface ButtonLinkProps extends LinkProps {
  variant?: ButtonVariant;
  size?: ButtonSize;
  icon?: IconName;
}

/** A router link styled as a button, for navigation actions such as "Add VM". */
export function ButtonLink({
  variant = 'secondary',
  size = 'md',
  icon,
  className,
  children,
  ...rest
}: ButtonLinkProps) {
  return (
    <Link className={classNames(buttonClass(variant, size, className), 'no-underline')} {...rest}>
      {icon ? <Icon name={icon} size={iconSize(size)} /> : null}
      {children}
    </Link>
  );
}

export interface ButtonAnchorProps extends AnchorHTMLAttributes<HTMLAnchorElement> {
  variant?: ButtonVariant;
  size?: ButtonSize;
  icon?: IconName;
}

/**
 * A plain anchor styled as a button, for the server-rendered auth routes.
 *
 * Sign in and sign out are full browser navigations to Flask, which then redirects
 * to Entra ID, so they must not be intercepted by React Router.
 */
export function ButtonAnchor({
  variant = 'secondary',
  size = 'md',
  icon,
  className,
  children,
  ...rest
}: ButtonAnchorProps) {
  return (
    <a className={classNames(buttonClass(variant, size, className), 'no-underline')} {...rest}>
      {icon ? <Icon name={icon} size={iconSize(size)} /> : null}
      {children}
    </a>
  );
}
