// SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:avif_native/avif_native.dart' as avif;

Future<ui.Codec> createAvifCodec(Uint8List bytes) async =>
    _AvifCodec(await _AvifWorker.start(bytes));

class _AvifCodec implements ui.Codec {
  _AvifCodec(this._worker)
    : frameCount = _worker.frameCount,
      repetitionCount = _worker.repetitionCount < -1
          ? 0
          : _worker.repetitionCount;

  final _AvifWorker _worker;

  @override
  final int frameCount;

  @override
  final int repetitionCount;

  Future<void> _queue = Future.value();
  final _requests = <Completer<ui.FrameInfo>>{};
  ui.Image? _staticImage;
  Duration _staticDuration = Duration.zero;
  bool _disposed = false;
  Object? _failure;
  StackTrace? _failureStack;

  bool get _isOpen => !_disposed && _failure == null;

  @override
  Future<ui.FrameInfo> getNextFrame() {
    if (!_isOpen) {
      return Future.error(
        _failure ?? StateError('AVIF codec has been disposed'),
        _failureStack,
      );
    }
    final result = Completer<ui.FrameInfo>();
    _requests.add(result);
    // Decode and upload together, so overlapping callers cannot accumulate
    // decoded RGBA frames while the UI isolate uploads an earlier frame.
    _queue = _queue.then((_) => _nextFrame(result));
    return result.future;
  }

  Future<void> _nextFrame(Completer<ui.FrameInfo> result) async {
    ui.Image? image;
    try {
      if (!_isOpen) return;
      final Duration duration;
      switch (_staticImage) {
        case final ui.Image cached:
          image = cached.clone();
          duration = _staticDuration;
          break;
        case null:
          final frame = await _worker.nextFrame();
          if (!_isOpen) return;
          // A static image needs no native decoder after its only frame arrives.
          if (frameCount == 1) _worker.close();
          image = await _uploadFrame(frame);
          if (!_isOpen) return;
          duration = frame.duration;
          if (frameCount == 1) {
            _staticImage = image.clone();
            _staticDuration = duration;
          }
          break;
      }
      if (!result.isCompleted) {
        result.complete(_AvifFrameInfo(image, duration));
        image = null; // The recipient now owns this image handle.
      }
    } catch (error, stack) {
      if (_isOpen) _fail(error, stack);
    } finally {
      // In particular, release uploads which finish after dispose().
      image?.dispose();
      _requests.remove(result);
    }
  }

  void _fail(Object error, StackTrace stack) {
    _failure = error;
    _failureStack = stack;
    _finishRequests(error, stack);
    _releaseResources();
  }

  void _finishRequests(Object error, [StackTrace? stack]) {
    for (final request in _requests) {
      if (!request.isCompleted) request.completeError(error, stack);
    }
    _requests.clear();
  }

  void _releaseResources() {
    _worker.close();
    _staticImage?.dispose();
    _staticImage = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finishRequests(StateError('AVIF codec has been disposed'));
    _releaseResources();
  }
}

class _AvifFrameInfo implements ui.FrameInfo {
  const _AvifFrameInfo(this.image, this.duration);

  @override
  final ui.Image image;

  @override
  final Duration duration;
}

