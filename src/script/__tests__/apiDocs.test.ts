import { existsSync, readFileSync, writeFileSync } from 'fs';
import { join } from 'path';

import { PHOTO_API_DECLARATIONS } from '../apiDeclarations';

const target = join(__dirname, '..', '..', '..', 'docs', 'photo-api.d.ts');
const expected = `// Generated from src/script/apiDeclarations.ts by \`npm run sync-api-docs\`. Do not edit by hand.\n\n${PHOTO_API_DECLARATIONS}`;

// docs/photo-api.d.ts is the API as a file people can read and tools can load.
// `npm run sync-api-docs` rewrites it; otherwise this test fails when it has fallen behind.
it('docs/photo-api.d.ts matches the declarations the agent is given', () => {
  if (process.env.UPDATE_API_DOCS) writeFileSync(target, expected);
  expect(existsSync(target)).toBe(true);
  expect(readFileSync(target, 'utf8')).toBe(expected);
});
