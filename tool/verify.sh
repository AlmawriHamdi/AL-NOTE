#!/usr/bin/env bash
set -euo pipefail

flutter --version
flutter pub get
flutter format --set-exit-if-changed lib test
flutter analyze --fatal-infos
flutter test

if flutter config --list | grep -q 'enable-linux-desktop: true'; then
  flutter build linux --debug
else
  echo 'Linux desktop is not enabled in this Flutter installation.' >&2
fi

flutter build apk --debug
flutter build web
