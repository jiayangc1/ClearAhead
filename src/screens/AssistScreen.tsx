import React, {useEffect, useMemo, useState} from 'react';
import {
  AccessibilityInfo,
  AppState,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import {SafeAreaView} from 'react-native-safe-area-context';
import {
  Camera,
  CommonResolutions,
  useFrameOutput,
} from 'react-native-vision-camera';
import {ClearAheadVision} from 'react-native-clear-ahead-vision';
import {PrimaryButton} from '../components/Controls';
import {SoundField} from '../components/SoundField';
import {colors, toFeedbackConfiguration} from '../config';
import {ClearAheadModule} from '../native/ClearAheadModule';
import type {
  AppPreferences,
  DemoScenario,
  PipelineMetrics,
  SessionQuality,
  SessionState,
  SpatialEvent,
} from '../types';
import {describeEvent, qualityMessage} from '../utils/eventLogic';

export function AssistScreen({
  preferences,
  demoScenario,
  onStop,
}: {
  preferences: AppPreferences;
  demoScenario?: DemoScenario;
  onStop: () => void;
}) {
  const [sessionState, setSessionState] = useState<SessionState>('starting');
  const [statusMessage, setStatusMessage] = useState('Starting camera');
  const [quality, setQuality] = useState<SessionQuality>('good');
  const [event, setEvent] = useState<SpatialEvent>();
  const [metrics, setMetrics] = useState<PipelineMetrics>();
  const [isForeground, setIsForeground] = useState(AppState.currentState === 'active');
  const isDemo = demoScenario != null;

  const frameOutput = useFrameOutput({
    targetResolution: CommonResolutions.HD_16_9,
    pixelFormat: 'yuv',
    dropFramesWhileBusy: true,
    enableCameraMatrixDelivery: true,
    enablePreviewSizedOutputBuffers: true,
    onFrame(frame) {
      'worklet';
      ClearAheadVision.processFrame(frame);
      frame.dispose();
    },
    onFrameDropped(reason) {
      ClearAheadVision.reportDroppedFrame(reason);
    },
  });

  useEffect(() => {
    const subscriptions = [
      ClearAheadModule.onStatus(payload => {
        setSessionState(payload.state);
        setStatusMessage(payload.message);
      }),
      ClearAheadModule.onEvent(payload => setEvent(payload)),
      ClearAheadModule.onQuality(payload => setQuality(payload.quality)),
      ClearAheadModule.onMetrics(setMetrics),
    ];

    const configuration = toFeedbackConfiguration(preferences);
    const start = ClearAheadModule.updateConfiguration(configuration).then(() =>
      isDemo
        ? ClearAheadModule.startDemo(demoScenario)
        : ClearAheadModule.startSession(configuration),
    );
    start.catch(error => {
      setSessionState('error');
      setStatusMessage(error instanceof Error ? error.message : 'Session could not start');
    });

    const appStateSubscription = AppState.addEventListener('change', next => {
      setIsForeground(next === 'active');
      if (next !== 'active') {
        ClearAheadModule.stopSession().catch(() => undefined);
        setSessionState('paused');
        setStatusMessage('Paused while Clear Ahead is in the background');
        AccessibilityInfo.announceForAccessibility('Assist mode paused because Clear Ahead left the foreground.');
      } else if (!isDemo) {
        ClearAheadModule.startSession(configuration).catch(() => undefined);
        AccessibilityInfo.announceForAccessibility('Assist mode resumed.');
      }
    });

    return () => {
      subscriptions.forEach(subscription => subscription?.remove());
      appStateSubscription.remove();
      (isDemo ? ClearAheadModule.stopDemo() : ClearAheadModule.stopSession()).catch(() => undefined);
    };
  }, [demoScenario, isDemo, preferences]);

  useEffect(() => {
    ClearAheadModule.updateConfiguration(toFeedbackConfiguration(preferences)).catch(() => undefined);
  }, [preferences]);

  const eventDescription = useMemo(
    () => (event ? describeEvent(event) : 'No priority event'),
    [event],
  );

  const stop = () => {
    (isDemo ? ClearAheadModule.stopDemo() : ClearAheadModule.stopSession())
      .catch(() => undefined)
      .finally(onStop);
  };

  return (
    <View style={styles.root}>
      {!isDemo ? (
        <Camera
          style={StyleSheet.absoluteFill}
          device="back"
          isActive={isForeground && sessionState !== 'idle' && sessionState !== 'error'}
          constraints={[{fps: 30}]}
          outputs={[frameOutput]}
          resizeMode="cover"
          onStarted={() => setStatusMessage('Camera active')}
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
            setStatusMessage('Camera active');
          }}
        />
      ) : (
        <View style={[StyleSheet.absoluteFill, styles.demoBackdrop]}>
          <Text style={styles.demoWord}>DEMO</Text>
        </View>
      )}
      <SoundField event={event} />
      <SafeAreaView pointerEvents="box-none" style={styles.safeArea}>
        <View
          accessibilityLiveRegion="polite"
          accessibilityLabel={`${statusMessage}. ${qualityMessage(quality)}`}
          style={styles.statusPill}>
          <View style={[styles.statusDot, quality !== 'good' && styles.statusDotWarning]} />
          <Text numberOfLines={1} style={styles.statusText}>
            {quality === 'good' ? statusMessage : qualityMessage(quality)}
          </Text>
          {metrics ? (
            <Text style={styles.latency}>{Math.round(metrics.endToEndLatencyMs)} MS</Text>
          ) : null}
        </View>

        <View style={styles.spacer} />

        <View
          accessible
          accessibilityLiveRegion="assertive"
          accessibilityLabel={eventDescription}
          style={[
            styles.eventCard,
            event && event.urgency > 0.76 && styles.eventCardCritical,
          ]}>
          <Text style={styles.eventEyebrow}>
            {event ? `${event.direction.toUpperCase()} · ${event.proximity.toUpperCase()}` : 'FIELD CLEAR'}
          </Text>
          <Text style={styles.eventTitle}>
            {event ? event.kind.replace('-', ' ') : 'Listening'}
          </Text>
          <Text style={styles.eventDescription}>{eventDescription}</Text>
        </View>

        <PrimaryButton
          label={isDemo ? 'Stop demo' : 'Stop assist mode'}
          hint="Stops the camera and all feedback immediately"
          destructive
          onPress={stop}
        />
      </SafeAreaView>
    </View>
  );
}

