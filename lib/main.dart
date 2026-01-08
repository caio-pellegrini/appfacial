import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'settings_screen.dart';

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

  final cameras = await availableCameras();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: FaceAwareCamera(cameras: cameras),
    ),
  );
}

class FaceAwareCamera extends StatefulWidget {
  final List<CameraDescription> cameras;
  const FaceAwareCamera({Key? key, required this.cameras}) : super(key: key);

  @override
  _FaceAwareCameraState createState() => _FaceAwareCameraState();
}

class _FaceAwareCameraState extends State<FaceAwareCamera> {
  CameraController? _controller;
  late FaceDetector _faceDetector;
  bool _isProcessing = false;
  CameraDescription? _cameraDescription;
  Timer? _noFaceTimer;
  bool _exposureJustApplied = false;
  Timer? _exposureFeedbackTimer;
  double? _minExposureOffset;
  double? _maxExposureOffset;

  Rect? _faceRectRaw;
  Size? _imageSizeRaw;
  InputImageRotation _currentRotation = InputImageRotation.rotation0deg;

  ExposureModeConfig _exposureMode = ExposureModeConfig.auto;
  double _exposureOffset = 1.0;
  AppOrientation _currentOrientation = AppOrientation.portrait;

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
    _initializeCamera();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final modeIndex =
        prefs.getInt('exposureMode') ?? ExposureModeConfig.auto.index;
    final offset = prefs.getDouble('exposureOffset') ?? 1.0;
    final orientationIndex =
        prefs.getInt('appOrientation') ?? AppOrientation.portrait.index;

