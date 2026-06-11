import { useMutation, type UseMutationOptions } from '@tanstack/react-query';
import { toast } from 'sonner';
import { callRpc, type RpcArgs, type RpcError, type RpcName, type RpcReturns } from '../lib/rpc';
import { useT } from '../lib/i18n';

type RpcMutationOptions<N extends RpcName> = Omit<
  UseMutationOptions<RpcReturns<N>, RpcError, RpcArgs<N>>,
  'mutationFn'
> & {
  /** Show a sonner error toast (translated) on failure. Defaults to true. */
  toastOnError?: boolean;
};

/**
 * TanStack Query mutation bound to a typed PostgREST RPC. Errors arrive as
 * {@link RpcError} with a stable code; by default they surface a translated
 * toast so call sites stay declarative.
 */
export function useRpc<N extends RpcName>(fn: N, options?: RpcMutationOptions<N>) {
  const t = useT();
  const { toastOnError = true, onError, ...rest } = options ?? {};

  return useMutation<RpcReturns<N>, RpcError, RpcArgs<N>>({
    mutationFn: (args: RpcArgs<N>) => callRpc(fn, args),
    onError: (...args) => {
      const error = args[0];
      if (toastOnError) {
        toast.error(t(error.i18nKey));
      }
      return onError?.(...args);
    },
    ...rest,
  });
}
