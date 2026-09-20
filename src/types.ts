export type MountingMode = 'handheld' | 'chest';
export type ProcessingMode = 'responsive' | 'detailed';
export type Direction = 'left' | 'center' | 'right';
export type Proximity = 'near' | 'medium' | 'far' | 'unknown';
export type MotionState = 'stationary' | 'approaching' | 'receding' | 'crossing';
export type CollisionRisk = 'none' | 'caution' | 'imminent';
export type EventKind =
  | 'obstacle'
  | 'person'
  | 'vehicle'
  | 'furniture'
  | 'opening'
  | 'device-warning';

export type SessionState = 'idle' | 'starting' | 'running' | 'paused' | 'error';
export type SessionQuality =
  | 'good'
  | 'low-light'
  | 'camera-covered'
  | 'camera-too-close'
  | 'moving-too-fast'
  | 'thermal-limited'
  | 'overloaded';

export interface NormalizedBox {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface SpatialEvent {
  id: string;
  kind: EventKind;
  label?: string;
  direction: Direction;
  proximity: Proximity;
  approximateDistanceMeters?: number;
  approachSpeed: number;
  motionState: MotionState;
  collisionRisk: CollisionRisk;
  timeToCollisionSeconds?: number;
  trajectoryConfidence: number;
  confidence: number;
  urgency: number;
  timestamp: number;
  box?: NormalizedBox;
}

export interface PipelineMetrics {
  cameraFps: number;
  detectorFps: number;
  depthFps: number;
  droppedFrames: number;
  endToEndLatencyMs: number;
  thermalState: string;
  objectModelLoaded?: boolean;
  depthModelLoaded?: boolean;
  objectInferenceError?: string;
  depthInferenceError?: string;
}

export interface FeedbackConfiguration {
  version: 1;
  hapticsEnabled: boolean;
  audioEnabled: boolean;
  speechEnabled: boolean;
  hapticIntensity: number;
  audioVolume: number;
  sensitivity: number;
  warningDistanceMeters: number;
  feedbackFrequency: number;
  mountingMode: MountingMode;
  processingMode: ProcessingMode;
  spokenCategories: EventKind[];
}

export interface AppPreferences extends FeedbackConfiguration {
  onboardingComplete: boolean;
  showFps: boolean;
}

export interface SessionStatusPayload {
  state: SessionState;
  message: string;
  severity?: 'info' | 'warning' | 'error';
  code?: 'models-ready' | 'model-load-failed';
  diagnostics?: {
    objectModel: ModelDiagnostic;
    depthModel: ModelDiagnostic;
  };
}

export interface ModelDiagnostic {
  loaded: boolean;
  resource?: string;
  error?: string;
}

export interface QualityPayload {
  quality: SessionQuality;
  message: string;
}

export type DemoScenario = 'hallway' | 'crossing-person' | 'approaching-vehicle';
