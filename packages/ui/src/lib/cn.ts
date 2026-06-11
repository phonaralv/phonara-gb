import { clsx, type ClassValue } from 'clsx';
import { twMerge } from 'tailwind-merge';

/**
 * Merge class names with conflict resolution. `clsx` resolves conditionals,
 * `tailwind-merge` dedupes conflicting Tailwind utilities (last wins).
 */
export function cn(...inputs: ClassValue[]): string {
  return twMerge(clsx(inputs));
}
