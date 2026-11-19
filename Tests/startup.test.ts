import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { URL } from 'node:url';
import { runInNewContext } from 'node:vm';
import ts from 'typescript';
import { DEFAULT_PREFERENCES } from '../src/config.ts';

type Element = { type: string; props: Record<string, unknown>; children: Element[] };

async function launch(assistError?: Error) {
  const states: unknown[] = [];
  const effects: (() => void)[] = [];
  let cursor = 0;
  let mounted = false;
  let assistLoads = 0;
  const recordSession = () => {};
  const react = {
    createElement: (type: string, props: Record<string, unknown>, ...children: Element[]) =>
      ({ type, props: props ?? {}, children }),
    useState(initial: unknown) {
      const index = cursor++;
      if (index >= states.length) states[index] = initial;
      return [states[index], (value: unknown) => {
        states[index] = typeof value === 'function' ? value(states[index]) : value;
      }];
    },
    useEffect(effect: () => void) { if (!mounted) effects.push(effect); },
    useCallback: (callback: unknown) => callback,
    useRef: (current: unknown) => ({ current }),
  };
  const modules: Record<string, unknown> = {
    react,
    'react-native': {
      Animated: { View: 'AnimatedView', Value: class {
        stopAnimation() {} setValue() {} interpolate() { return 1; }
      } },
      StyleSheet: { create: (styles: unknown) => styles },
      View: 'View', Text: 'Text', StatusBar: 'StatusBar',
    },
    'react-native-safe-area-context': { SafeAreaProvider: 'SafeAreaProvider' },
    'react-native-vision-camera': { useCameraPermission: () => ({ hasPermission: true }) },
    './src/config': { colors: {}, hasFeedbackChannel: () => true },
    './src/components/Controls': { PrimaryButton: 'PrimaryButton' },
    './src/hooks/usePreferences': { usePreferences: () => ({
      preferences: { ...DEFAULT_PREFERENCES, onboardingComplete: true }, isHydrated: true,
      setPreferences() {},
    }) },
    './src/hooks/useSessionStats': { useSessionStats: () => ({ stats: {}, recordSession }) },
    './src/hooks/useReducedMotion': { useReducedMotion: () => true },
    './src/native/ClearAheadModule': { ClearAheadModule: {
      onModelDownload() {}, prepareModels: () => Promise.resolve(),
    } },
  };
  const appModule = { exports: {} as { default: () => Element } };
  const source = ts.transpile(readFileSync(new URL('../App.tsx', import.meta.url), 'utf8'), {
    module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.React, esModuleInterop: true,
  });
  runInNewContext(source, {
    Error,
    exports: appModule.exports,
    require(id: string) {
      if (id === './src/screens/AssistScreen') {
        assistLoads++;
        if (assistError) throw assistError;
      }
      return modules[id] ?? { [id.split('/').at(-1)!]: id.split('/').at(-1)! };
    },
  });
  const render = () => { cursor = 0; return appModule.exports.default(); };
  render();
  mounted = true;
  effects.forEach(effect => effect());
  await Promise.resolve();
  return { render, assistLoads: () => assistLoads, recordSession };
}

function find(element: Element, type: string): Element | undefined {
  if (element?.type === type) return element;
  for (const child of element?.children ?? []) {
    const match = find(child, type);
    if (match) return match;
  }
  return undefined;
}

test('launch does not initialize Assist native processing', async () => {
  const app = await launch(new Error('ClearAheadVision is not registered'));
  assert.ok(find(app.render(), 'HomeScreen'));
  assert.equal(app.assistLoads(), 0);
});

test('Assist initialization failure shows an error and still allows settings', async () => {
  const error = new Error('ClearAheadVision is not registered');
  const app = await launch(error);
  (find(app.render(), 'HomeScreen')!.props.onStart as () => void)();
  const failed = app.render();
  assert.ok(JSON.stringify(failed).includes(error.message));
  (find(failed, 'PrimaryButton')!.props.onPress as () => void)();
  assert.ok(find(app.render(), 'SettingsScreen'));
});

test('successful Assist startup preserves preferences, session recording, and navigation', async () => {
  const app = await launch();
  (find(app.render(), 'HomeScreen')!.props.onStart as () => void)();
  const assist = find(app.render(), 'AssistScreen')!;
  assert.ok(assist);
  assert.equal(assist.props.onSessionEnd, app.recordSession);
  assert.equal((assist.props.preferences as typeof DEFAULT_PREFERENCES).lidarEnabled, true);
  (assist.props.onStop as () => void)();
  assert.ok(find(app.render(), 'HomeScreen'));
});
