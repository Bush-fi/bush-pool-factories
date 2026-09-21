import fs from 'fs';
import path from 'path';

export const ROOT = path.resolve(__dirname, '..');
export const REPO = path.resolve(ROOT, '../..');
export const MATHS = path.join(REPO, 'maths');
export const TEST_DATA = path.join(MATHS, 'testData');
export const ADAPTERS = path.join(ROOT, 'adapters');

/**
 * Every factory with an adapter in maths/check/adapters/<factory>.ts. Factories whose name starts with `_` (the
 * template) are examples, not approved factories: they are only included when asked for by name.
 */
export function discoverFactories(includeExamples = false): { name: string; adapter: string }[] {
  return fs
    .readdirSync(ADAPTERS)
    .filter((f) => f.endsWith('.ts'))
    .map((f) => f.slice(0, -3))
    .filter((name) => includeExamples || !name.startsWith('_'))
    .sort()
    .map((name) => ({ name, adapter: path.join(ADAPTERS, `${name}.ts`) }));
}

/** Where a factory's generated test data lives: examples stay out of maths/testData (the maths suites only know accepted types). */
export function testDataDirFor(factory: string): string {
  return factory.startsWith('_') ? path.join(ROOT, 'out', 'testData') : TEST_DATA;
}
