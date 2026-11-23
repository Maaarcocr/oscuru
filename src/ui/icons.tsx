import Svg, { Circle, Path, Rect } from 'react-native-svg';

import { colors } from './theme';

/** Line icons on a 24 × 24 grid, drawn here so they look the same everywhere. */
const ICONS = {
  back: <Path d="M15 5l-7 7 7 7" />,
  close: <Path d="M6 6l12 12M18 6L6 18" />,
  check: <Path d="M5 12.5l4.5 4.5L19 7.5" />,
  plus: <Path d="M12 5v14M5 12h14" />,
  undo: <Path d="M9 7L4.5 11.5 9 16M5 11.5h8.5a5.5 5.5 0 010 11H11" transform="translate(0 -3)" />,
  redo: <Path d="M15 7l4.5 4.5L15 16M19 11.5h-8.5a5.5 5.5 0 000 11H13" transform="translate(0 -3)" />,
  compare: (
    <>
      <Rect x="4" y="5" width="16" height="14" rx="2" />
      <Path d="M12 3v18" />
    </>
  ),
  share: <Path d="M12 15V4M8 7.5L12 3.5l4 4M6 11H5v9h14v-9h-1" />,
  settings: (
    <>
      <Path d="M4 7h9M17 7h3M4 17h3M11 17h9" />
      <Circle cx="15" cy="7" r="2" />
      <Circle cx="9" cy="17" r="2" />
    </>
  ),
  trash: <Path d="M5 7h14M10 7V4.5h4V7M7 7l1 12.5h8L17 7" />,
  assistant: <Path d="M10 4l1.6 4.4L16 10l-4.4 1.6L10 16l-1.6-4.4L4 10l4.4-1.6zM18 14l.8 2.2L21 17l-2.2.8L18 20l-.8-2.2L15 17l2.2-.8z" />,
  light: (
    <>
      <Circle cx="12" cy="12" r="3.5" />
      <Path d="M12 3.5v2M12 18.5v2M3.5 12h2M18.5 12h2M6 6l1.4 1.4M16.6 16.6L18 18M6 18l1.4-1.4M16.6 7.4L18 6" />
    </>
  ),
  color: <Path d="M12 3.5c3 3.6 5.5 6.3 5.5 9.3a5.5 5.5 0 01-11 0c0-3 2.500-5.700 5.500-9.300z" />,
  curves: (
    <>
      <Rect x="4" y="4" width="16" height="16" rx="2" />
      <Path d="M4.500 19.500C10 19.500 9 12 12 12s2-7.500 7.500-7.500" />
    </>
  ),
  hsl: (
    <>
      <Circle cx="12" cy="8.5" r="4.500" />
      <Circle cx="8.500" cy="14.500" r="4.500" />
      <Circle cx="15.500" cy="14.500" r="4.500" />
    </>
  ),
  grading: (
    <>
      <Circle cx="12" cy="12" r="8" />
      <Path d="M12 4v16M12 8l6.500 0M12 12h8M12 16h6.500" />
    </>
  ),
  detail: <Path d="M12 4l8 14H4zM12 10v4" />,
  crop: <Path d="M7 3v14h14M3 7h14v14" />,
  rotateLeft: <Path d="M5 5v5h5M5.500 10A7.500 7.500 0 1112 19.500" />,
  rotateRight: <Path d="M19 5v5h-5M18.500 10A7.500 7.500 0 1012 19.500" />,
  flipHorizontal: <Path d="M12 3v18M9 7l-5 5 5 5zM15 7l5 5-5 5z" />,
  flipVertical: <Path d="M3 12h18M7 9l5-5 5 5zM7 15l5 5 5-5z" />,
  stop: <Rect x="7" y="7" width="10" height="10" rx="1.500" />,
  send: <Path d="M12 19V5M6 11l6-6 6 6" />,
  histogram: <Path d="M4 20V14M8 20V9M12 20V4M16 20v-9M20 20v-5" />,
  chevronDown: <Path d="M6 9l6 6 6-6" />,
  chevronUp: <Path d="M6 15l6-6 6 6" />,
  reset: <Path d="M5 5v5h5M5.500 10A7.500 7.500 0 1112 19.500M12 9v3.500l2.500 1.500" />,
  photo: (
    <>
      <Rect x="3.500" y="5" width="17" height="14" rx="2" />
      <Circle cx="9" cy="10" r="1.500" />
      <Path d="M4 17l5-4.500 3.500 3 3-2.500 4.500 4" />
    </>
  ),
  folder: <Path d="M3.500 7V18.500h17V8.500h-8L10.500 6H3.500z" />,
} as const;

export type IconName = keyof typeof ICONS;

export function Icon(props: { name: IconName; size?: number; color?: string }) {
  return (
    <Svg width={props.size ?? 22} height={props.size ?? 22} viewBox="0 0 24 24" fill="none" stroke={props.color ?? colors.text} strokeWidth={1.7} strokeLinecap="round" strokeLinejoin="round">
      {ICONS[props.name]}
    </Svg>
  );
}
