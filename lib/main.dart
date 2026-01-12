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
  const FaceAwareCamera({Key? key}) : super(key: key);

  @override
  _FaceAwareCameraState createState() => _FaceAwareCameraState();
}

class _FaceAwareCameraState extends State<FaceAwareCamera> {
  late FaceDetector _faceDetector;
  bool _isProcessing = false;
  Timer? _noFaceTimer;

  AnalysisPreview? _currentPreview;
  Offset? _focusPositionNormalized;
  bool _showFocusFeedback = false;
  Timer? _focusFeedbackTimer;
  Completer<void>? _focusFeedbackCompleter;
  Offset? _brightnessPositionNormalized;
  bool _showBrightnessFeedback = false;
  Timer? _brightnessFeedbackTimer;

  Size? _imageSizeRaw;
  late StreamController<FaceDetectionModel> _faceDetectionController;

  BrightnessModeConfig _brightnessMode = BrightnessModeConfig.auto;
  double _brightnessPercent = 0.0;
  
  double _brightnessPercentToValue(double percent) {
    return ((percent + 100.0) / 200.0).clamp(0.0, 1.0);
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
  static const Duration _brightnessFeedbackDuration = Duration(milliseconds: 300);

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
    final modeIndex = prefs.getInt('brightnessMode') ?? BrightnessModeConfig.auto.index;
    final brightnessPercent = prefs.getDouble('brightnessPercent') ?? 0.0;

    setState(() {
      _brightnessMode = BrightnessModeConfig.values[modeIndex];
      _brightnessPercent = brightnessPercent.clamp(-100.0, 100.0);
    });
  }

