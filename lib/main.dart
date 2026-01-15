import 'dart:async';
import 'dart:io';
import 'dart:developer';
import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:camerawesome/pigeon.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'settings_screen.dart';

extension MLKitUtils on AnalysisImage {
  InputImage toInputImage() {
    return when(
      nv21: (image) {
        return InputImage.fromBytes(
          bytes: image.bytes,
          metadata: InputImageMetadata(
            rotation: inputImageRotation,
            format: InputImageFormat.nv21,
            size: image.size,
            bytesPerRow: image.planes.first.bytesPerRow,
          ),
        );
      },
      bgra8888: (image) {
        final inputImageData = InputImageMetadata(
          size: size,
          rotation: inputImageRotation,
          format: inputImageFormat,
          bytesPerRow: image.planes.first.bytesPerRow,
        );

        return InputImage.fromBytes(
          bytes: image.bytes,
          metadata: inputImageData,
        );
      },
    )!;
  }

  InputImageRotation get inputImageRotation =>
      InputImageRotation.values.byName(rotation.name);

  InputImageFormat get inputImageFormat {
    switch (format) {
      case InputAnalysisImageFormat.bgra8888:
        return InputImageFormat.bgra8888;
      case InputAnalysisImageFormat.nv21:
        return InputImageFormat.nv21;
      default:
        return InputImageFormat.yuv420;
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: FaceAwareCamera(),
    ),
  );
}

class FaceDetectionModel {
  final List<Face> faces;
  final Size absoluteImageSize;
  final InputImageRotation imageRotation;
  final AnalysisImage? img;

  FaceDetectionModel({
    required this.faces,
    required this.absoluteImageSize,
    required this.imageRotation,
    this.img,
  });

  Size get croppedSize => img?.croppedSize ?? absoluteImageSize;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FaceDetectionModel &&
          runtimeType == other.runtimeType &&
          faces == other.faces &&
          absoluteImageSize == other.absoluteImageSize &&
          imageRotation == other.imageRotation &&
          croppedSize == other.croppedSize;

  @override
  int get hashCode =>
      faces.hashCode ^
      absoluteImageSize.hashCode ^
      imageRotation.hashCode ^
      croppedSize.hashCode;
}

class FaceAwareCamera extends StatefulWidget {
  const FaceAwareCamera({super.key});

  @override
  FaceAwareCameraState createState() => FaceAwareCameraState();
}

class FaceAwareCameraState extends State<FaceAwareCamera> {
  late FaceDetector _faceDetector;
  bool _isProcessing = false;
  Timer? _noFaceTimer;

  AnalysisPreview? _currentPreview;
  Offset? _focusPositionNormalized;
  bool _showFocusFeedback = false;

  late StreamController<FaceDetectionModel> _faceDetectionController;

  BrightnessModeConfig _brightnessMode = BrightnessModeConfig.auto;
  double _brightnessPercent = 0.0;
  bool _showVisualFeedback = false;
  bool _brightnessApplied = false;
  int _cameraKey = 0; // Key para forçar reconstrução da câmera

  /// Aplica o brilho apenas se necessário (modo manual e ainda não foi aplicado)
  Future<void> _applyBrightnessIfNeeded() async {
    if (_brightnessMode != BrightnessModeConfig.manual ||
        _brightnessApplied ||
        _currentPreview == null) {
      return;
    }

    try {
      final brightnessValue = (_brightnessPercent / 100.0).clamp(0.0, 1.0);
      await CamerawesomePlugin.setBrightness(brightnessValue);
      _brightnessApplied = true;
      log('✨ Brilho aplicado: ${brightnessValue.toStringAsFixed(2)}');
    } catch (e) {
      log("Erro ao aplicar brightness: $e");
    }
  }

  Offset? _normalizedToScreenPosition(Offset normalizedPoint) {
    if (_currentPreview == null) return null;

    final previewSize = _currentPreview!.previewSize;
    final screenSize = MediaQuery.of(context).size;
    final scaleX = screenSize.width / previewSize.width;
    final scaleY = screenSize.height / previewSize.height;

    final previewPointX = normalizedPoint.dx * previewSize.width;
    final previewPointY = normalizedPoint.dy * previewSize.height;

    return Offset(
      previewPointX * scaleX + _currentPreview!.offset.dx,
      previewPointY * scaleY + _currentPreview!.offset.dy,
    );
  }