Future<ui.Image> _uploadFrame(_WorkerFrame frame) async {
  final pixels = frame.pixels.materialize().asUint8List();
  final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: frame.width,
      height: frame.height,
      rowBytes: frame.width * 4,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    codec = await descriptor.instantiateCodec();
    return (await codec.getNextFrame()).image;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

class _AvifWorker {
  _AvifWorker() {
    _responses.listen(_onMessage);
  }

  final _responses = ReceivePort();
  final _ready = Completer<void>();
  SendPort? _commands;
  Completer<_WorkerFrame>? _pendingFrame;
  bool _closing = false;
  bool _finished = false;
  Object? _failure;
  StackTrace? _failureStack;
  late int frameCount;
  late int repetitionCount;

  static Future<_AvifWorker> start(Uint8List bytes) async {
    final worker = _AvifWorker();
    // Attach the readiness consumer before a spawn failure can report an error.
    final ready = worker._ready.future;
    unawaited(worker._spawn(bytes));
    await ready;
    return worker;
  }

  Future<void> _spawn(Uint8List bytes) async {
    try {
      await Isolate.spawn(
        _runAvifWorker,
        _WorkerStart(
          _responses.sendPort,
          TransferableTypedData.fromList([bytes]),
        ),
        // Replies and exit/error notifications share an inbox. A requested
        // shutdown is marked before sending its command, including for stills.
        onError: _responses.sendPort,
        onExit: _responses.sendPort,
        errorsAreFatal: true,
        debugName: 'AVIF decoder',
      );
    } catch (error, stack) {
      _fail(error, stack);
      _finish();
    }
  }

  Future<_WorkerFrame> nextFrame() {
    if (_closing || _finished) {
      return Future.error(
        _failure ?? StateError('AVIF decoder has been closed'),
        _failureStack,
      );
    }
    assert(_pendingFrame == null);
    final result = Completer<_WorkerFrame>();
    _pendingFrame = result;
    _commands!.send(const _NextFrame());
    return result.future;
  }

  void _onMessage(Object? message) {
    switch (message) {
      case _WorkerReady():
        _commands = message.commands;
        frameCount = message.frameCount;
        repetitionCount = message.repetitionCount;
        if (_closing) {
          _commands!.send(const _CloseWorker());
          return;
        }
        if (!_ready.isCompleted) _ready.complete();
        return;
      case _WorkerFrame():
        final pending = _pendingFrame;
        _pendingFrame = null;
        if (pending != null && !pending.isCompleted) pending.complete(message);
        return;
      case _WorkerFailure():
        _fail(StateError(message.error), StackTrace.fromString(message.stack));
        return;
      case List():
        // Uncaught isolate errors use [error description, stack trace].
        _fail(
          StateError(message.first.toString()),
          StackTrace.fromString(message.length > 1 ? '${message[1]}' : ''),
        );
        return;
      case _WorkerClosed() || null:
        _finish();
        return;
      default:
        return;
    }
  }

  void _fail(Object error, StackTrace stack) {
    _failure ??= error;
    _failureStack ??= stack;
    if (!_ready.isCompleted) _ready.completeError(error, stack);
    final pending = _pendingFrame;
    _pendingFrame = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(error, stack);
    }
    close();
  }

  void close() {
    if (_closing || _finished) return;
    _closing = true;
    final pending = _pendingFrame;
    _pendingFrame = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('AVIF decoder has been closed'));
    }
    // Never kill a healthy worker: its decoder owns native allocations which
    // must be released inside the worker after an in-flight FFI call finishes.
    _commands?.send(const _CloseWorker());
  }

  void _finish() {
    if (_finished) return;
    if (!_closing) {
      _fail(StateError('AVIF decoder exited unexpectedly'), StackTrace.current);
    }
    _finished = true;
    _commands = null;
    _responses.close();
  }
}

class _WorkerStart {
  const _WorkerStart(this.replies, this.bytes);

  final SendPort replies;
  final TransferableTypedData bytes;
}

class _WorkerReady {
  const _WorkerReady(this.commands, this.frameCount, this.repetitionCount);

  final SendPort commands;
  final int frameCount;
  final int repetitionCount;
}

class _WorkerFrame {
  const _WorkerFrame(this.pixels, this.width, this.height, this.duration);

  final TransferableTypedData pixels;
  final int width;
  final int height;
  final Duration duration;
}

class _WorkerFailure {
  const _WorkerFailure(this.error, this.stack);

  final String error;
  final String stack;
}

class _NextFrame {
  const _NextFrame();
}

class _CloseWorker {
  const _CloseWorker();
}

class _WorkerClosed {
  const _WorkerClosed();
}

void _runAvifWorker(_WorkerStart start) {
  final commands = ReceivePort();
  avif.AvifDecoder? decoder;
  var frameIndex = 0;

  Never finish(Object message) {
    commands.close();
    try {
      decoder?.dispose();
    } finally {
      Isolate.exit(start.replies, message);
    }
  }

  try {
    final activeDecoder = avif.AvifDecoder(
      start.bytes.materialize().asUint8List(),
      premultiplyAlpha: true,
    );
    decoder = activeDecoder;
    start.replies.send(
      _WorkerReady(
        commands.sendPort,
        activeDecoder.frameCount,
        activeDecoder.repetitionCount,
      ),
    );
  } catch (error, stack) {
    finish(_WorkerFailure(error.toString(), stack.toString()));
  }

  commands.listen((message) {
    try {
      if (message is _CloseWorker) finish(const _WorkerClosed());
      if (message is! _NextFrame) return;
      final activeDecoder = decoder!;
      if (frameIndex == activeDecoder.frameCount) {
        activeDecoder.reset();
        frameIndex = 0;
      }
      final frame = activeDecoder.getNextFrame();
      frameIndex++;
      start.replies.send(
        _WorkerFrame(
          TransferableTypedData.fromList([frame.rgba]),
          frame.width,
          frame.height,
          frame.duration,
        ),
      );
    } catch (error, stack) {
      finish(_WorkerFailure(error.toString(), stack.toString()));
    }
  });
}
