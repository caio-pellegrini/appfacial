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
  bool _exposureJustApplied = false;
  Timer? _exposureFeedbackTimer;

  Rect? _faceRectRaw;
  Size? _imageSizeRaw;
  InputImageRotation _currentRotation = InputImageRotation.rotation0deg;

  ExposureModeConfig _exposureMode = ExposureModeConfig.auto;
  double _brightnessPercent = 0.0; // Brightness em percentual: -100% a +100% (padrão 0% = neutro)
  AppOrientation _currentOrientation = AppOrientation.portrait;
  
  // Converte percentual (-100 a +100) para brightness do camerawesome (0.0 a 1.0)
  double _brightnessPercentToValue(double percent) {
    return ((percent + 100.0) / 200.0).clamp(0.0, 1.0);
  }

  static const Duration _noFaceTimeout = Duration(seconds: 5);
  static const Duration _exposureFeedbackDuration = Duration(milliseconds: 300);

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
    final modeIndex =
        prefs.getInt('exposureMode') ?? ExposureModeConfig.auto.index;
    // Migração: converte valores antigos para o novo sistema de percentual
    final oldOffset = prefs.getDouble('exposureOffset');
    final oldBrightness = prefs.getDouble('brightness');
    
    // Se existe brightness antigo (0.0-1.0), converte para percentual
    // Se existe exposureOffset antigo, usa 0% como padrão
    double brightnessPercent = 0.0; // Padrão: 0% (neutro)
    if (oldBrightness != null) {
      // Converte de 0.0-1.0 para -100 a +100
      brightnessPercent = (oldBrightness * 200.0) - 100.0;
    } else if (oldOffset != null) {
      // Se tinha offset antigo, usa 0% como padrão (neutro)
      brightnessPercent = 0.0;
    }
    
    // Carrega o percentual salvo ou usa o padrão 0%
    brightnessPercent = prefs.getDouble('brightnessPercent') ?? brightnessPercent;
    
    final orientationIndex =
        prefs.getInt('appOrientation') ?? AppOrientation.portrait.index;

    setState(() {
      _exposureMode = ExposureModeConfig.values[modeIndex];
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
          currentMode: _exposureMode,
          currentOffset: _brightnessPercent,
          currentOrientation: _currentOrientation,
        ),
      ),
    );

    if (result != null) {
      final newMode = result['mode'] as ExposureModeConfig;
      final newBrightness = result['offset'] as double; // Agora é brightness
      final newOrientation = result['orientation'] as AppOrientation;

      // Se mudou a orientação, aplica a nova orientação
      if (_currentOrientation != newOrientation) {
        _applyOrientation(newOrientation);
      }

      setState(() {
        _exposureMode = newMode;
        _brightnessPercent = newBrightness.clamp(-100.0, 100.0);
        _currentOrientation = newOrientation;
      });
    }
  }


  Future<void> _processCameraImage(AnalysisImage img) async {
    if (_isProcessing) {
      print('⏸️ _processCameraImage: Já está processando, ignorando frame');
      return;
    }
    _isProcessing = true;

    try {
      final inputImage = img.toInputImage();
      final faces = await _faceDetector.processImage(inputImage);
      print('👁️ Análise: ${faces.length} rosto(s) detectado(s)');

      if (faces.isNotEmpty) {
        final face = faces.first;

        // Cancela o timer de fallback
        if (_noFaceTimer != null && _noFaceTimer!.isActive) {
          print('⏱️ TIMER CANCELADO: Rosto detectado, cancelando fallback');
          _noFaceTimer!.cancel();
          _noFaceTimer = null;
        }

        print('🔍 ROSTO DETECTADO!');
        print(
          '🔄 InputImageRotation: ${_rotationToString(inputImage.metadata!.rotation)}',
        );
        print('🎯 BoundingBox do ML Kit:');
        print(
          '   left: ${face.boundingBox.left}, top: ${face.boundingBox.top}',
        );
        print(
          '   width: ${face.boundingBox.width}, height: ${face.boundingBox.height}',
        );
        print(
          '   center: (${face.boundingBox.center.dx}, ${face.boundingBox.center.dy})',
        );
        print('');

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
        // MAS: só inicia se não houver um timer já ativo (evita resetar a cada frame)
        print('🚫 SEM ROSTO: Modo atual=${_exposureMode.name}');
        if (_exposureMode != ExposureModeConfig.off) {
          // Só inicia um novo timer se não houver um timer ativo
          if (_noFaceTimer == null || !_noFaceTimer!.isActive) {
            print('⏱️ INICIANDO TIMER: Fallback será acionado em ${_noFaceTimeout.inSeconds} segundos');
            _startNoFaceTimer();
          } else {
            print('⏱️ Timer já está ativo, mantendo...');
          }
        } else {
          print('⏱️ TIMER NÃO INICIADO: Modo está Off');
        }
      }
    } catch (e) {
      print("Erro: $e");
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _adjustHardwareFocus(Rect faceRect, Size imageSize) async {
    // Se o modo está Off, não faz nada (incluindo feedback visual)
    if (_exposureMode == ExposureModeConfig.off) {
      return;
    }

    // Calcula centro da face relativo à imagem (0.0 - 1.0)
    double centerX = faceRect.center.dx;
    double centerY = faceRect.center.dy;
    double x = centerX / imageSize.width;
    double y = centerY / imageSize.height;

    // Ajuste para rotação e orientação
    bool isLandscape = _currentOrientation == AppOrientation.landscape;

    if (Platform.isAndroid) {
      if (isLandscape) {
        // Landscape: imagem vem com rotação diferente
        double tempX = x;
        x = 1.0 - y;
        y = tempX;
      } else {
        // Portrait: rotação 270deg (Android frontal)
        double tempX = x;
        x = y;
        y = 1.0 - tempX;
      }
    } else if (Platform.isIOS) {
      if (isLandscape) {
        // iOS em landscape pode precisar de ajuste
        double tempX = x;
        x = y;
        y = 1.0 - tempX;
      }
      // Portrait no iOS geralmente não precisa ajuste
    }

    final point = Offset(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));

    try {
      // Calcula previewSize para focusOnPoint
      // Obtém o previewSize efetivo da câmera ou usa o tamanho da imagem
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

      // Aplica foco e exposição no ponto do rosto (unificado no camerawesome)
      await CamerawesomePlugin.focusOnPoint(
        previewSize: previewSize,
        position: point,
        androidFocusSettings: null,
      );

      // Se modo Manual, aplica brightness configurado
      if (_exposureMode == ExposureModeConfig.manual) {
        await Future.delayed(const Duration(milliseconds: 150));
        try {
          final brightnessValue = _brightnessPercentToValue(_brightnessPercent);
          await CamerawesomePlugin.setBrightness(brightnessValue);
        } catch (e) {
          print("Erro ao aplicar brightness: $e");
        }
      } else if (_exposureMode == ExposureModeConfig.auto) {
        // No modo Auto, reseta brightness para neutro (0.5 = 0%)
        await Future.delayed(const Duration(milliseconds: 150));
        try {
          await CamerawesomePlugin.setBrightness(0.5);
        } catch (e) {
          print("Erro ao resetar brightness: $e");
        }
      }

      // Feedback visual: faz a bolinha piscar (fica vermelha e maior)
      setState(() {
        _exposureJustApplied = true;
      });
      _exposureFeedbackTimer?.cancel();
      _exposureFeedbackTimer = Timer(_exposureFeedbackDuration, () {
        if (mounted) {
          setState(() {
            _exposureJustApplied = false;
          });
        }
      });
    } catch (e) {
      print("Erro ao ajustar foco: $e");
    }
  }

  void _startNoFaceTimer() {
    final now = DateTime.now();
    print('⏱️ _startNoFaceTimer() chamado em ${now.toString().substring(11, 19)}');
    
    // Cancela timer anterior apenas se existir e estiver ativo
    if (_noFaceTimer != null && _noFaceTimer!.isActive) {
      print('⏱️ Timer anterior estava ativo, cancelando antes de criar novo...');
      _noFaceTimer!.cancel();
    }
    
    _noFaceTimer = null; // Limpa referência

    final expectedExpireTime = now.add(_noFaceTimeout);
    print('⏱️ Criando novo timer: timeout=${_noFaceTimeout.inSeconds}s | Expira em ${expectedExpireTime.toString().substring(11, 19)}');
    
    _noFaceTimer = Timer(_noFaceTimeout, () {
      final expireTime = DateTime.now();
      print('═══════════════════════════════════════════════════════');
      print('⏱️ TIMER EXPIROU! Tempo: ${expireTime.toString().substring(11, 19)}');
      print('⏱️ Estado: modo=${_exposureMode.name} | _isProcessing=$_isProcessing | mounted=$mounted');
      print('⏱️ Acionando _adjustExposureToCenter()...');
      print('═══════════════════════════════════════════════════════');
      // Limpa a referência do timer após expirar
      _noFaceTimer = null;
      // Se não detectou rosto por X segundos, ajusta exposição para o centro
      _adjustExposureToCenter();
    });
    
    // Verifica se o timer foi criado corretamente
    if (_noFaceTimer != null) {
      print('⏱️ Timer criado com sucesso: isActive=${_noFaceTimer!.isActive}');
    } else {
      print('⏱️ ⚠️ ERRO: Timer NÃO foi criado!');
    }
  }

  Future<void> _adjustExposureToCenter() async {
    final now = DateTime.now();
    print('🎯 _adjustExposureToCenter() chamado em ${now.toString().substring(11, 19)}');
    print('🎯 Estado: modo=${_exposureMode.name}, mounted=$mounted, _isProcessing=$_isProcessing');
    
    // Se o modo está Off, não faz nada
    if (_exposureMode == ExposureModeConfig.off) {
      print('🎯 ABORTANDO: Modo está Off');
      return;
    }
    
    if (!mounted) {
      print('🎯 ABORTANDO: Widget não está montado');
      return;
    }
    
    print('🎯 Prosseguindo com fallback: aplicando exposição no centro da tela');

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

      // Aplica foco no centro (unificado no camerawesome)
      await CamerawesomePlugin.focusOnPoint(
        previewSize: previewSize,
        position: centerPoint,
        androidFocusSettings: null,
      );

      // Aguarda um pouco para a câmera processar o ajuste
      await Future.delayed(const Duration(milliseconds: 150));

      // Se modo Manual, aplica brightness configurado pelo usuário
      if (_exposureMode == ExposureModeConfig.manual) {
        try {
          final brightnessValue = _brightnessPercentToValue(_brightnessPercent);
          await CamerawesomePlugin.setBrightness(brightnessValue);
        } catch (e) {
          print("Erro ao aplicar brightness: $e");
        }
      } else if (_exposureMode == ExposureModeConfig.auto) {
        // No modo Auto, reseta brightness para neutro (0.5 = 0%)
        try {
          await CamerawesomePlugin.setBrightness(0.5);
        } catch (e) {
          print("Erro ao resetar brightness: $e");
        }
      }

      // Feedback visual também no fallback
      setState(() {
        _exposureJustApplied = true;
      });
      _exposureFeedbackTimer?.cancel();
      _exposureFeedbackTimer = Timer(_exposureFeedbackDuration, () {
        if (mounted) {
          setState(() {
            _exposureJustApplied = false;
          });
        }
      });
    } catch (e) {
      print("Erro ao ajustar exposição para centro: $e");
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

  @override
  void dispose() {
    print('🗑️ dispose() chamado: cancelando timers');
    if (_noFaceTimer != null && _noFaceTimer!.isActive) {
      print('🗑️ Cancelando _noFaceTimer ativo');
      _noFaceTimer!.cancel();
      _noFaceTimer = null;
    }
    _exposureFeedbackTimer?.cancel();
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
                  (_exposureJustApplied && _imageSizeRaw != null))
                CustomPaint(
                  painter: FacePainter(
                    faceRectRaw: _faceRectRaw,
                    imageSizeRaw: _imageSizeRaw ?? const Size(1280, 720),
                    widgetSize: widgetSize,
                    isFrontCamera: true, // Sempre frontal no camerawesome config acima
                    rotation: _currentRotation,
                    orientation: _currentOrientation,
                    devicePhysicalOrientation: deviceOrientation,
                    exposureJustApplied: _exposureJustApplied,
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
  final bool exposureJustApplied;

  FacePainter({
    required this.faceRectRaw,
    required this.imageSizeRaw,
    required this.widgetSize,
    required this.isFrontCamera,
    required this.rotation,
    required this.orientation,
    required this.devicePhysicalOrientation,
    required this.exposureJustApplied,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paintRect = Paint()
      ..color = Colors.white.withOpacity(0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    // Bolinha muda de cor/tamanho quando exposição é aplicada
    final Paint paintDot = Paint()
      ..color = exposureJustApplied ? Colors.red : Colors.yellow
      ..style = PaintingStyle.fill;

    final double dotRadius = exposureJustApplied ? 5.0 : 3.0;

    // Se não há rosto mas exposição foi aplicada (fallback), desenha no centro
    if (faceRectRaw == null && exposureJustApplied) {
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
      print(
        '❌ Retângulo NÃO desenhado: width=$width ou height=$height é inválido!',
      );
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
        oldDelegate.exposureJustApplied != exposureJustApplied;
  }
}
