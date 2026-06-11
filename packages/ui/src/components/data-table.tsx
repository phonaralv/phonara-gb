import { forwardRef, type ReactNode, type HTMLAttributes } from 'react';
import { cn } from '../lib/cn';

export interface ColumnDef<T> {
  key: string;
  header: ReactNode;
  cell: (row: T) => ReactNode;
  align?: 'left' | 'right' | 'center';
  className?: string;
}

export interface DataTableProps<T> extends HTMLAttributes<HTMLDivElement> {
  columns: ColumnDef<T>[];
  data: T[];
  keyExtractor: (row: T, i: number) => string | number;
  emptyState?: ReactNode;
  loading?: boolean;
  /** Compact row height */
  size?: 'sm' | 'md';
}

/**
 * DataTable — generic sortable/scrollable table for positions, orders, ledger entries.
 * All props generic over row type T. Column rendering via cell() function.
 */
function DataTableInner<T>(
  {
    columns,
    data,
    keyExtractor,
    emptyState,
    loading = false,
    size = 'md',
    className,
    ...rest
  }: DataTableProps<T>,
  ref: React.ForwardedRef<HTMLDivElement>,
) {
  const rowCls = size === 'sm' ? 'h-9 text-xs' : 'h-11 text-sm';

  return (
    <div
      ref={ref}
      className={cn('overflow-x-auto rounded-xl border border-border', className)}
      {...rest}
    >
      <table className="w-full border-collapse">
        <thead>
          <tr className="border-b border-border bg-surface-2">
            {columns.map((col) => (
              <th
                key={col.key}
                className={cn(
                  'px-4 py-2.5 text-xs font-medium text-muted whitespace-nowrap',
                  col.align === 'right' && 'text-right',
                  col.align === 'center' && 'text-center',
                  col.className,
                )}
              >
                {col.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {loading ? (
            <tr>
              <td
                colSpan={columns.length}
                className="px-4 py-8 text-center text-muted text-sm"
              >
                <span className="animate-pulse">…</span>
              </td>
            </tr>
          ) : data.length === 0 ? (
            <tr>
              <td
                colSpan={columns.length}
                className="px-4 py-8 text-center text-muted text-sm"
              >
                {emptyState ?? '—'}
              </td>
            </tr>
          ) : (
            data.map((row, i) => (
              <tr
                key={keyExtractor(row, i)}
                className={cn(rowCls, 'border-b border-border/60 last:border-0 hover:bg-white/[0.02] transition-colors')}
              >
                {columns.map((col) => (
                  <td
                    key={col.key}
                    className={cn(
                      'px-4 text-fg tabular-nums',
                      col.align === 'right' && 'text-right',
                      col.align === 'center' && 'text-center',
                      col.className,
                    )}
                  >
                    {col.cell(row)}
                  </td>
                ))}
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  );
}

export const DataTable = forwardRef(DataTableInner) as <T>(
  props: DataTableProps<T> & { ref?: React.ForwardedRef<HTMLDivElement> },
) => ReturnType<typeof DataTableInner>;

(DataTable as { displayName?: string }).displayName = 'DataTable';
