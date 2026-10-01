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
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import {
  Camera,
  CommonResolutions,
  useCameraDevices,
  useFrameOutput,
  type Frame,
} from 'react-native-vision-camera';
import { ClearAheadVision } from 'react-native-clear-ahead-vision';
import { PrimaryButton } from '../components/Controls';
import { SoundField } from '../components/SoundField';
import { colors, toFeedbackConfiguration } from '../config';
import { ClearAheadModule } from '../native/ClearAheadModule';
import type {
  AppPreferences,
  ObjectDetectionOverlay,
  PipelineMetrics,
  SessionQuality,
  SessionState,
  SpatialEvent,
} from '../types';
import { describeEvent, qualityMessage } from '../utils/eventLogic';
import { cameraStartedMessage } from '../utils/sessionStatus';
import { chooseRearCamera } from '../utils/cameraSelection';
import { AnnouncementGate } from '../utils/announcements';
import { SessionController } from '../utils/sessionController';

export function AssistScreen({
  preferences,
  onMetrics,
  onStop,
}: {
  preferences: AppPreferences;
  onMetrics: (metrics: PipelineMetrics) => void;
  onStop: () => void;
}) {
  const [sessionState, setSessionState] = useState<SessionState>('starting');
  const [statusMessage, setStatusMessage] = useState('Starting camera');
  const [quality, setQuality] = useState<SessionQuality>('good');
  const [event, setEvent] = useState<SpatialEvent>();
  const [metrics, setMetrics] = useState<PipelineMetrics>();
  const [detections, setDetections] = useState<ObjectDetectionOverlay[]>([]);
  const [depthMapDataUrl, setDepthMapDataUrl] = useState<string>();
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
  const cameraDevices = useCameraDevices();
  const cameraDevice = useMemo(() => {
    return chooseRearCamera(cameraDevices, preferences.cameraDeviceId);
  }, [cameraDevices, preferences.cameraDeviceId]);

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
    enablePreviewSizedOutputBuffers: true,
    onFrame: processFrame,
    onFrameDropped(reason) {
      ClearAheadVision.reportDroppedFrame(reason);
    },
  });
  const cameraConstraints = useMemo(
    () => [{ fps: preferences.processingMode === 'responsive' ? 15 : 30 }],
    [preferences.processingMode],
  );
  const cameraOutputs = useMemo(() => [frameOutput], [frameOutput]);

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
        if (announcements.current.event(payload, Date.now() / 1000)) {
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
      ...(preferences.showBoundingBoxes
        ? [ClearAheadModule.onDetections(setDetections)]
        : []),
      ...(preferences.depthMapEnabled
        ? [
            ClearAheadModule.onDepthMap(payload =>
              setDepthMapDataUrl(payload.dataUrl ?? undefined),
            ),
          ]
        : []),
      ClearAheadModule.onModelDownload(payload =>
        setStatusMessage(payload.message),
      ),
    ];

    const configuration = toFeedbackConfiguration(preferences);
    const controller = new SessionController(
      () => ClearAheadModule.updateConfiguration(configuration),
      () => ClearAheadModule.startSession(configuration),
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
        setDetections([]);
        setDepthMapDataUrl(undefined);
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
  }, [cameraDevice, onMetrics, preferences]);

  const eventDescription = useMemo(
    () => (event ? describeEvent(event) : 'Field clear'),
    [event],
  );
  const statusHasWarning =
    sessionState === 'error' ||
    latestStatus.current?.severity === 'warning' ||
    latestStatus.current?.severity === 'error';
  const displayedStatus =
    statusHasWarning || quality === 'good'
      ? statusMessage
      : qualityMessage(quality);

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
            setStatusMessage(current =>
              cameraStartedMessage(current, latestStatus.current),
            );
          }}
          onError={error => {
            startupError.current = true;
            setSessionState('error');
            setStatusMessage(error.message);
            sessionController.current?.stop().catch(() => undefined);
            setEvent(undefined);
            setDetections([]);
            setDepthMapDataUrl(undefined);
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
            setDetections([]);
            setDepthMapDataUrl(undefined);
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
        depthMapDataUrl ? (
          <Image
            accessibilityElementsHidden
            importantForAccessibility="no-hide-descendants"
            source={{ uri: depthMapDataUrl }}
            resizeMode="cover"
            style={StyleSheet.absoluteFill}
          />
        ) : (
          <View style={[StyleSheet.absoluteFill, styles.depthLoading]} />
        )
      ) : null}
      <SoundField
        event={event}
        detections={detections}
        showBoundingBoxes={preferences.showBoundingBoxes}
        boundingBoxVerbosity={preferences.boundingBoxVerbosity}
      />
      <SafeAreaView pointerEvents="box-none" style={styles.safeArea}>
        <ScrollView contentContainerStyle={styles.assistContent}>
          <View
            accessible
            accessibilityLabel={`${statusMessage}. ${qualityMessage(quality)}`}
            style={styles.statusPill}
          >
            <View
              style={[
                styles.statusDot,
                quality !== 'good' && styles.statusDotWarning,
              ]}
            />
            <Text style={styles.statusText}>{displayedStatus}</Text>
            {metrics ? (
              <Text style={styles.latency}>
                Processing {Math.round(metrics.processingLatencyMs)} ms
              </Text>
            ) : null}
          </View>

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
              style={styles.fpsLine}
            >
              <Text style={styles.fpsText}>
                {metrics
                  ? `${metrics.cameraFps.toFixed(
                      0,
                    )} fps  ·  objects ${metrics.detectorFps.toFixed(
                      0,
                    )}  ·  depth ${metrics.depthFps.toFixed(0)}`
                  : 'Measuring performance…'}
              </Text>
            </View>
          ) : null}

          {preferences.depthMapEnabled ? (
            <View
              accessible
              accessibilityLabel="Depth colors: red is close, blue is far"
              style={styles.depthLegend}
            >
              <Text style={styles.depthNear}>CLOSE</Text>
              <View style={styles.depthLegendLine} />
              <Text style={styles.depthFar}>FAR</Text>
            </View>
          ) : null}

          <View style={styles.spacer} />

          <View style={styles.bottomGroup}>
            <View
              accessible
              accessibilityLabel={eventDescription}
              style={[
                styles.eventCard,
                event?.collisionRisk === 'caution' && styles.eventCardCaution,
                event?.collisionRisk === 'imminent' && styles.eventCardCritical,
              ]}
            >
              <View style={styles.eventHeader}>
                <Text style={styles.eventEyebrow}>
                  {event?.collisionRisk === 'imminent'
                    ? 'COLLISION LIKELY'
                    : event?.collisionRisk === 'caution'
                    ? 'POSSIBLE COLLISION'
                    : event
                    ? `${event.direction.toUpperCase()} · ${event.proximity.toUpperCase()}`
                    : 'FIELD CLEAR'}
                </Text>
                {!event ? <View style={styles.clearMark} /> : null}
              </View>
              <Text style={styles.eventTitle}>
                {event?.collisionRisk === 'imminent'
                  ? 'Stop'
                  : event?.collisionRisk === 'caution'
                  ? 'Caution'
                  : event
                  ? event.label ?? event.kind.replace('-', ' ')
                  : 'Listening'}
              </Text>
              {event ? (
                <Text style={styles.eventDescription}>{eventDescription}</Text>
              ) : null}
            </View>
          </View>
        </ScrollView>
        <PrimaryButton
          label={'Stop Assist Mode'}
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
  safeArea: { flex: 1, paddingHorizontal: 14, paddingVertical: 10 },
  assistContent: { flexGrow: 1, paddingBottom: 10 },
  statusPill: {
    minHeight: 44,
    alignSelf: 'stretch',
    borderRadius: 9,
    backgroundColor: '#080808E8',
    borderWidth: 1,
    borderColor: '#FFFFFF24',
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 12,
    gap: 8,
  },
  statusDot: {
    width: 7,
    height: 7,
    borderRadius: 4,
    backgroundColor: colors.cyan,
  },
  statusDotWarning: { backgroundColor: colors.amber },
  statusText: { color: colors.text, fontSize: 14, fontWeight: '700', flex: 1 },
  latency: {
    color: colors.muted,
    fontSize: 11,
    fontWeight: '700',
    fontVariant: ['tabular-nums'],
  },
  fpsLine: {
    alignSelf: 'flex-start',
    marginTop: 7,
    paddingHorizontal: 9,
    paddingVertical: 5,
    borderRadius: 6,
    backgroundColor: '#080808CC',
  },
  fpsText: {
    color: '#D4D4D4',
    fontSize: 10,
    fontWeight: '600',
    fontVariant: ['tabular-nums'],
  },
  depthLegend: {
    alignSelf: 'flex-start',
    flexDirection: 'row',
    alignItems: 'center',
    gap: 7,
    marginTop: 7,
    paddingHorizontal: 9,
    paddingVertical: 5,
    borderRadius: 6,
    backgroundColor: '#080808CC',
  },
  depthLegendLine: { width: 42, height: 3, backgroundColor: '#8A208A' },
  depthNear: { color: '#FF4545', fontSize: 10, fontWeight: '800' },
  depthFar: { color: '#3291FF', fontSize: 10, fontWeight: '800' },
  spacer: { flex: 1 },
  bottomGroup: { gap: 10 },
  eventCard: {
    backgroundColor: '#080808E8',
    borderWidth: 1,
    borderColor: '#FFFFFF24',
    borderLeftWidth: 3,
    borderLeftColor: colors.cyan,
    borderRadius: 10,
    paddingHorizontal: 14,
    paddingVertical: 12,
  },
  eventCardCaution: { borderLeftColor: colors.amber },
  eventCardCritical: { borderLeftColor: colors.critical },
  eventHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  clearMark: {
    width: 7,
    height: 7,
    borderRadius: 4,
    backgroundColor: colors.cyan,
  },
  eventEyebrow: {
    color: colors.cyan,
    fontSize: 10,
    fontWeight: '800',
    letterSpacing: 1.4,
  },
  eventTitle: {
    color: colors.text,
    fontSize: 24,
    lineHeight: 29,
    fontWeight: '800',
    textTransform: 'capitalize',
    marginTop: 2,
  },
  eventDescription: {
    color: '#D4D4D4',
    fontSize: 14,
    lineHeight: 19,
    marginTop: 2,
  },
});
