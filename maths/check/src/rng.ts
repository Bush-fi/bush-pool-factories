import { Rng } from './types';

// Deterministic PRNG (mulberry32) so generated data can be reproduced from its seed.
export function makeRng(seed: number): Rng {
  let a = seed >>> 0;
  const rand = () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const ONE = 10n ** 18n;
  const fp = (x: number): bigint => {
    const [int, frac = ''] = x.toFixed(18).split('.');
    return BigInt(int) * ONE + BigInt(frac.padEnd(18, '0'));
  };
  const rng: Rng = {
    rand01: rand,
    num: (lo, hi) => lo + rand() * (hi - lo),
    logNum: (lo, hi) => Math.exp(rng.num(Math.log(lo), Math.log(hi))),
    int: (lo, hi) => Math.floor(rng.num(lo, hi + 1)),
    pick: (xs) => xs[rng.int(0, xs.length - 1)],
    fp,
  };
  return rng;
}
