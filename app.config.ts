import type { ConfigContext, ExpoConfig } from 'expo/config';

/**
 * app.json holds the static configuration. This adds what depends on the EAS project: over-the-air
 * updates are switched on only once the project is linked (`eas init` writes the id into app.json,
 * or CI passes EAS_PROJECT_ID), so a fresh checkout still builds and runs.
 */
export default ({ config }: ConfigContext): ExpoConfig => {
  const projectId = process.env.EAS_PROJECT_ID || (config.extra?.eas as { projectId?: string } | undefined)?.projectId;
  return {
    ...config,
    name: config.name ?? 'Oscuru',
    slug: config.slug ?? 'oscuru',
    updates: projectId ? { url: `https://u.expo.dev/${projectId}`, fallbackToCacheTimeout: 0 } : { enabled: false },
    extra: { ...config.extra, ...(projectId ? { eas: { projectId } } : {}) },
  };
};
