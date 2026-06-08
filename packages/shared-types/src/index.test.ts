import { describe, expect, it } from 'vitest';
import { currencies } from './index';

describe('shared types scaffold', () => {
  it('keeps PHON, USDT, and KRW as supported currencies', () => {
    expect(currencies).toEqual(['PHON', 'USDT', 'KRW']);
  });
});
