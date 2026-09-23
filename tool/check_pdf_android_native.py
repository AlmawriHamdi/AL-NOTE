#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compile/run the production transfer core on JVM using existing cached tools.
No Gradle/dependency changes or downloads. Android framework calls are not executed.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
def jar(group, artifact, version=None):
    root = cache / group / artifact
    matches = [path for path in (root / version if version else root).rglob('*.jar')
               if not path.name.endswith(('-sources.jar', '-javadoc.jar'))]
    if not matches:
        raise SystemExit(f'Missing existing cached tool: {artifact}')
    return str(sorted(matches)[-1])
compiler = [jar('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.3.20'),
            jar('org.jetbrains.kotlin', 'kotlin-stdlib', '2.3.20'),
            jar('org.jetbrains.kotlin', 'kotlin-script-runtime', '2.3.20'),
            jar('org.jetbrains.kotlin', 'kotlin-reflect'),
            jar('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm'),
            jar('org.jetbrains', 'annotations')]
android = Path.home() / 'Android/Sdk/platforms/android-36/android.jar'
engine = json.loads((repo / 'tool/flutter_toolchain.json').read_text())['flutter']['engineRevision']
embedding = jar('io.flutter', 'flutter_embedding_debug', f'1.0.0-{engine}')
cp = os.pathsep.join([*compiler, str(android), embedding])
with tempfile.TemporaryDirectory(prefix='al-note-android-native-') as output:
    subprocess.run(['java', '-cp', os.pathsep.join(compiler), 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
        '-no-stdlib', '-no-reflect', '-jvm-target', '17', '-classpath', cp, '-d', output,
        str(repo / 'android/app/src/main/kotlin/io/github/almawrihamdi/alnote/PdfFixtureReader.kt'),
        str(repo / 'test/native/PdfFixtureReaderTest.kt')], check=True)
    subprocess.run(['java', '-ea', '-cp', output + os.pathsep + cp,
                    'io.github.almawrihamdi.alnote.PdfFixtureReaderTestKt'], check=True)
