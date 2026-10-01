export function chooseRearCamera<
  T extends {
    id: string;
    position: string;
    type: string;
    focalLength?: number | null;
  },
>(devices: readonly T[], selection: string): T | undefined {
  const rear = devices.filter(device => device.position === 'back');
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
