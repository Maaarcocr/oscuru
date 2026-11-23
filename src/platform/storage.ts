/**
 * Where the app keeps small things: secrets in the keychain, settings as JSON files in the
 * documents directory. `storage.web.ts` is the stand-in used by the browser preview.
 */

import { File, Paths } from 'expo-file-system';
import * as SecureStore from 'expo-secure-store';

export const getSecret = (name: string): Promise<string | null> => SecureStore.getItemAsync(name);
export const setSecret = (name: string, value: string): Promise<void> => SecureStore.setItemAsync(name, value);
export const deleteSecret = (name: string): Promise<void> => SecureStore.deleteItemAsync(name);

const file = (name: string): File => new File(Paths.document, `${name}.json`);

export function readJSON(name: string): unknown {
  try {
    const target = file(name);
    return target.exists ? JSON.parse(target.textSync()) : undefined;
  } catch {
    return undefined;
  }
}

export function writeJSON(name: string, value: unknown): void {
  file(name).write(JSON.stringify(value));
}

/** The contents of a rendered file, for sending a preview to the model. */
export const readBase64 = (uri: string): Promise<string> => new File(uri).base64();
