import { readdirSync, readFileSync, statSync } from 'fs';
import { join } from 'path';

import { COLOR_RANGES, CURVE_CHANNELS, DETAIL_SPECS, GLOBAL_SPECS, GRADING_RANGES } from '@/engine/state';
import { en } from '../en';
import { it as italian } from '../it';

const root = join(__dirname, '..', '..');

function sources(directory: string): string[] {
  return readdirSync(directory).flatMap((name) => {
    const path = join(directory, name);
    if (statSync(path).isDirectory()) return name === '__tests__' ? [] : sources(path);
    return /\.tsx?$/.test(name) ? [path] : [];
  });
}

const placeholders = (text: string): string[] => (text.match(/\{\w+\}/g) ?? []).sort();

describe('strings', () => {
  const keys = Object.keys(en) as (keyof typeof en)[];

  it('exist in English and Italian, with the same placeholders', () => {
    expect(Object.keys(italian).sort()).toEqual([...keys].sort());
    for (const key of keys) {
      expect(italian[key].trim()).not.toBe('');
      expect({ key, placeholders: placeholders(italian[key]) }).toEqual({ key, placeholders: placeholders(en[key]) });
    }
  });

  it('cover every key the code asks for by name', () => {
    const used = new Set<string>();
    const screens = [...sources(join(root, 'ui')), ...sources(join(root, 'app')), join(root, 'editor', 'assistant.ts')];
    for (const file of screens) {
      const text = readFileSync(file, 'utf8');
      for (const match of text.matchAll(/'((?:action|library|editor|tab|section|param|channel|curves|color|hsl|grading|crop|export|assistant|script|suggest|settings)\.[A-Za-z0-9]+)'/g)) {
        used.add(match[1]);
      }
    }
    expect(used.size).toBeGreaterThan(80);
    expect([...used].filter((key) => !(key in en))).toEqual([]);
  });

  it('cover every key the code builds from a setting name', () => {
    const built = [
      ...Object.keys(GLOBAL_SPECS).map((name) => `param.${name}`),
      ...Object.keys(DETAIL_SPECS).map((name) => `param.${name}`),
      ...COLOR_RANGES.map((name) => `color.${name}`),
      ...CURVE_CHANNELS.map((name) => `channel.${name}`),
      ...GRADING_RANGES.map((name) => `grading.${name}`),
      ...['hue', 'saturation', 'luminance'].flatMap((name) => [`hsl.${name}`, `grading.${name}`]),
      ...['assistant', 'light', 'color', 'curves', 'hsl', 'grading', 'detail', 'crop'].map((name) => `tab.${name}`),
    ];
    expect(built.filter((key) => !(key in en))).toEqual([]);
  });

  it('are all used somewhere', () => {
    const text = sources(root)
      .filter((file) => !file.includes(join('src', 'i18n')))
      .map((file) => readFileSync(file, 'utf8'))
      .join('\n');
    const prefixes = ['param.', 'color.', 'channel.', 'grading.', 'hsl.', 'tab.'];
    const unused = keys.filter((key) => !text.includes(`'${key}'`) && !prefixes.some((prefix) => key.startsWith(prefix)));
    expect(unused).toEqual([]);
  });
});
