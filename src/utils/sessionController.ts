export class SessionController {
  private generation = 0;
  private configure: () => Promise<void>;
  private startNative: () => Promise<void>;
  private stopNative: () => Promise<void>;

  constructor(
    configure: () => Promise<void>,
    startNative: () => Promise<void>,
    stopNative: () => Promise<void>,
  ) {
    this.configure = configure;
    this.startNative = startNative;
    this.stopNative = stopNative;
  }

  async start(): Promise<boolean> {
    const generation = ++this.generation;
    await this.configure();
    if (generation !== this.generation) {
      return false;
    }
    await this.startNative();
    return generation === this.generation;
  }

  async stop(): Promise<void> {
    this.generation++;
    await this.stopNative();
  }
}

export async function runFeedbackTest(
  session: SessionController,
  signal: AbortSignal,
  duration = 2200,
): Promise<void> {
  let stopped = false;
  const stop = () => {
    stopped = true;
    session.stop().catch(() => undefined);
  };
  signal.addEventListener('abort', stop);
  try {
    if (signal.aborted || !(await session.start()) || signal.aborted) {
      return;
    }
    await new Promise<void>(resolve => {
      const finish = () => {
        clearTimeout(timer);
        signal.removeEventListener('abort', finish);
        resolve();
      };
      const timer = setTimeout(finish, duration);
      signal.addEventListener('abort', finish);
      if (signal.aborted) {
        finish();
      }
    });
  } finally {
    signal.removeEventListener('abort', stop);
    if (!stopped) {
      await session.stop();
    }
  }
}
