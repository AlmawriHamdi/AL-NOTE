// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.almawrihamdi.alnote

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var pdfFixtureReader: PdfFixtureReader? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pdfFixtureReader = PdfFixtureReader(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (pdfFixtureReader?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        pdfFixtureReader?.dispose()
        pdfFixtureReader = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        pdfFixtureReader?.dispose()
        pdfFixtureReader = null
        super.onDestroy()
    }
}
