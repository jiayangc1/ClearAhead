import type { NormalizedBox } from '../types';

/** Match the camera's centered aspect-fill crop. */
export function projectSceneBox(box: NormalizedBox, imageAspect: number, viewAspect: number): NormalizedBox {
  const width = Math.max(imageAspect / viewAspect, 1);
  const height = Math.max(viewAspect / imageAspect, 1);
  return {
    x: box.x * width - (width - 1) / 2,
    y: box.y * height - (height - 1) / 2,
    width: box.width * width,
    height: box.height * height,
  };
}
