import type { MutableRefObject, Ref } from 'react';

/**
 * Merges multiple refs (callback or object) into one callback ref. Lets a
 * `forwardRef` component keep its own internal ref (e.g. for focus/scroll
 * logic) while still exposing the node to the caller's forwarded ref.
 */
export function mergeRefs<T>(...refs: ReadonlyArray<Ref<T> | undefined>): (node: T | null) => void {
  return (node) => {
    for (const ref of refs) {
      if (typeof ref === 'function') {
        ref(node);
      } else if (ref) {
        (ref as MutableRefObject<T | null>).current = node;
      }
    }
  };
}
