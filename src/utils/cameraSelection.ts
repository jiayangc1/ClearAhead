export function chooseRearCamera<
  T extends {
    id: string;
    position: string;
    type: string;
    focalLength?: number | null;
    mediaTypes?: readonly string[];
  },
>(devices: readonly T[], selection: string, lidarEnabled = false): T | undefined {
  const rear = devices.filter(device => device.position === 'back');
  if (lidarEnabled && selection === 'standard') {
    const lidar = rear.find(device => device.type === 'lidar-depth' && device.mediaTypes?.includes('depth'));
    if (lidar) return lidar;
  }
  const explicit = rear.find(device => device.id === selection);
  if (explicit) {
    return explicit;
  }
  if (selection === 'widest') {
    return (
      rear.find(device => device.type === 'ultra-wide-angle') ??
      rear.sort(
        (left, right) =>
          (left.focalLength ?? Infinity) - (right.focalLength ?? Infinity),
      )[0]
    );
  }
  return rear.find(device => device.type === 'wide-angle') ?? rear[0];
}
