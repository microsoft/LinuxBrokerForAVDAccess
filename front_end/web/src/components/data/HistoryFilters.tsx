import { useEffect, useState } from 'react';

import type { HistoryFilterValues } from '../../types/broker';
import { Button } from '../ui/Button';
import { Checkbox, TextField } from '../ui/Field';
import { GlassCard } from '../ui/GlassCard';

export interface HistoryFiltersProps {
  value: HistoryFilterValues;
  onApply: (filters: HistoryFilterValues) => void;
}

/**
 * The date/limit filter bar shared by VM history, the activity log and rule history.
 *
 * The ignore switches mark a filter as omitted rather than clearing it, so the
 * operator's typed dates survive and reappear when the switch is turned back off.
 * The inputs are therefore made read-only, not cleared or disabled.
 */
export function HistoryFilters({ value, onApply }: HistoryFiltersProps) {
  const [draft, setDraft] = useState(value);

  // Re-sync when the URL changes underneath us, for example on a back navigation.
  useEffect(() => {
    setDraft(value);
  }, [value]);

  function set<K extends keyof HistoryFilterValues>(key: K, next: HistoryFilterValues[K]) {
    setDraft((current) => ({ ...current, [key]: next }));
  }

  return (
    <GlassCard
      elevation="soft"
      className="mb-5 p-4"
      role="search"
      aria-label="Filter history records"
    >
      <form
        onSubmit={(event) => {
          event.preventDefault();
          onApply(draft);
        }}
        className="grid grid-cols-1 items-end gap-4 sm:grid-cols-2 lg:grid-cols-5"
      >
        <TextField
          label="Start date"
          type="date"
          value={draft.startdate}
          readOnly={draft.ignore_dates}
          onChange={(event) => set('startdate', event.target.value)}
        />
        <TextField
          label="End date"
          type="date"
          value={draft.enddate}
          readOnly={draft.ignore_dates}
          onChange={(event) => set('enddate', event.target.value)}
        />
        <TextField
          label="Limit"
          type="number"
          min={1}
          value={draft.limit}
          readOnly={draft.ignore_limit}
          onChange={(event) => set('limit', event.target.value)}
        />

        <div className="flex flex-col gap-2">
          <Checkbox
            label="All dates"
            checked={draft.ignore_dates}
            onChange={(checked) => set('ignore_dates', checked)}
          />
          <Checkbox
            label="No limit"
            checked={draft.ignore_limit}
            onChange={(checked) => set('ignore_limit', checked)}
          />
        </div>

        <Button type="submit" variant="primary" icon="funnel" className="w-full">
          Apply filter
        </Button>
      </form>
    </GlassCard>
  );
}
