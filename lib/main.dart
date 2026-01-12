import 'dart:async';
import 'dart:io';
import 'dart:developer';
import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:camerawesome/pigeon.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  final prefs = await SharedPreferences.getInstance();
  final orientationIndex =
      prefs.getInt('appOrientation') ?? AppOrientation.portrait.index;
  final savedOrientation = AppOrientation.values[orientationIndex];

  if (savedOrientation == AppOrientation.portrait) {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  } else {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

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
  bool _brightnessJustApplied = false;
  Timer? _brightnessFeedbackTimer;

  Size? _imageSizeRaw;
  late StreamController<FaceDetectionModel> _faceDetectionController;

  BrightnessModeConfig _brightnessMode = BrightnessModeConfig.auto;
  double _brightnessPercent = 0.0;
  AppOrientation _currentOrientation = AppOrientation.portrait;
  
  double _brightnessPercentToValue(double percent) {
    return ((percent + 100.0) / 200.0).clamp(0.0, 1.0);
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
    
    final orientationIndex =
        prefs.getInt('appOrientation') ?? AppOrientation.portrait.index;

    setState(() {
      _brightnessMode = BrightnessModeConfig.values[modeIndex];
      _brightnessPercent = brightnessPercent.clamp(-100.0, 100.0);
      _currentOrientation = AppOrientation.values[orientationIndex];
    });

    _applyOrientation(_currentOrientation);
  }

  void _applyOrientation(AppOrientation orientation) {
    if (orientation == AppOrientation.portrait) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  Widget _buildCameraLayout(CameraState state, AnalysisPreview preview) {
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
          currentOrientation: _currentOrientation,
        ),
      ),
    );

    if (result != null) {
      final newMode = result['mode'] as BrightnessModeConfig;
      final newBrightness = result['offset'] as double;
      final newOrientation = result['orientation'] as AppOrientation;

      if (_currentOrientation != newOrientation) {
        _applyOrientation(newOrientation);
      }

      setState(() {
        _brightnessMode = newMode;
        _brightnessPercent = newBrightness.clamp(-100.0, 100.0);
        _currentOrientation = newOrientation;
      });
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
        _adjustHardwareFocus(face.boundingBox, inputImage.metadata!.size);
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

  Future<void> _adjustHardwareFocus(Rect faceRect, Size imageSize) async {
    if (_brightnessMode == BrightnessModeConfig.off) return;

    var x = faceRect.center.dx / imageSize.width;
    var y = faceRect.center.dy / imageSize.height;

    bool isLandscape = _currentOrientation == AppOrientation.landscape;

    if (Platform.isAndroid) {
      if (isLandscape) {
        double tempX = x;
        x = 1.0 - y;
        y = tempX;
      } else {
        double tempX = x;
        x = y;
        y = 1.0 - tempX;
      }
    } else if (Platform.isIOS) {
      if (isLandscape) {
        double tempX = x;
        x = y;
        y = 1.0 - tempX;
      }
    }

    final point = Offset(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));

    try {
      PreviewSize previewSize;
      try {
        previewSize = await CamerawesomePlugin.getEffectivPreviewSize(0);
        if (previewSize.width == 0 || previewSize.height == 0) {
          previewSize = PreviewSize(
            width: imageSize.width,
            height: imageSize.height,
          );
        }
      } catch (e) {
        previewSize = PreviewSize(
          width: imageSize.width,
          height: imageSize.height,
        );
      }

      await CamerawesomePlugin.focusOnPoint(
        previewSize: previewSize,
        position: point,
        androidFocusSettings: null,
      );

      log('🎯 Foco: (${point.dx.toStringAsFixed(2)}, ${point.dy.toStringAsFixed(2)})');

      if (_brightnessMode == BrightnessModeConfig.manual) {
        await Future.delayed(const Duration(milliseconds: 150));
        try {
          final brightnessValue = _brightnessPercentToValue(_brightnessPercent);
          await CamerawesomePlugin.setBrightness(brightnessValue);
        } catch (e) {
          log("Erro ao aplicar brightness: $e");
        }
      } else if (_brightnessMode == BrightnessModeConfig.auto) {
        await Future.delayed(const Duration(milliseconds: 150));
        try {
          await CamerawesomePlugin.setBrightness(0.5);
        } catch (e) {
          log("Erro ao resetar brightness: $e");
        }
      }

      setState(() {
        _brightnessJustApplied = true;
      });
      _brightnessFeedbackTimer?.cancel();
      _brightnessFeedbackTimer = Timer(_brightnessFeedbackDuration, () {
        if (mounted) {
          setState(() {
            _brightnessJustApplied = false;
          });
        }
      });
    } catch (e) {
      log("Erro ao ajustar foco: $e");
    }
  }

  void _startNoFaceTimer() {
    _noFaceTimer?.cancel();
    _noFaceTimer = null;

    _noFaceTimer = Timer(_noFaceTimeout, () {
      _noFaceTimer = null;
      _adjustBrightnessToCenter();
    });
  }

  Future<void> _adjustBrightnessToCenter() async {
    if (_brightnessMode == BrightnessModeConfig.off || !mounted) return;

    try {
      final centerPoint = Offset(0.5, 0.5);
      
      final imageSize = _imageSizeRaw ?? const Size(1280, 720);
      PreviewSize previewSize;
      try {
        previewSize = await CamerawesomePlugin.getEffectivPreviewSize(0);
        if (previewSize.width == 0 || previewSize.height == 0) {
          previewSize = PreviewSize(
            width: imageSize.width,
            height: imageSize.height,
          );
        }
      } catch (e) {
        previewSize = PreviewSize(
          width: imageSize.width,
          height: imageSize.height,
        );
      }

      await CamerawesomePlugin.focusOnPoint(
        previewSize: previewSize,
        position: centerPoint,
        androidFocusSettings: null,
      );

      log('🎯 Foco centro: (${centerPoint.dx.toStringAsFixed(2)}, ${centerPoint.dy.toStringAsFixed(2)})');

      await Future.delayed(const Duration(milliseconds: 150));

      if (_brightnessMode == BrightnessModeConfig.manual) {
        try {
          final brightnessValue = _brightnessPercentToValue(_brightnessPercent);
          await CamerawesomePlugin.setBrightness(brightnessValue);
        } catch (e) {
          log("Erro ao aplicar brightness: $e");
        }
      } else if (_brightnessMode == BrightnessModeConfig.auto) {
        try {
          await CamerawesomePlugin.setBrightness(0.5);
        } catch (e) {
          log("Erro ao resetar brightness: $e");
        }
      }

      setState(() {
        _brightnessJustApplied = true;
      });
      _brightnessFeedbackTimer?.cancel();
      _brightnessFeedbackTimer = Timer(_brightnessFeedbackDuration, () {
        if (mounted) {
          setState(() {
            _brightnessJustApplied = false;
          });
        }
      });
    } catch (e) {
      log("Erro ao ajustar brilho para centro: $e");
    }
  }

  @override
  void dispose() {
    _noFaceTimer?.cancel();
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
          if (_brightnessJustApplied)
            Center(
              child: Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
              ),
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
    
    if (canvasTransformation != null) {
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(FaceContourPainter oldDelegate) {
    return oldDelegate.model != model;
  }
}
