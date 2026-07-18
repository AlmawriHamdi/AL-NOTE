import 'package:flutter/material.dart';

void main() {
  runApp(const AlNoteApp());
}

class AlNoteApp extends StatelessWidget {
  const AlNoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AL NOTE',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const AlNoteHomePage(),
    );
  }
}

class AlNoteHomePage extends StatelessWidget {
  const AlNoteHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'AL NOTE',
              style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 12),
            Text('Repository and toolchain baseline'),
          ],
        ),
      ),
    );
  }
}