  Widget _buildCameraLayout(CameraState state, AnalysisPreview preview) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _currentPreview != preview) {
        setState(() {
          _currentPreview = preview;
        });
      }
    });
    
    return _FacePreviewDecorator(
      cameraState: state,
      faceDetectionStream: _faceDetectionController.stream,
      preview: preview,
    );
  }

  Future<void> _openSettings() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsScreen(
          currentMode: _brightnessMode,
          currentOffset: _brightnessPercent,
        ),
      ),
    );

    if (result != null) {
      final newMode = result['mode'] as BrightnessModeConfig;
      final newBrightness = result['offset'] as double;

      if (mounted) {
        setState(() {
          _brightnessMode = newMode;
          _brightnessPercent = newBrightness.clamp(-100.0, 100.0);
        });
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
        setState(() {
          _imageSizeRaw = inputImage.metadata!.size;
        });
        _focusOnDetectedFace(face.boundingBox, inputImage.metadata!.size, img);
      } else {
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

  Future<void> _showFocusFeedbackAt(Offset normalizedPosition) async {
    _focusFeedbackTimer?.cancel();
    _focusFeedbackCompleter = Completer<void>();
    
    setState(() {
      _focusPositionNormalized = normalizedPosition;
      _showFocusFeedback = true;
    });
    
    _focusFeedbackTimer = Timer(_brightnessFeedbackDuration, () {
      if (mounted) {
        setState(() {
          _showFocusFeedback = false;
        });
        _focusFeedbackCompleter?.complete();
        _focusFeedbackCompleter = null;
      }
    });
    
    return _focusFeedbackCompleter!.future;
  }

  Future<void> _showBrightnessFeedbackAt(Offset normalizedPosition) async {
    // Aguardar foco sumir se estiver visível
    if (_showFocusFeedback && _focusFeedbackCompleter != null) {
      await _focusFeedbackCompleter!.future;
    }
    
    _brightnessFeedbackTimer?.cancel();
    
    setState(() {
      _brightnessPositionNormalized = normalizedPosition;
      _showBrightnessFeedback = true;
    });
    
    _brightnessFeedbackTimer = Timer(_brightnessFeedbackDuration, () {
      if (mounted) {
        setState(() {
          _showBrightnessFeedback = false;
        });
      }
    });
  }

  Future<void> _focusOnDetectedFace(Rect faceRect, Size imageSize, AnalysisImage analysisImage) async {
    if (_brightnessMode == BrightnessModeConfig.off || _currentPreview == null) return;

    try {
      final nativePreviewSize = _currentPreview!.nativePreviewSize;
      final previewSizeFlutter = _currentPreview!.previewSize;
      final previewSize = PreviewSize(
        width: nativePreviewSize.width,
        height: nativePreviewSize.height,
      );
      
      final imageCenter = Offset(faceRect.center.dx, faceRect.center.dy);
      final previewPoint = _currentPreview!.convertFromImage(imageCenter, analysisImage);
      
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

      await _showFocusFeedbackAt(normalizedPositionForFeedback);

      if (_brightnessMode == BrightnessModeConfig.manual) {
        await Future.delayed(const Duration(milliseconds: 150));
        try {
          final brightnessValue = _brightnessPercentToValue(_brightnessPercent);
          await CamerawesomePlugin.setBrightness(brightnessValue);
          // Mostrar bolinha azul na mesma posição
          await _showBrightnessFeedbackAt(normalizedPositionForFeedback);
        } catch (e) {
          log("Erro ao aplicar brightness: $e");
        }
      }
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
    if (_brightnessMode == BrightnessModeConfig.off || !mounted || _currentPreview == null) return;

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

      await _showFocusFeedbackAt(normalizedCenter);

      await Future.delayed(const Duration(milliseconds: 150));

      if (_brightnessMode == BrightnessModeConfig.manual) {
        try {
          final brightnessValue = _brightnessPercentToValue(_brightnessPercent);
          await CamerawesomePlugin.setBrightness(brightnessValue);
          // Mostrar bolinha azul no centro
          await _showBrightnessFeedbackAt(normalizedCenter);
        } catch (e) {
          log("Erro ao aplicar brightness: $e");
        }
      }
    } catch (e) {
      log("Erro ao ajustar brilho para centro: $e");
    }
  }

  @override
  void dispose() {
    _noFaceTimer?.cancel();
    _focusFeedbackTimer?.cancel();
    _brightnessFeedbackTimer?.cancel();
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
          CameraAwesomeBuilder.custom(
            saveConfig: SaveConfig.photo(),
            previewFit: CameraPreviewFit.contain,
            sensorConfig: SensorConfig.single(
              aspectRatio: CameraAspectRatios.ratio_4_3,
              flashMode: FlashMode.auto,
              sensor: Sensor.position(SensorPosition.front),
              zoom: 1.0,
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
          if (_showFocusFeedback && _focusPositionNormalized != null)
            Builder(
              builder: (context) {
                final screenPosition = _normalizedToScreenPosition(_focusPositionNormalized!);
                if (screenPosition == null) return const SizedBox();
                return Positioned(
                  left: screenPosition.dx - 5,
                  top: screenPosition.dy - 5,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                  ),
                );
              },
            ),
          if (_showBrightnessFeedback && _brightnessPositionNormalized != null)
            Builder(
              builder: (context) {
                final screenPosition = _normalizedToScreenPosition(_brightnessPositionNormalized!);
                if (screenPosition == null) return const SizedBox();
                return Positioned(
                  left: screenPosition.dx - 5,
                  top: screenPosition.dy - 5,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: Colors.blue,
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

  const _FacePreviewDecorator({
    required this.cameraState,
    required this.faceDetectionStream,
    required this.preview,
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
                    if (!faceModelSnapshot.hasData || faceModelSnapshot.data!.img == null) {
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
          final canvasPoints = faceContour.points
              .map(
                (element) {
                  final originalPoint = Offset(element.x.toDouble(), element.y.toDouble());
                  final pointInPreview = preview!.convertFromImage(originalPoint, model.img!);
                  return Offset(
                    pointInPreview.dx * scaleToCanvasX + preview!.offset.dx,
                    pointInPreview.dy * scaleToCanvasY + preview!.offset.dy,
                  );
                },
              )
              .toList();
          
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
    
    if (canvasTransformation != null) { canvas.restore(); }
  }

  @override
  bool shouldRepaint(FaceContourPainter oldDelegate) {
    return oldDelegate.model != model;
  }
}
