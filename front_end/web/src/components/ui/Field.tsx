import { useId } from 'react';
import type { InputHTMLAttributes, ReactNode, SelectHTMLAttributes } from 'react';

import { classNames } from '../../lib/format';

interface FieldShellProps {
  label: string;
  help?: ReactNode;
  error?: string;
  htmlFor: string;
  className?: string;
  children: ReactNode;
}

function FieldShell({ label, help, error, htmlFor, className, children }: FieldShellProps) {
  return (
    <div className={classNames('flex flex-col gap-1.5', className)}>
      <label htmlFor={htmlFor} className="text-sm font-medium text-ink">
        {label}
      </label>
      {children}
      {error ? (
        <p id={`${htmlFor}-error`} className="mb-0 text-xs text-[var(--lb-danger-fg)]">
          {error}
        </p>
      ) : null}
      {help ? (
        <p id={`${htmlFor}-help`} className="mb-0 text-xs text-muted">
          {help}
        </p>
      ) : null}
    </div>
  );
}

export interface TextFieldProps extends Omit<InputHTMLAttributes<HTMLInputElement>, 'id'> {
  label: string;
  help?: ReactNode;
  error?: string;
  fieldClassName?: string;
}

export function TextField({
  label,
  help,
  error,
  className,
  fieldClassName,
  ...rest
}: TextFieldProps) {
  const id = useId();
  const describedBy = [help ? `${id}-help` : null, error ? `${id}-error` : null]
    .filter(Boolean)
    .join(' ');

  return (
    <FieldShell label={label} help={help} error={error} htmlFor={id} className={fieldClassName}>
      <input
        id={id}
        className={classNames('lb-field', className)}
        aria-describedby={describedBy || undefined}
        aria-invalid={error ? true : undefined}
        {...rest}
      />
    </FieldShell>
  );
}

export interface SelectFieldProps extends Omit<SelectHTMLAttributes<HTMLSelectElement>, 'id'> {
  label: string;
  help?: ReactNode;
  error?: string;
  options: Array<{ value: string; label: string }>;
  fieldClassName?: string;
}

export function SelectField({
  label,
  help,
  error,
  options,
  className,
  fieldClassName,
  ...rest
}: SelectFieldProps) {
  const id = useId();
  const describedBy = [help ? `${id}-help` : null, error ? `${id}-error` : null]
    .filter(Boolean)
    .join(' ');

  return (
    <FieldShell label={label} help={help} error={error} htmlFor={id} className={fieldClassName}>
      <select
        id={id}
        className={classNames('lb-field', className)}
        aria-describedby={describedBy || undefined}
        aria-invalid={error ? true : undefined}
        {...rest}
      >
        {options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
    </FieldShell>
  );
}

export interface TextAreaFieldProps
  extends Omit<React.TextareaHTMLAttributes<HTMLTextAreaElement>, 'id'> {
  label: string;
  help?: ReactNode;
  fieldClassName?: string;
}

export function TextAreaField({
  label,
  help,
  className,
  fieldClassName,
  ...rest
}: TextAreaFieldProps) {
  const id = useId();

  return (
    <FieldShell label={label} help={help} htmlFor={id} className={fieldClassName}>
      <textarea
        id={id}
        className={classNames('lb-field', className)}
        aria-describedby={help ? `${id}-help` : undefined}
        {...rest}
      />
    </FieldShell>
  );
}

export interface SwitchProps {
  label: ReactNode;
  help?: ReactNode;
  checked: boolean;
  onChange: (checked: boolean) => void;
  disabled?: boolean;
  className?: string;
}

/**
 * Checkbox styled as a switch.
 *
 * Deliberately a real `<input type="checkbox">` rather than a div with a role, so
 * it keeps native keyboard handling, form semantics and assistive-technology
 * behaviour for free.
 */
export function Switch({ label, help, checked, onChange, disabled, className }: SwitchProps) {
  const id = useId();

  return (
    <div className={classNames('flex items-start gap-2.5', className)}>
      <input
        id={id}
        type="checkbox"
        role="switch"
        checked={checked}
        disabled={disabled}
        onChange={(event) => onChange(event.target.checked)}
        aria-describedby={help ? `${id}-help` : undefined}
        className={classNames(
          'mt-0.5 h-5 w-9 shrink-0 cursor-pointer appearance-none rounded-full border',
          'border-[var(--lb-hairline)] bg-[var(--lb-neutral-bg)] transition-colors',
          'checked:border-[var(--lb-brand)] checked:bg-[var(--lb-brand)]',
          'disabled:cursor-not-allowed disabled:opacity-60',
          // The knob is drawn with a gradient so no extra element is needed.
          'bg-[radial-gradient(circle_at_0.625rem_50%,var(--lb-ink-subtle)_0.375rem,transparent_0.4rem)]',
          'checked:bg-[radial-gradient(circle_at_1.625rem_50%,var(--lb-on-brand)_0.375rem,transparent_0.4rem)]',
        )}
      />
      <div className="min-w-0">
        <label htmlFor={id} className="cursor-pointer text-sm font-medium text-ink">
          {label}
        </label>
        {help ? (
          <p id={`${id}-help`} className="mt-0.5 mb-0 text-xs text-muted">
            {help}
          </p>
        ) : null}
      </div>
    </div>
  );
}

export interface CheckboxProps {
  label: ReactNode;
  help?: ReactNode;
  checked: boolean;
  onChange: (checked: boolean) => void;
  className?: string;
}

export function Checkbox({ label, help, checked, onChange, className }: CheckboxProps) {
  const id = useId();

  return (
    <div className={classNames('flex items-start gap-2.5', className)}>
      <input
        id={id}
        type="checkbox"
        checked={checked}
        onChange={(event) => onChange(event.target.checked)}
        aria-describedby={help ? `${id}-help` : undefined}
        className="mt-0.5 size-4 shrink-0 cursor-pointer accent-[var(--lb-brand)]"
      />
      <div className="min-w-0">
        <label htmlFor={id} className="cursor-pointer text-sm text-ink">
          {label}
        </label>
        {help ? (
          <p id={`${id}-help`} className="mt-0.5 mb-0 text-xs text-muted">
            {help}
          </p>
        ) : null}
      </div>
    </div>
  );
}
