#!/bin/sh

set -eu

if [ -z "${CLEAR_AHEAD_HERMESC:-}" ] || [ ! -x "$CLEAR_AHEAD_HERMESC" ]; then
  echo "error: Clear Ahead could not resolve the CocoaPods-provided Hermes compiler." >&2
  exit 1
fi

# Metro's React Native bundle relies on globals supplied by the native runtime,
# and the Debug bundle includes DevTools code that intentionally uses eval().
# Hermes cannot infer those runtime bindings during static compilation.
exec "$CLEAR_AHEAD_HERMESC" -w "$@"
