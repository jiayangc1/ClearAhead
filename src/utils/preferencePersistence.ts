export function createSerializedWriter(
  write: (value: string) => Promise<void>,
): (value: string) => Promise<void> {
  let queue = Promise.resolve();
  return value => {
    const result = queue.then(() => write(value));
    queue = result.catch(() => undefined);
    return result;
  };
}
