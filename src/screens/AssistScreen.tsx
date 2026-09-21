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
  DemoScenario,
  ObjectDetectionOverlay,
  PipelineMetrics,
  SessionQuality,
  SessionState,
  SpatialEvent,
} from '../types';
import { describeEvent, qualityMessage } from '../utils/eventLogic';
import { cameraStartedMessage } from '../utils/sessionStatus';

export function AssistScreen({
  preferences,
  demoScenario,
  onMetrics,
  onStop,
}: {
  preferences: AppPreferences;
  demoScenario?: DemoScenario;
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
  const [isForeground, setIsForeground] = useState(
    AppState.currentState === 'active',
  );
  const isDemo = demoScenario != null;
  const previousQuality = useRef(quality);
  const latestStatus = useRef<
    import('../types').SessionStatusPayload | undefined
  >(undefined);
  const cameraDevices = useCameraDevices();
  const cameraDevice = useMemo(() => {
    const backDevices = cameraDevices
      .filter(device => device.position === 'back')
      .sort(
        (left, right) =>
          (left.focalLength ?? Number.MAX_VALUE) -
          (right.focalLength ?? Number.MAX_VALUE),
      );
    if (preferences.cameraDeviceId !== 'widest') {
      const selected = backDevices.find(
        device => device.id === preferences.cameraDeviceId,
      );
      if (selected) {
        return selected;
      }
    }
    return (
      backDevices.find(device => device.type === 'ultra-wide-angle') ??
      backDevices[0]
    );
  }, [cameraDevices, preferences.cameraDeviceId]);

  useEffect(() => {
    if (quality !== previousQuality.current && quality !== 'good') {
      AccessibilityInfo.announceForAccessibility(qualityMessage(quality));
    }
    previousQuality.current = quality;
  }, [quality]);

  useEffect(() => {
    if (sessionState === 'error') {
      AccessibilityInfo.announceForAccessibility(statusMessage);
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
        latestStatus.current = payload;
        setSessionState(payload.state);
        setStatusMessage(payload.message);
      }),
      ClearAheadModule.onEvent(payload => setEvent(payload)),
      ClearAheadModule.onEventCleared(() => setEvent(undefined)),
      ClearAheadModule.onQuality(payload => setQuality(payload.quality)),
      ClearAheadModule.onMetrics(payload => {
        setMetrics(payload);
        if (!isDemo) {
          onMetrics(payload);
        }
      }),
      ClearAheadModule.onDetections(setDetections),
      ClearAheadModule.onDepthMap(payload =>
        setDepthMapDataUrl(payload.dataUrl),
      ),
      ClearAheadModule.onModelDownload(payload =>
        setStatusMessage(payload.message),
      ),
    ];

    const configuration = toFeedbackConfiguration(preferences);
    const startNativeSession = () =>
      ClearAheadModule.updateConfiguration(configuration).then(() =>
        isDemo
          ? ClearAheadModule.startDemo(demoScenario)
          : ClearAheadModule.startSession(configuration),
      );
    const handleStartError = (error: unknown) => {
      if (!active) {
        return;
      }
      setSessionState('error');
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
        (isDemo
          ? ClearAheadModule.stopDemo()
          : ClearAheadModule.stopSession()
        ).catch(() => undefined);
        setSessionState('paused');
        setStatusMessage('Paused while Clear Ahead is in the background');
        AccessibilityInfo.announceForAccessibility(
          'Assist mode paused because Clear Ahead left the foreground.',
        );
      } else {
        setSessionState('starting');
        setStatusMessage(isDemo ? 'Restarting safe demo' : 'Restarting camera');
        startNativeSession()
          .then(() => {
            if (active) {
              AccessibilityInfo.announceForAccessibility(
                isDemo ? 'Safe demo resumed.' : 'Assist mode resumed.',
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
      (isDemo
        ? ClearAheadModule.stopDemo()
        : ClearAheadModule.stopSession()
      ).catch(() => undefined);
    };
  }, [demoScenario, isDemo, onMetrics, preferences]);

  const eventDescription = useMemo(
    () => (event ? describeEvent(event) : 'Field clear'),
    [event],
  );

  const stop = () => {
    (isDemo ? ClearAheadModule.stopDemo() : ClearAheadModule.stopSession())
      .catch(() => undefined)
      .finally(onStop);
  };

  return (
    <View style={styles.root}>
      {!isDemo && cameraDevice ? (
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
            setSessionState('error');
            setStatusMessage(error.message);
            ClearAheadModule.stopSession().catch(() => undefined);
          }}
          onInterruptionStarted={() => {
            setSessionState('paused');
            setStatusMessage('Camera interrupted');
          }}
          onInterruptionEnded={() => {
            setSessionState('running');
            setStatusMessage(current =>
              cameraStartedMessage(current, latestStatus.current),
            );
          }}
        />
      ) : isDemo ? (
        <View
          accessibilityElementsHidden
          importantForAccessibility="no-hide-descendants"
          style={[StyleSheet.absoluteFill, styles.demoBackdrop]}
        >
          <View style={styles.demoRingOuter} />
          <View style={styles.demoRingInner} />
          <Text style={styles.demoWord}>DEMO</Text>
        </View>
      ) : null}
      {!isDemo && preferences.depthMapEnabled ? (
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
      />
      <SafeAreaView pointerEvents="box-none" style={styles.safeArea}>
        <View
          accessible
          accessibilityLiveRegion="polite"
          accessibilityLabel={`${statusMessage}. ${qualityMessage(quality)}`}
          style={styles.statusPill}
        >
          <View
            style={[
              styles.statusDot,
              quality !== 'good' && styles.statusDotWarning,
            ]}
          />
          <Text style={styles.statusText}>
            {quality === 'good' ? statusMessage : qualityMessage(quality)}
          </Text>
          {metrics ? (
            <Text style={styles.latency}>
              {Math.round(metrics.endToEndLatencyMs)} ms
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

        {preferences.depthMapEnabled && !isDemo ? (
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
            accessibilityLiveRegion="polite"
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

          <PrimaryButton
            label={isDemo ? 'Stop demo' : 'Stop Assist Mode'}
            hint="Stops the camera and all feedback immediately"
            destructive
            onPress={stop}
          />
        </View>
      </SafeAreaView>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.black },
  depthLoading: { backgroundColor: colors.black },
  safeArea: { flex: 1, paddingHorizontal: 14, paddingVertical: 10 },
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
  demoBackdrop: {
    backgroundColor: colors.surface,
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
  demoRingOuter: {
    position: 'absolute',
    width: 310,
    height: 310,
    borderRadius: 155,
    borderWidth: 1,
    borderColor: '#3291FF32',
  },
  demoRingInner: {
    position: 'absolute',
    width: 210,
    height: 210,
    borderRadius: 105,
    borderWidth: 1,
    borderColor: '#3291FF52',
  },
  demoWord: {
    color: colors.line,
    fontSize: 54,
    fontWeight: '900',
    letterSpacing: 6,
  },
});
