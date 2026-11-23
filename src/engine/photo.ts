import type { PhotoDefaults } from './state';

/** What is known about an opened photo. Scripts read this through `getMetadata()`. */
export interface PhotoInfo {
  fileName: string;
  /** Uniform type identifier of the file, e.g. "com.adobe.raw-image". */
  typeIdentifier: string;
  isRaw: boolean;
  /** Full-resolution size, upright, before any crop. */
  width: number;
  height: number;
  /** White balance as recorded by the camera. Non-RAW photos report 6500 K and tint 0. */
  asShot: { temperature: number; tint: number };
  /** Where this photo's settings start: as-shot white balance and the RAW decoder's own detail settings. */
  defaults: PhotoDefaults;
  make?: string;
  model?: string;
  lens?: string;
  iso?: number;
  /** Shutter time in seconds. */
  exposureTime?: number;
  aperture?: number;
  focalLength?: number;
  focalLength35mm?: number;
  dateTaken?: string;
}
