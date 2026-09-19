import {
  NativeEventEmitter,
  NativeModules,
  type EmitterSubscription,
} from 'react-native';
import type {
  DemoScenario,
  FeedbackConfiguration,
  PipelineMetrics,
  QualityPayload,
  SessionStatusPayload,
  SpatialEvent,
} from '../types';

interface ClearAheadNativeModule {
  startSession(configuration: FeedbackConfiguration): Promise<void>;
  stopSession(): Promise<void>;
  updateConfiguration(configuration: FeedbackConfiguration): Promise<void>;
  startDemo(scenario: DemoScenario): Promise<void>;
  stopDemo(): Promise<void>;
  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

const nativeModule = NativeModules.ClearAheadModule as
  | ClearAheadNativeModule
  | undefined;

const emitter = nativeModule ? new NativeEventEmitter(nativeModule) : undefined;

function subscribe<T>(
  eventName: string,
  listener: (payload: T) => void,
): EmitterSubscription | undefined {
  return emitter?.addListener(eventName, (...args: readonly Object[]) => {
    listener(args[0] as T);
  });
}

function unavailable(): Promise<never> {
  return Promise.reject(
    new Error('Clear Ahead native module is unavailable on this platform.'),
  );
}

export const ClearAheadModule = {
  isAvailable: nativeModule != null,
  startSession: (configuration: FeedbackConfiguration) =>
    nativeModule?.startSession(configuration) ?? unavailable(),
  stopSession: () => nativeModule?.stopSession() ?? unavailable(),
  updateConfiguration: (configuration: FeedbackConfiguration) =>
    nativeModule?.updateConfiguration(configuration) ?? unavailable(),
  startDemo: (scenario: DemoScenario) =>
    nativeModule?.startDemo(scenario) ?? unavailable(),
  stopDemo: () => nativeModule?.stopDemo() ?? unavailable(),
  onStatus(listener: (payload: SessionStatusPayload) => void): EmitterSubscription | undefined {
    return subscribe('sessionStatus', listener);
  },
  onEvent(listener: (payload: SpatialEvent) => void): EmitterSubscription | undefined {
    return subscribe('topEvent', listener);
  },
  onEventCleared(listener: () => void): EmitterSubscription | undefined {
    return subscribe('eventCleared', listener);
  },
  onQuality(listener: (payload: QualityPayload) => void): EmitterSubscription | undefined {
    return subscribe('qualityChanged', listener);
  },
  onMetrics(listener: (payload: PipelineMetrics) => void): EmitterSubscription | undefined {
    return subscribe('performanceMetrics', listener);
  },
};
