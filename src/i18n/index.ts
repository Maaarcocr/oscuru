import { getLocales } from 'expo-localization';

import { en } from './en';
import { it } from './it';

export type StringKey = keyof typeof en;

const tables: Record<string, Record<StringKey, string>> = { en, it };

function currentTable(): Record<StringKey, string> {
  const language = getLocales()[0]?.languageCode ?? 'en';
  return tables[language] ?? en;
}

/** The text for `key` in the phone's language (English or Italian), with `{name}` placeholders filled in. */
export function t(key: StringKey, values?: Record<string, string | number>): string {
  const template = currentTable()[key] ?? en[key] ?? key;
  if (!values) return template;
  return template.replace(/\{(\w+)\}/g, (match, name: string) => (name in values ? String(values[name]) : match));
}
