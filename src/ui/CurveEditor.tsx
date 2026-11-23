import { useMemo } from 'react';
import { PanResponder, StyleSheet, View, type PanResponderInstance } from 'react-native';
import Svg, { Circle, Line, Path } from 'react-native-svg';

import { curveEvaluator } from '@/engine/color';
import { MAX_CURVE_POINTS, type CurvePoint } from '@/engine/state';
import { histogramPath } from './Histogram';
import { colors } from './theme';
import { useResponder } from './useResponder';

const PAD = 14;
const GRAB_RADIUS = 30;
const MIN_GAP = 0.02;
const DOUBLE_TAP_MS = 320;

export interface CurveEditorProps {
  size: number;
  points: CurvePoint[];
  color: string;
  /** Histogram bins to draw behind the curve. */
  backdrop?: number[];
  onChange: (points: CurvePoint[]) => void;
  onCommit: () => void;
}

const clamp = (value: number, min: number, max: number): number => Math.min(max, Math.max(min, value));

/** Moves point `index` to (x, y), keeping it between its neighbours. */
export function movePoint(points: CurvePoint[], index: number, x: number, y: number): CurvePoint[] {
  const min = index === 0 ? 0 : points[index - 1][0] + MIN_GAP;
  const max = index === points.length - 1 ? 1 : points[index + 1][0] - MIN_GAP;
  const next = points.slice();
  next[index] = [Math.round(clamp(x, min, max) * 1000) / 1000, Math.round(clamp(y, 0, 1) * 1000) / 1000];
  return next;
}

/** Adds a point at (x, y) if there is room for one. Returns the new list and the point's index. */
export function insertPoint(points: CurvePoint[], x: number, y: number): { points: CurvePoint[]; index: number } | null {
  if (points.length >= MAX_CURVE_POINTS) return null;
  if (points.some((point) => Math.abs(point[0] - x) < MIN_GAP)) return null;
  const index = points.findIndex((point) => point[0] > x);
  const at = index === -1 ? points.length : index;
  const next = points.slice();
  next.splice(at, 0, [Math.round(clamp(x, 0, 1) * 1000) / 1000, Math.round(clamp(y, 0, 1) * 1000) / 1000]);
  return { points: next, index: at };
}

function createResponder(latest: () => CurveEditorProps): PanResponderInstance {
  let active: number | null = null;
  let moved = false;
  let lastTap: { index: number; at: number } | null = null;
  const toCurve = (px: number, py: number): [number, number] => {
    const span = latest().size - PAD * 2;
    return [(px - PAD) / span, 1 - (py - PAD) / span];
  };
  return PanResponder.create({
    onStartShouldSetPanResponder: () => true,
    onMoveShouldSetPanResponder: () => true,
    onPanResponderTerminationRequest: () => false,
    onPanResponderGrant: (event) => {
      const { locationX, locationY } = event.nativeEvent;
      const current = latest();
      const span = current.size - PAD * 2;
      let nearest = -1;
      let nearestDistance = GRAB_RADIUS;
      current.points.forEach((point, index) => {
        const distance = Math.hypot(PAD + point[0] * span - locationX, PAD + (1 - point[1]) * span - locationY);
        if (distance < nearestDistance) {
          nearest = index;
          nearestDistance = distance;
        }
      });
      moved = false;
      if (nearest >= 0) {
        active = nearest;
        return;
      }
      const [x, y] = toCurve(locationX, locationY);
      const inserted = insertPoint(current.points, clamp(x, 0, 1), clamp(y, 0, 1));
      if (inserted) {
        active = inserted.index;
        moved = true;
        current.onChange(inserted.points);
      } else {
        active = null;
      }
    },
    onPanResponderMove: (event, gesture) => {
      if (active === null) return;
      if (Math.abs(gesture.dx) + Math.abs(gesture.dy) < 2 && !moved) return;
      moved = true;
      const [x, y] = toCurve(event.nativeEvent.locationX, event.nativeEvent.locationY);
      const current = latest();
      current.onChange(movePoint(current.points, Math.min(active, current.points.length - 1), x, y));
    },
    onPanResponderRelease: () => {
      const index = active;
      active = null;
      const current = latest();
      if (index !== null && !moved) {
        const now = Date.now();
        if (lastTap && lastTap.index === index && now - lastTap.at < DOUBLE_TAP_MS && current.points.length > 2) {
          lastTap = null;
          current.onChange(current.points.filter((_, i) => i !== index));
          current.onCommit();
          return;
        }
        lastTap = { index, at: now };
        return;
      }
      if (moved) current.onCommit();
    },
  });
}

/**
 * A tone curve you edit by touch: drag a point, touch the line to add one, double-tap a point to
 * remove it.
 */
export function CurveEditor(props: CurveEditorProps) {
  const { size, points } = props;
  const inner = size - PAD * 2;
  const responder = useResponder(props, createResponder);

  const path = useMemo(() => {
    const evaluate = curveEvaluator(points);
    let d = '';
    for (let i = 0; i <= 64; i++) {
      const x = i / 64;
      d += `${i === 0 ? 'M' : 'L'}${(PAD + x * inner).toFixed(1)} ${(PAD + (1 - evaluate(x)) * inner).toFixed(1)}`;
    }
    return d;
  }, [points, inner]);

  return (
    <View style={[styles.box, { width: size, height: size }]} {...responder.panHandlers} testID="curve-editor" accessibilityLabel="Tone curve">
      <View pointerEvents="none">
        <Svg width={size} height={size}>
          {props.backdrop ? (
            <Svg x={PAD} y={PAD} width={inner} height={inner} viewBox="0 0 255 100" preserveAspectRatio="none">
              <Path d={histogramPath(props.backdrop)} fill={colors.faint} opacity={0.35} />
            </Svg>
          ) : null}
          {[0.25, 0.5, 0.75].map((line) => (
            <Line key={`v${line}`} x1={PAD + line * inner} y1={PAD} x2={PAD + line * inner} y2={PAD + inner} stroke={colors.border} strokeWidth={1} />
          ))}
          {[0.25, 0.5, 0.75].map((line) => (
            <Line key={`h${line}`} x1={PAD} y1={PAD + line * inner} x2={PAD + inner} y2={PAD + line * inner} stroke={colors.border} strokeWidth={1} />
          ))}
          <Line x1={PAD} y1={PAD + inner} x2={PAD + inner} y2={PAD} stroke={colors.faint} strokeWidth={1} strokeDasharray="4 4" />
          <Path d={path} stroke={props.color} strokeWidth={2} fill="none" />
          {points.map((point, index) => (
            <Circle key={index} cx={PAD + point[0] * inner} cy={PAD + (1 - point[1]) * inner} r={6} fill={colors.background} stroke={props.color} strokeWidth={2} />
          ))}
        </Svg>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  box: { backgroundColor: colors.surface, borderRadius: 10, borderWidth: StyleSheet.hairlineWidth, borderColor: colors.border },
});
