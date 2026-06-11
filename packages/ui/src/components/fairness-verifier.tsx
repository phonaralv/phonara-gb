import { forwardRef, type HTMLAttributes, type ReactNode } from 'react';
import { cn } from '../lib/cn';
import { Badge } from './badge';

export interface FairnessVerifierProps extends Omit<HTMLAttributes<HTMLDivElement>, 'title'> {
  title: ReactNode;
  seedHashLabel: ReactNode;
  seedHash: ReactNode;
  serverSeedLabel?: ReactNode;
  serverSeed?: ReactNode;
  resultLabel?: ReactNode;
  result?: ReactNode;
  statusLabel: ReactNode;
  verified?: boolean | null;
}

export const FairnessVerifier = forwardRef<HTMLDivElement, FairnessVerifierProps>(
  function FairnessVerifier(
    {
      title,
      seedHashLabel,
      seedHash,
      serverSeedLabel,
      serverSeed,
      resultLabel,
      result,
      statusLabel,
      verified,
      className,
      ...props
    },
    ref,
  ) {
    return (
      <div ref={ref} className={cn('rounded-2xl border border-border bg-surface p-4', className)} {...props}>
        <div className="flex items-center justify-between gap-3">
          <h3 className="font-semibold text-fg">{title}</h3>
          <Badge tone={verified === false ? 'down' : verified ? 'up' : 'neutral'} size="sm">
            {statusLabel}
          </Badge>
        </div>
        <dl className="mt-3 flex flex-col gap-2 text-xs">
          <div>
            <dt className="text-muted">{seedHashLabel}</dt>
            <dd className="break-all font-mono text-fg">{seedHash}</dd>
          </div>
          {serverSeedLabel && serverSeed && (
            <div>
              <dt className="text-muted">{serverSeedLabel}</dt>
              <dd className="break-all font-mono text-fg">{serverSeed}</dd>
            </div>
          )}
          {resultLabel && result && (
            <div>
              <dt className="text-muted">{resultLabel}</dt>
              <dd className="break-all font-mono text-fg">{result}</dd>
            </div>
          )}
        </dl>
      </div>
    );
  },
);

FairnessVerifier.displayName = 'FairnessVerifier';
