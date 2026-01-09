import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
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

  Rect? _faceRectRaw;
  Size? _imageSizeRaw;
  InputImageRotation _currentRotation = InputImageRotation.rotation0deg;

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


  Future<void> _processCameraImage(AnalysisImage img) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final inputImage = img.toInputImage();
      final faces = await _faceDetector.processImage(inputImage);
      print('👁️ Análise: ${faces.length} rosto(s) detectado(s)');

      if (faces.isNotEmpty) {
        final face = faces.first;

        // Cancela o timer de fallback
        _noFaceTimer?.cancel();
        _noFaceTimer = null;

        // Atualiza a UI PRIMEIRO (sem esperar o foco)
        setState(() {
          _faceRectRaw = face.boundingBox;
          _imageSizeRaw = inputImage.metadata!.size;
          _currentRotation = inputImage.metadata!.rotation;
        });

        // Ajusta foco em background (não bloqueia a UI)
        _adjustHardwareFocus(face.boundingBox, inputImage.metadata!.size);
      } else {
        if (_faceRectRaw != null) {
          setState(() {
            _faceRectRaw = null;
          });
        }

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
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final widgetSize = Size(constraints.maxWidth, constraints.maxHeight);
          // Detecta a orientação física do dispositivo
          final mediaQuery = MediaQuery.of(context);
          final deviceOrientation = mediaQuery.orientation;

          return Stack(
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
              if ((_faceRectRaw != null && _imageSizeRaw != null) || 
                  (_brightnessJustApplied && _imageSizeRaw != null))
                CustomPaint(
                  painter: FacePainter(
                    faceRectRaw: _faceRectRaw,
                    imageSizeRaw: _imageSizeRaw ?? const Size(1280, 720),
                    widgetSize: widgetSize,
                    isFrontCamera: true, // Sempre frontal no camerawesome config acima
                    rotation: _currentRotation,
                    orientation: _currentOrientation,
                    devicePhysicalOrientation: deviceOrientation,
                    brightnessJustApplied: _brightnessJustApplied,
                  ),
                  child: Container(),
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
          );
        },
      ),
    );
  }
}

class FacePainter extends CustomPainter {
  final Rect? faceRectRaw;
  final Size imageSizeRaw;
  final Size widgetSize;
  final bool isFrontCamera;
  final InputImageRotation rotation;
  final AppOrientation orientation;
  final Orientation devicePhysicalOrientation;
  final bool brightnessJustApplied;

