import { defaultState, setCrop, type CropSettings } from '@/engine/state';
import { cropAspect, cropForAspect, flipCrop, frameAspect, moveCrop, resizeCrop, rotateCrop } from '../crop';

const landscape = { width: 6000, height: 4000 };
const full = { x: 0, y: 0, width: 1, height: 1 };
const crop = (settings: Partial<CropSettings> = {}): CropSettings => setCrop(defaultState(), settings).crop;

describe('crop geometry', () => {
  it('knows the proportions of the frame and of the crop', () => {
    expect(frameAspect(landscape, crop())).toBeCloseTo(1.5);
    expect(frameAspect(landscape, crop({ rotation: 90 }))).toBeCloseTo(2 / 3);
    expect(cropAspect(landscape, crop({ width: 0.5 }))).toBeCloseTo(0.75);
  });

  it('fits the largest centred rectangle of given proportions', () => {
    expect(cropForAspect(1.5, 1)).toEqual({ x: 0.1667, y: 0, width: 0.6667, height: 1 });
    expect(cropForAspect(1.5, 16 / 9)).toEqual({ x: 0, y: 0.0781, width: 1, height: 0.8438 });
    expect(cropForAspect(1.5, 1.5)).toEqual(full);
    const square = cropForAspect(1.5, 1);
    expect(cropAspect(landscape, crop(square))).toBeCloseTo(1, 3);
  });

  it('moves a rectangle without letting it leave the frame', () => {
    const start = { x: 0.2, y: 0.2, width: 0.5, height: 0.5 };
    expect(moveCrop(start, 0.1, -0.1)).toEqual({ x: 0.3, y: 0.1, width: 0.5, height: 0.5 });
    expect(moveCrop(start, 5, 5)).toEqual({ x: 0.5, y: 0.5, width: 0.5, height: 0.5 });
    expect(moveCrop(start, -5, -5)).toEqual({ x: 0, y: 0, width: 0.5, height: 0.5 });
  });

  it('resizes from a corner, keeping the opposite corner fixed', () => {
    expect(resizeCrop(full, 'tl', 0.2, 0.1, null)).toEqual({ x: 0.2, y: 0.1, width: 0.8, height: 0.9 });
    expect(resizeCrop(full, 'br', -0.3, -0.4, null)).toEqual({ x: 0, y: 0, width: 0.7, height: 0.6 });
    expect(resizeCrop(full, 'tr', -0.25, 0.25, null)).toEqual({ x: 0, y: 0.25, width: 0.75, height: 0.75 });
    // Dragging outwards stops at the frame; dragging past the opposite corner stops at the smallest size.
    expect(resizeCrop(full, 'br', 1, 1, null)).toEqual(full);
    expect(resizeCrop(full, 'bl', 2, 0, null)).toEqual({ x: 0.95, y: 0, width: 0.05, height: 1 });
  });

  it('keeps locked proportions while resizing', () => {
    const start = { x: 0.1, y: 0.1, width: 0.6, height: 0.6 };
    const resized = resizeCrop(start, 'br', 0.2, 0, 1);
    expect(resized.width).toBeCloseTo(resized.height);
    expect(resized).toMatchObject({ x: 0.1, y: 0.1, width: 0.8 });
    // No room to grow taller: the width gives way instead.
    const limited = resizeCrop({ x: 0, y: 0.5, width: 0.4, height: 0.4 }, 'br', 0.5, 0, 1);
    expect(limited).toEqual({ x: 0, y: 0.5, width: 0.5, height: 0.5 });
  });

  it('turns the crop rectangle with the photo', () => {
    const start = crop({ x: 0.1, y: 0.2, width: 0.5, height: 0.3 });
    const right = rotateCrop(start, 'right');
    expect(right).toMatchObject({ rotation: 90, x: 0.5, y: 0.1, width: 0.3, height: 0.5 });
    expect(rotateCrop(right, 'left')).toMatchObject({ rotation: 0, x: 0.1, y: 0.2, width: 0.5, height: 0.3 });
    let turned = start;
    for (let i = 0; i < 4; i++) turned = rotateCrop(turned, 'right');
    expect(turned).toEqual(start);
    expect(rotateCrop(crop(), 'left').rotation).toBe(270);
  });

  it('mirrors what is on screen, whichever way the photo is turned', () => {
    const upright = flipCrop(crop({ x: 0.1, width: 0.5, angle: 3 }), 'horizontal');
    expect(upright).toMatchObject({ flipHorizontal: true, flipVertical: false, x: 0.4, angle: -3 });
    const sideways = flipCrop(crop({ rotation: 90, y: 0.2, height: 0.5 }), 'horizontal');
    expect(sideways).toMatchObject({ flipHorizontal: false, flipVertical: true });
    const vertical = flipCrop(crop({ y: 0.1, height: 0.5 }), 'vertical');
    expect(vertical).toMatchObject({ flipVertical: true, y: 0.4 });
    expect(flipCrop(upright, 'horizontal')).toMatchObject({ flipHorizontal: false, x: 0.1, angle: 3 });
  });

  it('always produces rectangles the editor accepts', () => {
    for (const rect of [resizeCrop(full, 'tl', 0.97, 0.97, 1.37), cropForAspect(1.5, 9 / 16), moveCrop({ x: 0.9, y: 0.9, width: 0.1, height: 0.1 }, 1, 1)]) {
      expect(() => crop(rect)).not.toThrow();
    }
  });
});
