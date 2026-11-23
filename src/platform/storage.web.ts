/** Browser preview only: everything lives in localStorage. Do not ship secrets this way. */

export const getSecret = async (name: string): Promise<string | null> => localStorage.getItem(`secret:${name}`);
export const setSecret = async (name: string, value: string): Promise<void> => localStorage.setItem(`secret:${name}`, value);
export const deleteSecret = async (name: string): Promise<void> => localStorage.removeItem(`secret:${name}`);

export function readJSON(name: string): unknown {
  try {
    const text = localStorage.getItem(`json:${name}`);
    return text === null ? undefined : JSON.parse(text);
  } catch {
    return undefined;
  }
}

export function writeJSON(name: string, value: unknown): void {
  localStorage.setItem(`json:${name}`, JSON.stringify(value));
}

export async function readBase64(uri: string): Promise<string> {
  const blob = await (await fetch(uri)).blob();
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error);
    reader.onload = () => resolve(String(reader.result).split(',')[1] ?? '');
    reader.readAsDataURL(blob);
  });
}