    setState(() {
      _exposureMode = ExposureModeConfig.values[modeIndex];
      _exposureOffset = offset;
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
          currentOffset: _exposureOffset,
          currentOrientation: _currentOrientation,
        ),
      ),
    );

    if (result != null) {
      final newMode = result['mode'] as ExposureModeConfig;
      final newOffset = result['offset'] as double;
      final newOrientation = result['orientation'] as AppOrientation;

      // Se mudou de Manual para Auto/Off, reseta o offset
      if (_exposureMode == ExposureModeConfig.manual &&
          newMode != ExposureModeConfig.manual) {
        await _resetExposureOffset();
      }

      // Se mudou a orientação, aplica a nova orientação
      if (_currentOrientation != newOrientation) {
        _applyOrientation(newOrientation);
        // Força reconstrução da câmera quando a orientação muda
        _controller?.dispose();
        await _initializeCamera();
      }

      setState(() {
        _exposureMode = newMode;
        _exposureOffset = newOffset;
        _currentOrientation = newOrientation;
      });
    }
  }

  Future<void> _resetExposureOffset() async {
    if (_controller == null) return;
    if (_minExposureOffset == null || _maxExposureOffset == null) return;

    try {
      await _controller!.setExposureOffset(0.0);
    } catch (e) {}
  }

  Future<void> _initializeCamera() async {
    _cameraDescription = widget.cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => widget.cameras.first,
    );

    _controller = CameraController(
      _cameraDescription!,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    try {
      await _controller!.initialize();
      if (mounted) {
        // Obtém os limites de exposição suportados pela câmera
        try {
          _minExposureOffset = await _controller!.getMinExposureOffset();
          _maxExposureOffset = await _controller!.getMaxExposureOffset();
        } catch (e) {
          // Algumas câmeras podem não suportar exposure offset
          print("Exposure offset não suportado: $e");
        }
        setState(() {});
        _controller!.startImageStream(_processCameraImage);
      }
    } catch (e) {
      print("Erro ao iniciar câmera: $e");
    }
  }

  void _processCameraImage(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) {
        _isProcessing = false;
        return;
      }

      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isNotEmpty) {
        final face = faces.first;

        // Cancela o timer de fallback
        _noFaceTimer?.cancel();

        print('🔍 ROSTO DETECTADO!');
        print('📐 CameraImage: ${image.width} x ${image.height}');
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
          _imageSizeRaw = Size(image.width.toDouble(), image.height.toDouble());
          _currentRotation = inputImage.metadata!.rotation;
        });

        // Ajusta foco em background (não bloqueia a UI)
        _adjustHardwareFocus(face.boundingBox, image);
      } else {
        if (_faceRectRaw != null) {
          setState(() {
            _faceRectRaw = null;
          });
        }

        // Inicia timer de fallback se não há rosto (só se modo não for Off)
        if (_exposureMode != ExposureModeConfig.off) {
          _startNoFaceTimer();

          try {
            await _controller?.setExposurePoint(null);
            await _controller?.setFocusPoint(null);
            // Reseta o offset de exposição quando não há rosto
            if (_minExposureOffset != null && _maxExposureOffset != null) {
              try {
                await _controller?.setExposureOffset(0.0);
              } catch (e) {}
            }
          } catch (e) {}
        }
      }
    } catch (e) {
      print("Erro: $e");
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _adjustHardwareFocus(Rect faceRect, CameraImage image) async {
    if (_controller == null) return;

    // Se o modo está Off, não faz nada (incluindo feedback visual)
    if (_exposureMode == ExposureModeConfig.off) {
      return;
    }

    double centerX = faceRect.center.dx;
    double centerY = faceRect.center.dy;
    double x = centerX / image.width;
    double y = centerY / image.height;

    // Ajuste para rotação e orientação
    bool isLandscape = _currentOrientation == AppOrientation.landscape;

    if (Platform.isAndroid &&
        _cameraDescription!.lensDirection == CameraLensDirection.front) {
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
      await _controller!.setExposureMode(ExposureMode.auto);
      await _controller!.setFocusMode(FocusMode.auto);

      // Aplica exposição e foco no ponto do rosto
      await _controller!.setExposurePoint(point);
      await _controller!.setFocusPoint(point);

      // Se modo Manual, aplica offset após delay
      if (_exposureMode == ExposureModeConfig.manual) {
        await Future.delayed(Duration(milliseconds: 150));

        if (_minExposureOffset != null && _maxExposureOffset != null) {
          double exposureOffset = _exposureOffset.clamp(
            _minExposureOffset!,
            _maxExposureOffset!,
          );
          try {
            await _controller!.setExposureOffset(exposureOffset);
          } catch (e) {
            // Se falhar, continua sem o offset
          }
        }
      } else if (_exposureMode == ExposureModeConfig.auto) {
        // No modo Auto, garante que o offset está resetado (0.0)
        await Future.delayed(Duration(milliseconds: 150));
        if (_minExposureOffset != null && _maxExposureOffset != null) {
          try {
            await _controller!.setExposureOffset(0.0);
          } catch (e) {}
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
    } catch (e) {}
  }

  void _startNoFaceTimer() {
    _noFaceTimer?.cancel();

    _noFaceTimer = Timer(_noFaceTimeout, () {
      // Se não detectou rosto por X segundos, ajusta exposição para o centro
      _adjustExposureToCenter();
    });
  }

  Future<void> _adjustExposureToCenter() async {
    if (_controller == null) return;

    // Se o modo está Off, não faz nada
    if (_exposureMode == ExposureModeConfig.off) {
      return;
    }

    try {
      // Ponto central da tela (0.5, 0.5)
      final centerPoint = Offset(0.5, 0.5);

      await _controller!.setExposureMode(ExposureMode.auto);
      await _controller!.setFocusMode(FocusMode.auto);
      await _controller!.setExposurePoint(centerPoint);
      await _controller!.setFocusPoint(centerPoint);

      // Aguarda um pouco para a câmera processar o ajuste
      await Future.delayed(Duration(milliseconds: 150));

      // Se modo Manual, aplica offset configurado pelo usuário
      if (_exposureMode == ExposureModeConfig.manual) {
        if (_minExposureOffset != null && _maxExposureOffset != null) {
          double exposureOffset = _exposureOffset.clamp(
            _minExposureOffset!,
            _maxExposureOffset!,
          );
          try {
            await _controller!.setExposureOffset(exposureOffset);
          } catch (e) {}
        }
      } else if (_exposureMode == ExposureModeConfig.auto) {
        // No modo Auto, garante que o offset está resetado (0.0)
        if (_minExposureOffset != null && _maxExposureOffset != null) {
          try {
            await _controller!.setExposureOffset(0.0);
          } catch (e) {}
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
    } catch (e) {}
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    // Determina a rotação baseada na plataforma, orientação e direção da câmera
    bool isLandscape = _currentOrientation == AppOrientation.landscape;
    bool isFrontCamera =
        _cameraDescription!.lensDirection == CameraLensDirection.front;

    InputImageRotation rotation;

    if (Platform.isAndroid) {
      if (isFrontCamera) {
        // Android frontal: Portrait = 270°, Landscape = 90° ou 0° (depende do dispositivo)
        rotation = isLandscape
            ? InputImageRotation.rotation90deg
            : InputImageRotation.rotation270deg;
      } else {
        // Android traseira: Portrait = 90°, Landscape = 0°
        rotation = isLandscape
            ? InputImageRotation.rotation0deg
            : InputImageRotation.rotation90deg;
      }
    } else {
      // iOS: Portrait = 90° (frontal) ou 270° (traseira), Landscape varia
      if (isLandscape) {
        rotation = isFrontCamera
            ? InputImageRotation.rotation270deg
            : InputImageRotation.rotation90deg;
      } else {
        rotation = isFrontCamera
            ? InputImageRotation.rotation90deg
            : InputImageRotation.rotation270deg;
      }
    }

    // print('📷 _inputImageFromCameraImage()');
    // print('   Plataforma: ${Platform.isAndroid ? "Android" : "iOS"}');
    // print('   Orientação: ${isLandscape ? "Landscape" : "Portrait"}');
    // print('   Câmera: ${isFrontCamera ? "Frontal" : "Traseira"}');
    // print('   Rotação escolhida: ${_rotationToString(rotation)}');
    // print('   Tamanho imagem: ${image.width} x ${image.height}');
    // print('');

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
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
    _noFaceTimer?.cancel();
    _exposureFeedbackTimer?.cancel();
    _controller?.dispose();
    _faceDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return Container(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }

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
              Center(child: CameraPreview(_controller!)),
              if (_faceRectRaw != null && _imageSizeRaw != null)
                CustomPaint(
                  painter: FacePainter(
                    faceRectRaw: _faceRectRaw!,
                    imageSizeRaw: _imageSizeRaw!,
                    widgetSize: widgetSize,
                    isFrontCamera:
                        _cameraDescription!.lensDirection ==
                        CameraLensDirection.front,
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
                    icon: Icon(Icons.settings, color: Colors.white, size: 28),
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
  final Rect faceRectRaw;
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

    // ========== LOGS DETALHADOS ==========
    print('═══════════════════════════════════════════════════════');
    print('🎨 FacePainter.paint() - Início do cálculo');
    print(
      '📍 Orientação App: ${orientation == AppOrientation.portrait ? "Portrait" : "Landscape"}',
    );
    print(
      '📍 Orientação Física: ${devicePhysicalOrientation == Orientation.portrait ? "Portrait" : "Landscape"}',
    );
    print('🔄 Rotação ML Kit: ${_rotationToStringPainter(rotation)}');
    print('📷 Câmera: ${isFrontCamera ? "Frontal" : "Traseira"}');
    print('');
    print('📐 Imagem Bruta (imageSizeRaw):');
    print('   width: ${imageSizeRaw.width}, height: ${imageSizeRaw.height}');
    print('');
    print('🎯 Retângulo do Rosto (faceRectRaw do ML Kit):');
    print('   left: ${faceRectRaw.left}, top: ${faceRectRaw.top}');
    print('   width: ${faceRectRaw.width}, height: ${faceRectRaw.height}');
    print('   right: ${faceRectRaw.right}, bottom: ${faceRectRaw.bottom}');
    print('   center: (${faceRectRaw.center.dx}, ${faceRectRaw.center.dy})');
    print('');
    print('📱 Tamanho do Widget (widgetSize):');
    print('   width: ${widgetSize.width}, height: ${widgetSize.height}');
    print('');

    // Em Portrait: usa a lógica original simples (como estava funcionando)
    // Em Landscape: converte coordenadas do ML Kit para espaço bruto primeiro
    Rect displayRect;
    Size displaySize;

    if (orientation == AppOrientation.portrait) {
      // PORTRAIT: Lógica original simples (como estava funcionando antes)
      // O ML Kit retorna coordenadas já no espaço rotacionado
      // Usamos diretamente as coordenadas e dimensões rotacionadas
      displaySize = _getDisplaySize();
      displayRect = faceRectRaw;

      print('📊 Portrait: Usando lógica original');
      print('   displaySize: ${displaySize.width} x ${displaySize.height}');
      print(
        '   displayRect: left=${displayRect.left}, top=${displayRect.top}, width=${displayRect.width}, height=${displayRect.height}',
      );
    } else {
      // LANDSCAPE: Precisamos converter coordenadas do ML Kit para espaço bruto
      // porque o CameraPreview exibe a imagem bruta
      // Detecta se está em Landscape normal ou invertido baseado na rotação do ML Kit
      Size rotatedSize = _getDisplaySize();

      // Em Landscape, a rotação pode ser:
      // - 90° = Landscape normal (tablet virado para a esquerda/direita padrão)
      // - 270° = Landscape invertido (tablet rotacionado 180°)
      bool isLandscapeInverted = rotation == InputImageRotation.rotation270deg;

      displayRect = _convertMLKitToImageSpace(faceRectRaw, rotatedSize);
      displaySize = imageSizeRaw; // Preview mostra imagem bruta

      print('📊 Landscape: Convertendo coordenadas ML Kit → espaço bruto');
      print('   Rotação ML Kit: ${_rotationToStringPainter(rotation)}');
      print(
        '   rotatedSize (ML Kit): ${rotatedSize.width} x ${rotatedSize.height}',
      );
      print(
        '   displaySize (bruto): ${displaySize.width} x ${displaySize.height}',
      );
      print('   Landscape invertido (180°)?: $isLandscapeInverted');
      print(
        '   displayRect convertido: left=${displayRect.left}, top=${displayRect.top}, width=${displayRect.width}, height=${displayRect.height}',
      );

      // A conversão _convertMLKitToImageSpace já trata 90° e 270° corretamente
    }
    print('');

    // Calcula escala do CameraPreview (BoxFit.cover)
    double scaleX = widgetSize.width / displaySize.width;
    double scaleY = widgetSize.height / displaySize.height;
    double scale = math.max(scaleX, scaleY);

    print('📏 Cálculo de Escala:');
    print('   scaleX: $scaleX, scaleY: $scaleY');
    print('   scale usado: $scale (max)');
    print('');

    // Offset do crop
    double scaledWidth = displaySize.width * scale;
    double scaledHeight = displaySize.height * scale;
    double offsetX = (widgetSize.width - scaledWidth) / 2.0;
    double offsetY = (widgetSize.height - scaledHeight) / 2.0;

    print('📐 Tamanho Escalado e Offsets:');
    print('   scaledWidth: $scaledWidth, scaledHeight: $scaledHeight');
    print('   offsetX: $offsetX, offsetY: $offsetY');
    print('');

    // Transforma para coordenadas da tela
    double left = displayRect.left * scale + offsetX;
    double top = displayRect.top * scale + offsetY;
    double width = displayRect.width * scale;
    double height = displayRect.height * scale;

    print('🎯 Coordenadas Antes do Espelhamento:');
    print('   left: $left, top: $top');
    print('   width: $width, height: $height');
    print('   right: ${left + width}, bottom: ${top + height}');
    print('');

    // Espelha horizontalmente para câmera frontal
    // Portrait: sempre espelha (como estava funcionando)
    // Landscape: não espelha (a conversão já trata isso)
    if (isFrontCamera) {
      if (orientation == AppOrientation.portrait) {
        left = widgetSize.width - left - width;
        print('🪞 Espelhamento aplicado (Portrait - câmera frontal)');
      } else {
        print('🪞 Sem espelhamento (Landscape - câmera frontal)');
      }
      print('');
    } else {
      print('🪞 Sem espelhamento (câmera traseira)');
      print('');
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
      print('⚠️ Ajuste por Clamp necessário:');
      print(
        '   ANTES: left=$leftBeforeClamp, top=$topBeforeClamp, width=$widthBeforeClamp, height=$heightBeforeClamp',
      );
      print('   DEPOIS: left=$left, top=$top, width=$width, height=$height');
      print('');
    }

    print('✅ Coordenadas Finais do Retângulo:');
    print('   left: $left, top: $top');
    print('   width: $width, height: $height');
    print('   right: ${left + width}, bottom: ${top + height}');
    print('   center: (${left + width / 2}, ${top + height / 2})');
    print('═══════════════════════════════════════════════════════');
    print('');

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