  static const Duration _noFaceTimeout = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    final options = FaceDetectorOptions(
      performanceMode: FaceDetectorMode.accurate,
      enableContours: true,
      enableLandmarks: true,
      enableClassification: false,
      minFaceSize: 0.1,
    );
    _faceDetector = FaceDetector(options: options);
    _faceDetectionController = StreamController<FaceDetectionModel>.broadcast();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final modeIndex =
        prefs.getInt('brightnessMode') ?? BrightnessModeConfig.auto.index;
    final brightnessPercent = prefs.getDouble('brightnessPercent') ?? 0.0;
    final showVisualFeedback = prefs.getBool('showVisualFeedback') ?? false;

    setState(() {
      _brightnessMode = BrightnessModeConfig.values[modeIndex];
      _brightnessPercent = brightnessPercent.clamp(0.0, 100.0);
      _showVisualFeedback = showVisualFeedback;
      _brightnessApplied = false;
    });

    // Aplicar brilho após carregar configurações se a câmera já estiver pronta
    if (_currentPreview != null) {
      _applyBrightnessIfNeeded();
    }
  }

  Widget _buildCameraLayout(CameraState state, AnalysisPreview preview) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _currentPreview != preview) {
        setState(() {
          _currentPreview = preview;
          _brightnessApplied = false;
        });
        // Aplicar brilho quando a câmera é inicializada
        _applyBrightnessIfNeeded();
      }
    });

    return _FacePreviewDecorator(
      cameraState: state,
      faceDetectionStream: _faceDetectionController.stream,
      preview: preview,
      showVisualFeedback: _showVisualFeedback,
    );
  }

  Future<void> _openSettings() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsScreen(
          currentMode: _brightnessMode,
          currentOffset: _brightnessPercent,
          currentShowVisualFeedback: _showVisualFeedback,
        ),
      ),
    );

    if (result != null) {
      final newMode = result['mode'] as BrightnessModeConfig;
      final newBrightness = result['offset'] as double;
      final newShowVisualFeedback =
          result['showVisualFeedback'] as bool? ?? false;

      if (mounted) {
        final previousMode = _brightnessMode;

        setState(() {
          _brightnessMode = newMode;
          _brightnessPercent = newBrightness.clamp(0.0, 100.0);
          _showVisualFeedback = newShowVisualFeedback;
          _brightnessApplied = false;
        });

        // Se mudou de manual para auto/off, reconstruir a câmera para resetar o brilho
        if (previousMode == BrightnessModeConfig.manual &&
            (newMode == BrightnessModeConfig.auto ||
                newMode == BrightnessModeConfig.off)) {
          setState(() {
            _cameraKey++; // Incrementa a key para forçar reconstrução
            _currentPreview = null; // Limpa o preview atual
          });
          log('🔄 Reconstruindo câmera para resetar brilho');
        } else if (newMode == BrightnessModeConfig.manual) {
          // Se mudou para manual, aplicar brilho quando a câmera estiver pronta
          _applyBrightnessIfNeeded();
        }
      }
    }
  }

  Future<void> _processCameraImage(AnalysisImage img) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final inputImage = img.toInputImage();
      final faces = await _faceDetector.processImage(inputImage);

      _faceDetectionController.add(
        FaceDetectionModel(
          faces: faces,
          absoluteImageSize: inputImage.metadata!.size,
          imageRotation: inputImage.metadata!.rotation,
          img: img,
        ),
      );

      if (faces.isNotEmpty) {
        final face = faces.first;

        log('👁️ Rosto detectado: ${face.boundingBox.width.toStringAsFixed(0)}x${face.boundingBox.height.toStringAsFixed(0)} @ (${face.boundingBox.center.dx.toStringAsFixed(0)}, ${face.boundingBox.center.dy.toStringAsFixed(0)})');

        _noFaceTimer?.cancel();
        _noFaceTimer = null;
        _focusOnDetectedFace(face.boundingBox, inputImage.metadata!.size, img);
      } else {
        // Esconder bolinha quando não há rosto
        _hideFocusFeedback();
        if (_brightnessMode != BrightnessModeConfig.off) {
          if (_noFaceTimer == null || !_noFaceTimer!.isActive) {
            _startNoFaceTimer();
          }
        }
      }
    } catch (e) {
      log("Erro: $e");
    } finally {
      _isProcessing = false;
    }
  }

  void _showFocusFeedbackAt(Offset normalizedPosition) {
    setState(() {
      _focusPositionNormalized = normalizedPosition;
      _showFocusFeedback = true;
    });
  }

  void _hideFocusFeedback() {
    if (mounted) {
      setState(() {
        _showFocusFeedback = false;
        _focusPositionNormalized = null;
      });
    }
  }

  Future<void> _focusOnDetectedFace(
      Rect faceRect, Size imageSize, AnalysisImage analysisImage) async {
    if (_brightnessMode == BrightnessModeConfig.off || _currentPreview == null)
      return;

    try {
      final nativePreviewSize = _currentPreview!.nativePreviewSize;
      final previewSizeFlutter = _currentPreview!.previewSize;
      final previewSize = PreviewSize(
        width: nativePreviewSize.width,
        height: nativePreviewSize.height,
      );

      final imageCenter = Offset(faceRect.center.dx, faceRect.center.dy);
      final previewPoint =
          _currentPreview!.convertFromImage(imageCenter, analysisImage);

      Offset focusPosition;
      AndroidFocusSettings? focusSettings;
      Offset normalizedPositionForFeedback;

      if (Platform.isAndroid) {
        final normalizedX = previewPoint.dx / previewSizeFlutter.width;
        final normalizedY = previewPoint.dy / previewSizeFlutter.height;

        // Inverter X para o preview nativo (não espelhado) para o foco
        final normalizedXInverted = 1.0 - normalizedX;
        focusPosition = Offset(
          normalizedXInverted * nativePreviewSize.width,
          normalizedY * nativePreviewSize.height,
        );
        focusSettings = AndroidFocusSettings(autoCancelDurationInMillis: 5000);

        // Inverter X também para o feedback visual (Stack não está espelhado)
        normalizedPositionForFeedback = Offset(1.0 - normalizedX, normalizedY);
      } else {
        final normalizedX = previewPoint.dx / previewSizeFlutter.width;
        final normalizedY = previewPoint.dy / previewSizeFlutter.height;
        focusPosition = Offset(normalizedX, normalizedY);
        focusSettings = null;
        normalizedPositionForFeedback = Offset(normalizedX, normalizedY);
      }

      await CamerawesomePlugin.focusOnPoint(
        previewSize: previewSize,
        position: focusPosition,
        androidFocusSettings: focusSettings,
      );

      log('🎯 Foco: (${focusPosition.dx.toStringAsFixed(2)}, ${focusPosition.dy.toStringAsFixed(2)})');

      _showFocusFeedbackAt(normalizedPositionForFeedback);
    } catch (e) {
      log("Erro ao ajustar foco: $e");
    }
  }

  void _startNoFaceTimer() {
    _noFaceTimer?.cancel();
    _noFaceTimer = null;

    _noFaceTimer = Timer(_noFaceTimeout, () {
      _noFaceTimer = null;
      _focusOnCenterWhenNoFace();
    });
  }

  Future<void> _focusOnCenterWhenNoFace() async {
    if (_brightnessMode == BrightnessModeConfig.off ||
        !mounted ||
        _currentPreview == null) return;

    try {
      final nativePreviewSize = _currentPreview!.nativePreviewSize;
      final previewSize = PreviewSize(
        width: nativePreviewSize.width,
        height: nativePreviewSize.height,
      );
      const normalizedCenter = Offset(0.5, 0.5);

      Offset focusPosition;
      AndroidFocusSettings? focusSettings;

      if (Platform.isAndroid) {
        focusPosition = Offset(
          nativePreviewSize.width * 0.5,
          nativePreviewSize.height * 0.5,
        );
        focusSettings = AndroidFocusSettings(autoCancelDurationInMillis: 5000);
      } else {
        focusPosition = normalizedCenter;
        focusSettings = null;
      }

      await CamerawesomePlugin.focusOnPoint(
        previewSize: previewSize,
        position: focusPosition,
        androidFocusSettings: focusSettings,
      );

      log('🎯 Foco centro: (${focusPosition.dx.toStringAsFixed(2)}, ${focusPosition.dy.toStringAsFixed(2)})');

      _showFocusFeedbackAt(normalizedCenter);
    } catch (e) {
      log("Erro ao ajustar brilho para centro: $e");
    }
  }

  @override
  void dispose() {
    _noFaceTimer?.cancel();
    _faceDetectionController.close();
    _faceDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Widget wrapper com key para forçar reconstrução da câmera
          SizedBox(
            key: ValueKey(_cameraKey),
            child: CameraAwesomeBuilder.custom(
              saveConfig: SaveConfig.photo(),
              previewFit: CameraPreviewFit.contain,
              sensorConfig: SensorConfig.single(
                aspectRatio: CameraAspectRatios.ratio_4_3,
                flashMode: FlashMode.auto,
                sensor: Sensor.position(SensorPosition.front),
              ),
              onImageForAnalysis: (img) => _processCameraImage(img),
              imageAnalysisConfig: AnalysisConfig(
                androidOptions: const AndroidAnalysisOptions.nv21(
                  width: 1024,
                ),
                maxFramesPerSecond: 5,
                autoStart: true,
              ),
              builder: (CameraState state, AnalysisPreview preview) {
                return _buildCameraLayout(state, preview);
              },
            ),
          ),
          if (_showVisualFeedback &&
              _showFocusFeedback &&
              _focusPositionNormalized != null)
            Builder(
              builder: (context) {
                final screenPosition =
                    _normalizedToScreenPosition(_focusPositionNormalized!);
                if (screenPosition == null) return const SizedBox();
                return Positioned(
                  left: screenPosition.dx - 5,
                  top: screenPosition.dy - 5,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                );
              },
            ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: SafeArea(
              child: IconButton(
                icon: const Icon(Icons.settings, color: Colors.white, size: 28),
                onPressed: _openSettings,
                tooltip: 'Configurações',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FacePreviewDecorator extends StatelessWidget {
  final CameraState cameraState;
  final Stream<FaceDetectionModel> faceDetectionStream;
  final AnalysisPreview preview;
  final bool showVisualFeedback;

  const _FacePreviewDecorator({
    required this.cameraState,
    required this.faceDetectionStream,
    required this.preview,
    required this.showVisualFeedback,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: StreamBuilder(
        stream: cameraState.sensorConfig$,
        builder: (_, sensorSnapshot) {
          if (!sensorSnapshot.hasData) {
            return const SizedBox();
          } else {
            return StreamBuilder<SensorConfig>(
              stream: cameraState.sensorConfig$,
              builder: (_, sensorSnapshot) {
                if (!sensorSnapshot.hasData) {
                  return const SizedBox();
                }
                return StreamBuilder<FaceDetectionModel>(
                  stream: faceDetectionStream,
                  builder: (_, faceModelSnapshot) {
                    if (!showVisualFeedback) {
                      return const SizedBox();
                    }

                    if (!faceModelSnapshot.hasData ||
                        faceModelSnapshot.data!.img == null) {
                      return const SizedBox();
                    }

                    final canvasTransformation = faceModelSnapshot.data!.img
                        ?.getCanvasTransformation(preview);

                    return CustomPaint(
                      painter: FaceContourPainter(
                        model: faceModelSnapshot.requireData,
                        canvasTransformation: canvasTransformation,
                        preview: preview,
                      ),
                    );
                  },
                );
              },
            );
          }
        },
      ),
    );
  }
}

class FaceContourPainter extends CustomPainter {
  final FaceDetectionModel model;
  final CanvasTransformation? canvasTransformation;
  final AnalysisPreview? preview;

  FaceContourPainter({
    required this.model,
    this.canvasTransformation,
    this.preview,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (model.img == null) {
      return;
    }

    if (canvasTransformation != null) {
      canvas.save();
      canvas.applyTransformation(canvasTransformation!, size);
    }

    if (preview == null) {
      return;
    }

    final previewSize = preview!.previewSize;
    final canvasSize = size;
    final scaleToCanvasX = canvasSize.width / previewSize.width;
    final scaleToCanvasY = canvasSize.height / previewSize.height;

    for (final Face face in model.faces) {
      Map<FaceContourType, Path> paths = {
        for (var fct in FaceContourType.values) fct: Path()
      };

      face.contours.forEach((contourType, faceContour) {
        if (faceContour != null && faceContour.points.isNotEmpty) {
          final canvasPoints = faceContour.points.map(
            (element) {
              final originalPoint =
                  Offset(element.x.toDouble(), element.y.toDouble());
              final pointInPreview =
                  preview!.convertFromImage(originalPoint, model.img!);
              return Offset(
                pointInPreview.dx * scaleToCanvasX + preview!.offset.dx,
                pointInPreview.dy * scaleToCanvasY + preview!.offset.dy,
              );
            },
          ).toList();

          paths[contourType]!.addPolygon(canvasPoints, true);

          for (var point in canvasPoints) {
            canvas.drawCircle(point, 4, Paint()..color = Colors.blue);
          }
        }
      });

      paths.removeWhere((key, value) => value.getBounds().isEmpty);

      for (var p in paths.entries) {
        canvas.drawPath(
          p.value,
          Paint()
            ..color = Colors.orange
            ..strokeWidth = 2
            ..style = PaintingStyle.stroke,
        );
      }
    }

    if (canvasTransformation != null) {
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(FaceContourPainter oldDelegate) {
    return oldDelegate.model != model;
  }
}