  FacePainter({
    required this.faceRectRaw,
    required this.imageSizeRaw,
    required this.widgetSize,
    required this.isFrontCamera,
    required this.rotation,
    required this.orientation,
    required this.devicePhysicalOrientation,
    required this.brightnessJustApplied,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paintRect = Paint()
      ..color = Colors.white.withOpacity(0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    // Bolinha muda de cor/tamanho quando brilho é aplicado
    final Paint paintDot = Paint()
      ..color = brightnessJustApplied ? Colors.red : Colors.yellow
      ..style = PaintingStyle.fill;

    final double dotRadius = brightnessJustApplied ? 5.0 : 3.0;

    // Se não há rosto mas brilho foi aplicado (fallback), desenha no centro
    if (faceRectRaw == null && brightnessJustApplied) {
      final centerPoint = Offset(widgetSize.width / 2, widgetSize.height / 2);
      canvas.drawCircle(centerPoint, dotRadius, paintDot);
      print('🎯 FacePainter: Desenhando bolinha no centro da tela (fallback)');
      return;
    }

    // Se não há rosto, não desenha nada
    if (faceRectRaw == null) {
      return;
    }

    // ========== LOGS DETALHADOS ==========
    print('═══════════════════════════════════════════════════════');
    print('🎨 FacePainter.paint() | App: ${orientation == AppOrientation.portrait ? "Portrait" : "Landscape"} | Física: ${devicePhysicalOrientation == Orientation.portrait ? "Portrait" : "Landscape"} | Rotação: ${_rotationToStringPainter(rotation)} | Câmera: ${isFrontCamera ? "Frontal" : "Traseira"}');
    print('📐 Imagem: ${imageSizeRaw.width.toStringAsFixed(1)}x${imageSizeRaw.height.toStringAsFixed(1)} | Widget: ${widgetSize.width.toStringAsFixed(1)}x${widgetSize.height.toStringAsFixed(1)}');
    print('🎯 Rosto ML Kit: left=${faceRectRaw!.left.toStringAsFixed(1)} top=${faceRectRaw!.top.toStringAsFixed(1)} width=${faceRectRaw!.width.toStringAsFixed(1)} height=${faceRectRaw!.height.toStringAsFixed(1)} | center=(${faceRectRaw!.center.dx.toStringAsFixed(1)}, ${faceRectRaw!.center.dy.toStringAsFixed(1)})');

    // Em Portrait: usa a lógica original simples (como estava funcionando)
    // Em Landscape: converte coordenadas do ML Kit para espaço bruto primeiro
    Rect displayRect;
    Size displaySize;

    if (orientation == AppOrientation.portrait) {
      // PORTRAIT: Lógica original simples (como estava funcionando antes)
      // O ML Kit retorna coordenadas já no espaço rotacionado
      // Usamos diretamente as coordenadas e dimensões rotacionadas
      displaySize = _getDisplaySize();
      displayRect = faceRectRaw!;

      print('📊 Portrait: displaySize=${displaySize.width.toStringAsFixed(1)}x${displaySize.height.toStringAsFixed(1)} | displayRect: left=${displayRect.left.toStringAsFixed(1)} top=${displayRect.top.toStringAsFixed(1)} width=${displayRect.width.toStringAsFixed(1)} height=${displayRect.height.toStringAsFixed(1)}');
    } else {
      // LANDSCAPE: Precisamos converter coordenadas do ML Kit para espaço bruto
      // porque o CameraPreview exibe a imagem bruta
      // Detecta se está em Landscape normal ou invertido baseado na rotação do ML Kit
      Size rotatedSize = _getDisplaySize();

      // Em Landscape, a rotação pode ser:
      // - 90° = Landscape normal (tablet virado para a esquerda/direita padrão)
      // - 270° = Landscape invertido (tablet rotacionado 180°)
      bool isLandscapeInverted = rotation == InputImageRotation.rotation270deg;

      displayRect = _convertMLKitToImageSpace(faceRectRaw!, rotatedSize);
      displaySize = imageSizeRaw; // Preview mostra imagem bruta

      print('📊 Landscape: Rotação=${_rotationToStringPainter(rotation)} | rotatedSize=${rotatedSize.width.toStringAsFixed(1)}x${rotatedSize.height.toStringAsFixed(1)} | displaySize=${displaySize.width.toStringAsFixed(1)}x${displaySize.height.toStringAsFixed(1)} | Invertido=$isLandscapeInverted');
      print('   displayRect convertido: left=${displayRect.left.toStringAsFixed(1)} top=${displayRect.top.toStringAsFixed(1)} width=${displayRect.width.toStringAsFixed(1)} height=${displayRect.height.toStringAsFixed(1)}');

      // A conversão _convertMLKitToImageSpace já trata 90° e 270° corretamente
    }
    print('');

    // Calcula escala do CameraPreview (BoxFit.cover)
    double scaleX = widgetSize.width / displaySize.width;
    double scaleY = widgetSize.height / displaySize.height;
    double scale = math.max(scaleX, scaleY);

    // Offset do crop
    double scaledWidth = displaySize.width * scale;
    double scaledHeight = displaySize.height * scale;
    double offsetX = (widgetSize.width - scaledWidth) / 2.0;
    double offsetY = (widgetSize.height - scaledHeight) / 2.0;

    print('📏 Escala: scaleX=${scaleX.toStringAsFixed(1)} scaleY=${scaleY.toStringAsFixed(1)} scale=${scale.toStringAsFixed(1)} (max) | scaledSize=${scaledWidth.toStringAsFixed(1)}x${scaledHeight.toStringAsFixed(1)} | offsetX=${offsetX.toStringAsFixed(1)} offsetY=${offsetY.toStringAsFixed(1)}');

    // Transforma para coordenadas da tela
    double left = displayRect.left * scale + offsetX;
    double top = displayRect.top * scale + offsetY;
    double width = displayRect.width * scale;
    double height = displayRect.height * scale;

    // Espelha horizontalmente para câmera frontal
    // Portrait: sempre espelha (como estava funcionando)
    // Landscape: não espelha (a conversão já trata isso)
    double leftBeforeMirror = left;
    String mirrorInfo = '';
    if (isFrontCamera) {
      if (orientation == AppOrientation.portrait) {
        left = widgetSize.width - left - width;
        mirrorInfo = '🪞 Espelhado (Portrait-Frontal)';
      } else {
        mirrorInfo = '🪞 Sem espelhamento (Landscape-Frontal)';
      }
    } else {
      mirrorInfo = '🪞 Sem espelhamento (Traseira)';
    }
    if (left != leftBeforeMirror) {
      print('🎯 Antes espelhamento: left=${leftBeforeMirror.toStringAsFixed(1)} | Depois: left=${left.toStringAsFixed(1)} top=${top.toStringAsFixed(1)} width=${width.toStringAsFixed(1)} height=${height.toStringAsFixed(1)} right=${(left + width).toStringAsFixed(1)} bottom=${(top + height).toStringAsFixed(1)} | $mirrorInfo');
    } else {
      print('🎯 Coordenadas: left=${left.toStringAsFixed(1)} top=${top.toStringAsFixed(1)} width=${width.toStringAsFixed(1)} height=${height.toStringAsFixed(1)} right=${(left + width).toStringAsFixed(1)} bottom=${(top + height).toStringAsFixed(1)} | $mirrorInfo');
    }

    // Garante que o retângulo está dentro dos limites da tela
    double leftBeforeClamp = left;
    double topBeforeClamp = top;
    double widthBeforeClamp = width;
    double heightBeforeClamp = height;

    left = left.clamp(0.0, widgetSize.width);
    top = top.clamp(0.0, widgetSize.height);
    width = width.clamp(0.0, widgetSize.width - left);
    height = height.clamp(0.0, widgetSize.height - top);

    if (left != leftBeforeClamp ||
        top != topBeforeClamp ||
        width != widthBeforeClamp ||
        height != heightBeforeClamp) {
      print('⚠️ Clamp: ANTES left=${leftBeforeClamp.toStringAsFixed(1)} top=${topBeforeClamp.toStringAsFixed(1)} width=${widthBeforeClamp.toStringAsFixed(1)} height=${heightBeforeClamp.toStringAsFixed(1)} | DEPOIS left=${left.toStringAsFixed(1)} top=${top.toStringAsFixed(1)} width=${width.toStringAsFixed(1)} height=${height.toStringAsFixed(1)}');
    }

    print('✅ FINAL: left=${left.toStringAsFixed(1)} top=${top.toStringAsFixed(1)} width=${width.toStringAsFixed(1)} height=${height.toStringAsFixed(1)} right=${(left + width).toStringAsFixed(1)} bottom=${(top + height).toStringAsFixed(1)} center=(${(left + width / 2).toStringAsFixed(1)}, ${(top + height / 2).toStringAsFixed(1)})');
    print('═══════════════════════════════════════════════════════');

    // Só desenha se o retângulo tem tamanho válido
    if (width > 0 && height > 0) {
      Rect finalRect = Rect.fromLTWH(left, top, width, height);
      canvas.drawRect(finalRect, paintRect);
      canvas.drawCircle(finalRect.center, dotRadius, paintDot);
    } else {
      print('❌ Retângulo NÃO desenhado: width=$width ou height=$height é inválido!');
    }
  }

  String _rotationToStringPainter(InputImageRotation rotation) {
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

  // Retorna o tamanho da imagem no espaço rotacionado (como o ML Kit vê)
  Size _getDisplaySize() {
    // Após rotação de 90° ou 270°, as dimensões são trocadas
    if (rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg) {
      return Size(imageSizeRaw.height, imageSizeRaw.width);
    }
    return imageSizeRaw;
  }

  // Converte coordenadas do espaço ML Kit (rotacionado) para o espaço da imagem bruta
  // O CameraPreview exibe a imagem bruta, então precisamos fazer essa conversão
  Rect _convertMLKitToImageSpace(Rect mlKitRect, Size rotatedSize) {
    // Se não há rotação (0° ou 180°), as coordenadas já estão corretas
    if (rotation == InputImageRotation.rotation0deg) {
      return mlKitRect;
    }

    // Para rotações 90°, 180°, 270°, precisamos converter
    switch (rotation) {
      case InputImageRotation.rotation90deg:
        // Rotação 90° horário: (x, y) no espaço rotacionado → (height-y, x) no espaço bruto
        // rotatedSize = (720, 1280), imageSizeRaw = (1280, 720)
        return Rect.fromLTWH(
          rotatedSize.height - mlKitRect.bottom, // x na imagem bruta
          mlKitRect.left, // y na imagem bruta
          mlKitRect.height, // width na imagem bruta
          mlKitRect.width, // height na imagem bruta
        );

      case InputImageRotation.rotation180deg:
        // Rotação 180°: (x, y) → (width-x, height-y)
        return Rect.fromLTWH(
          rotatedSize.width - mlKitRect.right,
          rotatedSize.height - mlKitRect.bottom,
          mlKitRect.width,
          mlKitRect.height,
        );

      case InputImageRotation.rotation270deg:
        // Rotação 270° (90° anti-horário): (x, y) → (y, width-x)
        return Rect.fromLTWH(
          mlKitRect.top, // x na imagem bruta
          rotatedSize.width - mlKitRect.right, // y na imagem bruta
          mlKitRect.height, // width na imagem bruta
          mlKitRect.width, // height na imagem bruta
        );

      case InputImageRotation.rotation0deg:
        return mlKitRect;
    }
  }

  @override
  bool shouldRepaint(FacePainter oldDelegate) {
    return oldDelegate.faceRectRaw != faceRectRaw ||
        oldDelegate.widgetSize != widgetSize ||
        oldDelegate.orientation != orientation ||
        oldDelegate.brightnessJustApplied != brightnessJustApplied;
  }
}
