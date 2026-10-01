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
