import React, {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import {
  AccessibilityInfo,
  AppState,
  Image,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { Volume2, VolumeX } from 'lucide-react-native';
import {
  Camera,
  CommonResolutions,
  useCameraDevices,
  useFrameOutput,
  useDepthOutput,
  type Frame,
} from 'react-native-vision-camera';
import { ClearAheadVision } from 'react-native-clear-ahead-vision';
import { PrimaryButton } from '../components/Controls';
import { SpringPressable } from '../components/Motion';
import { SoundField } from '../components/SoundField';
import { LoadingBar } from '../components/LoadingBar';
import { colors, toFeedbackConfiguration } from '../config';
import { ClearAheadModule } from '../native/ClearAheadModule';
import type {
  AppPreferences,
  DepthMapPayload,
  ScenePayload,
  PipelineMetrics,
  SessionQuality,
  SessionState,
  SpatialEvent,
} from '../types';
import { describeEvent, qualityMessage, summarizeEvent } from '../utils/eventLogic';
import { cameraStartedMessage } from '../utils/sessionStatus';
import { chooseRearCamera } from '../utils/cameraSelection';
import { AnnouncementGate } from '../utils/announcements';
import { SessionController } from '../utils/sessionController';

// Capture at 30 fps in both modes; the native throttle decides how many of
// those frames the models process.
const cameraConstraints = [{ fps: 30 }, { videoStabilizationMode: 'off' as const }];
// Matches the native depth preview ramp, nearest to farthest.
const DEPTH_SPECTRUM = ['#FF0000', '#FF8000', '#FFFF00', '#00FF00', '#00FFFF', '#0000FF'];

export function AssistScreen({
  preferences,
  onChange,
  onMetrics,
  onStop,
}: {
  preferences: AppPreferences;
  onChange: (update: Partial<AppPreferences>) => void;
  onMetrics: (metrics: PipelineMetrics) => void;
  onStop: () => void;
}) {
  const [sessionState, setSessionState] = useState<SessionState>('starting');
  const [statusMessage, setStatusMessage] = useState('Starting camera');
  const [quality, setQuality] = useState<SessionQuality>('good');
  const [event, setEvent] = useState<SpatialEvent>();
  const [metrics, setMetrics] = useState<PipelineMetrics>();
  const [scene, setScene] = useState<ScenePayload>();
  const [loadProgress, setLoadProgress] = useState(0);
  const [depthMap, setDepthMap] = useState<DepthMapPayload>();
  const [lidarUnavailable, setLidarUnavailable] = useState(false);
  const latestMetrics = useRef<PipelineMetrics | undefined>(undefined);
  const [isForeground, setIsForeground] = useState(
    AppState.currentState === 'active',
  );
  const previousQuality = useRef(quality);
  const announcements = useRef(new AnnouncementGate());
  const announcedRisk = useRef<SpatialEvent['collisionRisk']>('none');
  const sessionController = useRef<SessionController | undefined>(undefined);
  const startupError = useRef(false);
  const cameraInterrupted = useRef(false);
  const latestStatus = useRef<
    import('../types').SessionStatusPayload | undefined
  >(undefined);
  const configuration = useMemo(() => toFeedbackConfiguration(preferences), [preferences]);
  const latestConfiguration = useRef(configuration);
  const cameraDevices = useCameraDevices();
  const cameraDevice = useMemo(() => {
    return chooseRearCamera(cameraDevices, preferences.cameraDeviceId, preferences.lidarEnabled && !lidarUnavailable);
  }, [cameraDevices, preferences.cameraDeviceId, preferences.lidarEnabled, lidarUnavailable]);
  const usesLidar = preferences.lidarEnabled && !lidarUnavailable && cameraDevice?.type === 'lidar-depth'
    && cameraDevice.mediaTypes.includes('depth');

  useEffect(() => {
    if (
      quality !== previousQuality.current &&
      quality !== 'good' &&
      announcements.current.message(qualityMessage(quality), Date.now() / 1000)
    ) {
      AccessibilityInfo.announceForAccessibilityWithOptions(qualityMessage(quality), { queue: true });
    }
    previousQuality.current = quality;
  }, [quality]);

  useEffect(() => {
    if (
      sessionState === 'error' &&
      announcements.current.message(statusMessage, Date.now() / 1000)
    ) {
      AccessibilityInfo.announceForAccessibilityWithOptions(statusMessage, { queue: true });
    }
  }, [sessionState, statusMessage]);

  const processFrame = useCallback((frame: Frame) => {
    'worklet';
    try {
      ClearAheadVision.processFrame(frame);
    } finally {
      frame.dispose();
    }
  }, []);

  const frameOutput = useFrameOutput({
    targetResolution:
      preferences.processingMode === 'responsive'
        ? CommonResolutions.VGA_16_9
        : CommonResolutions.HD_16_9,
    pixelFormat: 'yuv',
    dropFramesWhileBusy: true,
    enablePreviewSizedOutputBuffers: !usesLidar,
    enableCameraMatrixDelivery: true,
    onFrame: processFrame,
    onFrameDropped(reason) {
      ClearAheadVision.reportDroppedFrame(reason);
    },
  });
  const depthOutput = useDepthOutput({
    targetResolution: CommonResolutions.VGA_16_9,
    enableFiltering: true,
    onDepth(depth) {
      'worklet';
      depth.dispose();
    },
    onDepthFrameDropped() {},
  });
  const cameraOutputs = useMemo(() => usesLidar ? [frameOutput, depthOutput] : [frameOutput],
    [frameOutput, depthOutput, usesLidar]);

  // Feedback changes made on this screen reach the running session directly;
  // restarting it would drop every tracked hazard.
  useEffect(() => {
    latestConfiguration.current = configuration;
    ClearAheadModule.updateConfiguration(configuration).catch(() => undefined);
  }, [configuration]);

  useEffect(() => {
    let active = true;
    const subscriptions = [
      ClearAheadModule.onStatus(payload => {
        if (!active || AppState.currentState !== 'active') {
          return;
        }
        if (
          (startupError.current || cameraInterrupted.current) &&
          payload.state === 'idle'
        ) {
          return;
        }
        latestStatus.current = payload;
        setSessionState(payload.state);
        setStatusMessage(payload.message);
        if (
          (payload.severity === 'warning' || payload.severity === 'error') &&
          announcements.current.message(
            payload.message,
            Date.now() / 1000,
            payload.severity === 'error',
          )
        ) {
          AccessibilityInfo.announceForAccessibilityWithOptions(payload.message, { queue: true });
        }
      }),
      ClearAheadModule.onEvent(payload => {
        setEvent(payload);
        // Unnamed surfaces stay on the card and in the tones; VoiceOver names
        // one only when it is on a collision course. A surface that is merely
        // close carries caution without a time to collision.
        const quietSurface =
          payload.label === 'surface' &&
          (payload.collisionRisk === 'none' || payload.timeToCollisionSeconds == null);
        if (!quietSurface && announcements.current.event(payload, Date.now() / 1000)) {
          AccessibilityInfo.announceForAccessibilityWithOptions(describeEvent(payload), {
            queue: payload.collisionRisk !== 'imminent' || announcedRisk.current === 'imminent',
          });
          announcedRisk.current = payload.collisionRisk;
        }
      }),
      ClearAheadModule.onEventCleared(() => {
        setEvent(undefined);
        announcements.current.clear();
      }),
      ClearAheadModule.onQuality(payload => setQuality(payload.quality)),
      ClearAheadModule.onMetrics(payload => {
        setMetrics(payload);
        latestMetrics.current = payload;
      }),
      ClearAheadModule.onScene(setScene),
      ...(preferences.depthMapEnabled
        ? [
            ClearAheadModule.onDepthMap(setDepthMap),
          ]
        : []),
      ClearAheadModule.onModelDownload(payload => {
        setStatusMessage(payload.message);
        setLoadProgress(current => Math.max(current, payload.progress));
      }),
    ];

    const controller = new SessionController(
      () => ClearAheadModule.updateConfiguration(latestConfiguration.current),
      () => ClearAheadModule.startSession(latestConfiguration.current),
      () => ClearAheadModule.stopSession(),
    );
    sessionController.current = controller;
    const startNativeSession = () => {
      startupError.current = false;
      if (!cameraDevice) {
        return Promise.reject(
          new Error('No rear camera available. Assist mode cannot start.'),
        );
      }
      return controller.start();
    };
    const handleStartError = (error: unknown) => {
      if (!active || AppState.currentState !== 'active') {
        return;
      }
      setSessionState('error');
      startupError.current = true;
      setStatusMessage(
        error instanceof Error ? error.message : 'Session could not start',
      );
    };

    if (AppState.currentState === 'active') {
      startNativeSession().catch(handleStartError);
    }

    const appStateSubscription = AppState.addEventListener('change', next => {
      setIsForeground(next === 'active');
      if (next !== 'active') {
        cameraInterrupted.current = false;
        controller.stop().catch(() => undefined);
        setEvent(undefined);
        setScene(undefined);
        setDepthMap(undefined);
        announcements.current.clear();
        setSessionState('paused');
        setStatusMessage('Paused while Clear Ahead is in the background');
        AccessibilityInfo.announceForAccessibility(
          'Assist mode paused because Clear Ahead left the foreground.',
        );
      } else {
        setSessionState('starting');
        setStatusMessage('Restarting camera');
        startNativeSession()
          .then(started => {
            if (active && started) {
              AccessibilityInfo.announceForAccessibility(
                'Assist mode resumed.',
              );
            }
          })
          .catch(handleStartError);
      }
    });

    return () => {
      active = false;
      subscriptions.forEach(subscription => subscription?.remove());
      appStateSubscription.remove();
      controller.stop().catch(() => undefined);
      if (latestMetrics.current) {
        onMetrics(latestMetrics.current);
      }
    };
  }, [cameraDevice, onMetrics, preferences.depthMapEnabled, preferences.modelVariant]);

  const risk = event?.collisionRisk ?? 'none';
  const sceneClear = !event && scene?.state === 'clear';
  const cardTitle =
    risk === 'imminent' ? 'Stop'
    : risk === 'caution' ? 'Careful'
    : event ? summarizeEvent(event)
    : sceneClear ? 'Path clear'
    : sessionState === 'starting' ? 'Starting' : 'Looking';
  const cardDetail = risk !== 'none' && event ? summarizeEvent(event) : undefined;
  const cardLabel = event
    ? describeEvent(event)
    : sceneClear ? 'Path clear. Nothing nearby in the camera view.' : 'Scene unavailable';
  // Voice can be silenced here only while another kind of feedback remains.
  const canMuteVoice = preferences.audioEnabled || preferences.hapticsEnabled;
  const statusHasWarning =
    sessionState === 'error' ||
    latestStatus.current?.severity === 'warning' ||
    latestStatus.current?.severity === 'error';
  const displayedStatus = statusHasWarning
    ? statusMessage
    : quality !== 'good'
    ? qualityMessage(quality)
    : sessionState === 'running'
    ? 'Watching the path'
    : statusMessage;

  const stop = () => {
    (sessionController.current?.stop() ?? ClearAheadModule.stopSession())
      .catch(() => undefined)
      .finally(onStop);
  };

  return (
    <View style={styles.root}>
      {cameraDevice ? (
        <Camera
          style={StyleSheet.absoluteFill}
          device={cameraDevice}
          isActive={
            isForeground && sessionState !== 'idle' && sessionState !== 'error'
          }
          constraints={cameraConstraints}
          outputs={cameraOutputs}
          resizeMode="cover"
          onStarted={() => {
            if (usesLidar) {
              try {
                ClearAheadVision.connectDepthOutputs(frameOutput, depthOutput);
              } catch {
                setLidarUnavailable(true);
                setStatusMessage('LiDAR unavailable. Using the depth model.');
              }
            }
            setStatusMessage(current =>
              cameraStartedMessage(current, latestStatus.current),
            );
          }}
          onError={error => {
            if (usesLidar) {
              setLidarUnavailable(true);
              setSessionState('starting');
              setStatusMessage('LiDAR capture unavailable. Restarting with model depth.');
              setDepthMap(undefined);
              return;
            }
            startupError.current = true;
            setSessionState('error');
            setStatusMessage(error.message);
            sessionController.current?.stop().catch(() => undefined);
            setEvent(undefined);
            setScene(undefined);
            setDepthMap(undefined);
          }}
          onInterruptionStarted={() => {
            if (AppState.currentState !== 'active') {
              return;
            }
            cameraInterrupted.current = true;
            sessionController.current?.stop().catch(() => undefined);
            setSessionState('paused');
            setStatusMessage('Camera interrupted');
            setEvent(undefined);
            setScene(undefined);
            setDepthMap(undefined);
            announcements.current.clear();
          }}
          onInterruptionEnded={() => {
            cameraInterrupted.current = false;
            if (AppState.currentState !== 'active') {
              return;
            }
            startupError.current = false;
            setSessionState('starting');
            setStatusMessage('Waiting for camera frames');
            sessionController.current?.start().catch(error => {
              startupError.current = true;
              setSessionState('error');
              setStatusMessage(
                error instanceof Error
                  ? error.message
                  : 'Camera could not restart',
              );
            });
          }}
        />
      ) : null}
      {preferences.depthMapEnabled ? (
        depthMap?.dataUrl ? (
          <Image
            accessibilityElementsHidden
            importantForAccessibility="no-hide-descendants"
            source={{ uri: depthMap.dataUrl }}
            resizeMode="cover"
            style={StyleSheet.absoluteFill}
          />
        ) : (
          <View style={[StyleSheet.absoluteFill, styles.depthLoading]} />
        )
      ) : null}
      <SoundField
        scene={scene}
        showBoundingBoxes={preferences.showBoundingBoxes}
        boundingBoxVerbosity={preferences.boundingBoxVerbosity}
      />
      <SafeAreaView pointerEvents="box-none" style={styles.safeArea}>
        <View style={styles.topRow}>
          <View
            accessible
            accessibilityLabel={`${statusMessage}. ${qualityMessage(quality)}`}
            style={styles.statusPill}
          >
            <View
              style={[
                styles.statusDot,
                (quality !== 'good' || statusHasWarning) && styles.statusDotWarning,
              ]}
            />
            <Text numberOfLines={2} style={styles.statusText}>{displayedStatus}</Text>
          </View>
          {canMuteVoice || !preferences.speechEnabled ? (
            <SpringPressable
              accessibilityRole="switch"
              accessibilityLabel="Voice"
              accessibilityState={{ checked: preferences.speechEnabled }}
              accessibilityHint="Turns spoken warnings on or off. Sounds and vibration continue."
              hitSlop={6}
              onPress={() => onChange({ speechEnabled: !preferences.speechEnabled })}
              pressedScale={0.9}
              style={[styles.voiceButton, !preferences.speechEnabled && styles.voiceButtonOff]}
            >
              {preferences.speechEnabled
                ? <Volume2 color={colors.ink} size={24} strokeWidth={2} />
                : <VolumeX color={colors.muted} size={24} strokeWidth={2} />}
            </SpringPressable>
          ) : null}
        </View>

        {sessionState === 'starting' ? (
          <View style={styles.loading}><LoadingBar progress={loadProgress} message={statusMessage} /></View>
        ) : null}

        {preferences.showFps ? (
          <View
            accessible
            accessibilityLabel={
              metrics
                ? `Processed ${metrics.cameraFps.toFixed(
                    1,
                  )} frames per second. Objects ${metrics.detectorFps.toFixed(
                    1,
                  )} per second. Depth ${metrics.depthFps.toFixed(
                    1,
                  )} per second. ${metrics.droppedFrames} dropped frames.`
                : 'Waiting for frame rate measurements'
            }
            style={styles.diagnostics}
          >
            <Text style={styles.diagnosticsText}>
              {metrics
                ? `${metrics.cameraFps.toFixed(0)} fps · objects ${metrics.detectorFps.toFixed(
                    0,
                  )} · depth ${metrics.depthFps.toFixed(0)} · ${Math.round(metrics.processingLatencyMs)} ms`
                : 'Measuring performance…'}
            </Text>
            <Text style={styles.diagnosticsText}>
              {scene?.spatialCapability ?? 'Spatial audio initializing'}
              {' · '}{scene?.distanceStatus.replaceAll('-', ' ') ?? 'Distance unavailable'}
            </Text>
          </View>
        ) : null}

        {preferences.depthMapEnabled ? (
          <View
            accessible
            accessibilityLabel={depthMap?.dataUrl
              ? `Estimated depth in meters. Red: ${depthMap.nearMeters} meters or closer. Blue: ${depthMap.farMeters} meters or farther. ${depthMap.distanceStatus?.replaceAll('-', ' ')}`
              : 'Depth unavailable'}
            style={styles.depthLegend}
          >
            <Text style={styles.diagnosticsText}>{depthMap?.dataUrl ? `≤${depthMap.nearMeters} m` : 'Depth unavailable'}</Text>
            <View style={styles.depthLegendLine}>
              {DEPTH_SPECTRUM.map(color => (
                <View key={color} style={[styles.depthLegendStop, { backgroundColor: color }]} />
              ))}
            </View>
            <Text style={styles.diagnosticsText}>{depthMap?.dataUrl ? `≥${depthMap.farMeters} m` : ''}</Text>
          </View>
        ) : null}

        <View pointerEvents="none" style={styles.spacer} />

        <View
          accessible
          accessibilityLabel={cardLabel}
          style={[
            styles.eventCard,
            sceneClear && styles.eventCardClear,
            risk === 'caution' && styles.eventCardCaution,
            risk === 'imminent' && styles.eventCardCritical,
          ]}
        >
          <Text
            numberOfLines={2}
            adjustsFontSizeToFit
            style={[styles.eventTitle, risk !== 'none' && styles.eventTitleUrgent]}
          >
            {cardTitle}
          </Text>
          {cardDetail ? <Text style={styles.eventDetail}>{cardDetail}</Text> : null}
        </View>
        <PrimaryButton
          label="Stop"
          hint="Stops the camera and all feedback immediately"
          destructive
          onPress={stop}
        />
      </SafeAreaView>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.black },
  depthLoading: { backgroundColor: colors.black },
  safeArea: { flex: 1, paddingHorizontal: 16, paddingVertical: 10 },
  topRow: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  statusPill: {
    flex: 1,
    minHeight: 48,
    borderRadius: 24,
    backgroundColor: '#FAF7F2F2',
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 16,
    paddingVertical: 8,
    gap: 10,
  },
  statusDot: {
    width: 10,
    height: 10,
    borderRadius: 5,
    backgroundColor: colors.mintInk,
  },
  statusDotWarning: { backgroundColor: colors.peachInk },
  statusText: { color: colors.ink, fontSize: 15, lineHeight: 20, fontWeight: '600', flex: 1 },
  voiceButton: {
    width: 48,
    height: 48,
    borderRadius: 24,
    backgroundColor: colors.accent,
    alignItems: 'center',
    justifyContent: 'center',
  },
  voiceButtonOff: { backgroundColor: '#FAF7F2F2' },
  loading: {
    marginTop: 10,
    paddingHorizontal: 16,
    paddingVertical: 10,
    borderRadius: 20,
    backgroundColor: '#FAF7F2F2',
  },
  diagnostics: {
    alignSelf: 'flex-start',
    marginTop: 8,
    paddingHorizontal: 12,
    paddingVertical: 8,
    borderRadius: 14,
    backgroundColor: '#FAF7F2E6',
    gap: 2,
  },
  diagnosticsText: {
    color: colors.ink,
    fontSize: 11,
    fontWeight: '600',
    fontVariant: ['tabular-nums'],
  },
  depthLegend: {
    alignSelf: 'flex-start',
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    marginTop: 8,
    paddingHorizontal: 12,
    paddingVertical: 8,
    borderRadius: 14,
    backgroundColor: '#FAF7F2E6',
  },
  depthLegendLine: { width: 48, height: 4, borderRadius: 2, overflow: 'hidden', flexDirection: 'row' },
  depthLegendStop: { flex: 1 },
  spacer: { flex: 1 },
  eventCard: {
    minHeight: 112,
    justifyContent: 'center',
    backgroundColor: '#FAF7F2F2',
    borderRadius: 28,
    paddingHorizontal: 24,
    paddingVertical: 18,
    marginBottom: 12,
  },
  eventCardClear: { backgroundColor: colors.mint },
  eventCardCaution: { backgroundColor: colors.peach },
  eventCardCritical: { backgroundColor: colors.coral },
  eventTitle: {
    color: colors.ink,
    fontSize: 30,
    lineHeight: 36,
    fontWeight: '700',
    letterSpacing: -0.4,
  },
  eventTitleUrgent: { fontSize: 44, lineHeight: 50, letterSpacing: -1 },
  eventDetail: {
    color: colors.ink,
    fontSize: 18,
    lineHeight: 24,
    fontWeight: '500',
    marginTop: 2,
  },
});