const styles = StyleSheet.create({
  root: {flex: 1, backgroundColor: colors.black},
  safeArea: {flex: 1, padding: 18},
  statusPill: {minHeight: 48, alignSelf: 'stretch', borderRadius: 16, backgroundColor: '#071018DD', flexDirection: 'row', alignItems: 'center', paddingHorizontal: 15, gap: 10},
  statusDot: {width: 10, height: 10, borderRadius: 5, backgroundColor: colors.cyan},
  statusDotWarning: {backgroundColor: colors.amber},
  statusText: {color: colors.text, fontSize: 15, fontWeight: '700', flex: 1},
  latency: {color: colors.muted, fontSize: 11, fontWeight: '800', fontVariant: ['tabular-nums'], letterSpacing: 1},
  spacer: {flex: 1},
  eventCard: {backgroundColor: '#071018E8', borderLeftWidth: 5, borderLeftColor: colors.cyan, borderRadius: 18, padding: 18, marginBottom: 12},
  eventCardCritical: {borderLeftColor: colors.critical},
  eventEyebrow: {color: colors.cyan, fontSize: 11, fontWeight: '900', letterSpacing: 1.6},
  eventTitle: {color: colors.text, fontSize: 31, lineHeight: 35, fontWeight: '900', textTransform: 'capitalize', marginTop: 4},
  eventDescription: {color: colors.muted, fontSize: 16, lineHeight: 22, marginTop: 4},
  demoBackdrop: {backgroundColor: colors.surface, alignItems: 'center', justifyContent: 'center'},
  demoWord: {color: colors.line, fontSize: 74, fontWeight: '900', letterSpacing: 7, transform: [{rotate: '-12deg'}]},
});
