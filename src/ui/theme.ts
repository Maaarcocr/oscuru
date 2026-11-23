/** One dark look: the photo is the only bright thing on screen. */
export const colors = {
  background: '#0B0B0C',
  surface: '#151517',
  raised: '#212125',
  border: '#2C2C31',
  text: '#F2F2F3',
  dim: '#9B9BA3',
  faint: '#5E5E66',
  accent: '#E3A857',
  onAccent: '#1A1206',
  danger: '#FF6B5E',
  good: '#6FCF97',
} as const;

export const spacing = { xs: 4, s: 8, m: 12, l: 16, xl: 24 } as const;

export const radius = { s: 8, m: 12, l: 18 } as const;

export const font = {
  mono: 'ui-monospace',
} as const;
