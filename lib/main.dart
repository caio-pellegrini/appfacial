import 'dart:async';
import 'dart:io';
import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:camerawesome/pigeon.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'settings_screen.dart';

// Extensão para converter AnalysisImage para InputImage
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

  // Carrega a orientação salva ou usa Portrait como padrão
  final prefs = await SharedPreferences.getInstance();
  final orientationIndex =
      prefs.getInt('appOrientation') ?? AppOrientation.portrait.index;
  final savedOrientation = AppOrientation.values[orientationIndex];

  // Aplica a orientação salva
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

  BrightnessModeConfig _brightnessMode = BrightnessModeConfig.auto;
  double _brightnessPercent = 0.0; // Brightness em percentual: -100% a +100% (padrão 0% = neutro)
  AppOrientation _currentOrientation = AppOrientation.portrait;
  
  // Converte percentual (-100 a +100) para brightness do camerawesome (0.0 a 1.0)
  double _brightnessPercentToValue(double percent) {
    return ((percent + 100.0) / 200.0).clamp(0.0, 1.0);
  }

  static const Duration _noFaceTimeout = Duration(seconds: 5);
  static const Duration _brightnessFeedbackDuration = Duration(milliseconds: 300);

  @override
  void initState() {
    super.initState();
    // Opções mais sensíveis para detectar rostos mesmo em condições adversas
    final options = FaceDetectorOptions(
      performanceMode:
          FaceDetectorMode.accurate, // Mais preciso, detecta melhor contra luz
      enableContours: false,
      enableClassification: false,
      minFaceSize: 0.1, // Reduz o tamanho mínimo do rosto (mais sensível)
    );
    _faceDetector = FaceDetector(options: options);
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

    // Aplica a orientação
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

      // Se mudou a orientação, aplica a nova orientação
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


  String _rotationToString(InputImageRotation rotation) {
    switch (rotation) {
      case InputImageRotation.rotation0deg:
        return '0°';
      case InputImageRotation.rotation90deg:
        return '90°';
      case InputImageRotation.rotation180deg:
        return '180°';
      case InputImageRotation.rotation270deg:
        return '270°';
    }
  }

  Future<void> _processCameraImage(AnalysisImage img) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final inputImage = img.toInputImage();
      final faces = await _faceDetector.processImage(inputImage);
      print('👁️ Análise: ${faces.length} rosto(s) detectado(s)');

      if (faces.isNotEmpty) {
        final face = faces.first;

        // ========== LOGS DAS COORDENADAS DO ML KIT ==========
        print('═══════════════════════════════════════════════════════');
        print('👁️ ML Kit - Rosto detectado');
        print('📐 Tamanho da imagem: ${inputImage.metadata!.size.width.toStringAsFixed(1)}x${inputImage.metadata!.size.height.toStringAsFixed(1)}');
        print('🔄 Rotação: ${_rotationToString(inputImage.metadata!.rotation)}');
        print('📱 Orientação do app: ${_currentOrientation == AppOrientation.portrait ? "Portrait" : "Landscape"}');
        print('🎯 Coordenadas do rosto (ML Kit):');
        print('   left=${face.boundingBox.left.toStringAsFixed(1)}');
        print('   top=${face.boundingBox.top.toStringAsFixed(1)}');
        print('   width=${face.boundingBox.width.toStringAsFixed(1)}');
        print('   height=${face.boundingBox.height.toStringAsFixed(1)}');
        print('   right=${face.boundingBox.right.toStringAsFixed(1)}');
        print('   bottom=${face.boundingBox.bottom.toStringAsFixed(1)}');
        print('   center=(${face.boundingBox.center.dx.toStringAsFixed(1)}, ${face.boundingBox.center.dy.toStringAsFixed(1)})');
        print('═══════════════════════════════════════════════════════');

        // Cancela o timer de fallback
        _noFaceTimer?.cancel();
        _noFaceTimer = null;

        // Atualiza informações da imagem
        setState(() {
          _imageSizeRaw = inputImage.metadata!.size;
        });

        // Ajusta foco em background (não bloqueia a UI)
        _adjustHardwareFocus(face.boundingBox, inputImage.metadata!.size);
      } else {
        // Inicia timer de fallback se não há rosto (só se modo não for Off)
        // e se não houver um timer já ativo (evita resetar a cada frame)
        if (_brightnessMode != BrightnessModeConfig.off) {
          if (_noFaceTimer == null || !_noFaceTimer!.isActive) {
            _startNoFaceTimer();
          }
        }
      }
    } catch (e) {
      print("Erro: $e");
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _adjustHardwareFocus(Rect faceRect, Size imageSize) async {
    if (_brightnessMode == BrightnessModeConfig.off) return;

    // Calcula centro da face relativo à imagem (0.0 - 1.0)
    double centerX = faceRect.center.dx;
    double centerY = faceRect.center.dy;
    double x = centerX / imageSize.width;
    double y = centerY / imageSize.height;

    // Ajuste para rotação e orientação
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

      print('🎯 Foco aplicado no rosto: (${point.dx.toStringAsFixed(2)}, ${point.dy.toStringAsFixed(2)})');

      if (_brightnessMode == BrightnessModeConfig.manual) {
        await Future.delayed(const Duration(milliseconds: 150));
        try {
          final brightnessValue = _brightnessPercentToValue(_brightnessPercent);
          await CamerawesomePlugin.setBrightness(brightnessValue);
        } catch (e) {
          print("Erro ao aplicar brightness: $e");
        }
      } else if (_brightnessMode == BrightnessModeConfig.auto) {
        await Future.delayed(const Duration(milliseconds: 150));
        try {
          await CamerawesomePlugin.setBrightness(0.5);
        } catch (e) {
          print("Erro ao resetar brightness: $e");
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
      print("Erro ao ajustar foco: $e");
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
      // Ponto central da tela (0.5, 0.5)
      final centerPoint = Offset(0.5, 0.5);
      
      // Usa um previewSize padrão (será ajustado pela câmera)
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

      print('🎯 Foco aplicado no centro: (${centerPoint.dx.toStringAsFixed(2)}, ${centerPoint.dy.toStringAsFixed(2)})');

      await Future.delayed(const Duration(milliseconds: 150));

      // Se modo Manual, aplica brightness configurado pelo usuário
      if (_brightnessMode == BrightnessModeConfig.manual) {
        try {
          final brightnessValue = _brightnessPercentToValue(_brightnessPercent);
          await CamerawesomePlugin.setBrightness(brightnessValue);
        } catch (e) {
          print("Erro ao aplicar brightness: $e");
        }
      } else if (_brightnessMode == BrightnessModeConfig.auto) {
        // No modo Auto, reseta brightness para neutro (0.5 = 0%)
        try {
          await CamerawesomePlugin.setBrightness(0.5);
        } catch (e) {
          print("Erro ao resetar brightness: $e");
        }
      }

      // Feedback visual também no fallback
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
      print("Erro ao ajustar brilho para centro: $e");
    }
  }

  @override
  void dispose() {
    _noFaceTimer?.cancel();
    _brightnessFeedbackTimer?.cancel();
    _faceDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final screenSize = mediaQuery.size;
    final orientation = mediaQuery.orientation;
    
    // Calcula aspect ratio da tela
    final screenAspectRatio = screenSize.width / screenSize.height;
    final expectedAspectRatio = 16.0 / 9.0;
    
    // Logs para entender o problema do landscape
    print('═══════════════════════════════════════════════════════');
    print('📱 Build - Orientação App: ${_currentOrientation == AppOrientation.portrait ? "Portrait" : "Landscape"}');
    print('📱 Build - Orientação Física: ${orientation == Orientation.portrait ? "Portrait" : "Landscape"}');
    print('📐 Tela: ${screenSize.width.toStringAsFixed(1)}x${screenSize.height.toStringAsFixed(1)}');
    print('📐 Aspect Ratio da tela: ${screenAspectRatio.toStringAsFixed(3)}');
    print('📐 Aspect Ratio esperado (16:9): ${expectedAspectRatio.toStringAsFixed(3)}');
    print('📐 Diferença: ${(screenAspectRatio - expectedAspectRatio).abs().toStringAsFixed(3)}');
    print('═══════════════════════════════════════════════════════');
    
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraAwesomeBuilder.previewOnly(
            sensorConfig: SensorConfig.single(
              sensor: Sensor.position(SensorPosition.front),
              aspectRatio: CameraAspectRatios.ratio_16_9,
            ),
            onImageForAnalysis: (img) => _processCameraImage(img),
            imageAnalysisConfig: AnalysisConfig(
              androidOptions: const AndroidAnalysisOptions.nv21(
                width: 1024,
              ),
              maxFramesPerSecond: 5,
              autoStart: true,
            ),
            builder: (cameraModeState, preview) {
              // Preview já é renderizado automaticamente
              return const SizedBox.shrink();
            },
          ),
          // Bolinha vermelha apenas no fallback (5 segundos sem rosto)
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
          // Ícone de configurações no canto superior direito
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

