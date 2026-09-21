import fs from 'fs';
import path from 'path';

export const ROOT = path.resolve(__dirname, '..');
export const REPO = path.resolve(ROOT, '../..');
export const MATHS = path.join(REPO, 'bush-maths');
export const TEST_DATA = path.join(MATHS, 'testData');

/**
 * Every factory package that ships a math-check adapter. Packages whose name starts with `_` (the template) are
 * examples, not approved factories: they are only included when asked for by name.
 */
export function discoverFactories(includeExamples = false): { name: string; dir: string }[] {
  const pkg = path.join(REPO, 'pkg');
  return fs
    .readdirSync(pkg)
    .filter((d) => fs.existsSync(path.join(pkg, d, 'math-check', 'pool.ts')))
    .filter((d) => includeExamples || !d.startsWith('_'))
    .sort()
    .map((d) => ({ name: d, dir: path.join(pkg, d) }));
}

/** Where a factory's generated test data lives: examples stay out of bush-maths (its suites only know accepted types). */
export function testDataDirFor(factory: string): string {
  return factory.startsWith('_') ? path.join(ROOT, 'out', 'testData') : TEST_DATA;
}
