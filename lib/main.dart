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
      enableContours: true, // Habilita contornos faciais
      enableLandmarks: true, // Habilita landmarks (pontos faciais)
      enableClassification: false,
      minFaceSize: 0.1, // Reduz o tamanho mínimo do rosto (mais sensível)
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

  Widget _buildCameraLayout(CameraState state, AnalysisPreview preview) {
    // Calcula o previewRect a partir do AnalysisPreview
    // O previewRect é a área onde o preview está desenhado no canvas
    final previewRect = Rect.fromLTWH(
      preview.offset.dx,
      preview.offset.dy,
      preview.previewSize.width,
      preview.previewSize.height,
    );
    
    // Retorna widget decorador que desenha os contornos
    return _FacePreviewDecorator(
      cameraState: state,
      faceDetectionStream: _faceDetectionController.stream,
      preview: preview,
      previewRect: previewRect,
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

      // Emite resultado no stream para desenho dos contornos
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

        // ========== LOGS DAS COORDENADAS DO ML KIT ==========
        log('═══════════════════════════════════════════════════════');
        log('👁️ ML Kit - Rosto detectado');
        log('📐 Tamanho da imagem: ${inputImage.metadata!.size.width.toStringAsFixed(1)}x${inputImage.metadata!.size.height.toStringAsFixed(1)}');
        log('🔄 Rotação: ${_rotationToString(inputImage.metadata!.rotation)}');
        log('📱 Orientação do app: ${_currentOrientation == AppOrientation.portrait ? "Portrait" : "Landscape"}');
        log('🎯 Coordenadas do rosto (ML Kit):');
        log('   left=${face.boundingBox.left.toStringAsFixed(1)}');
        log('   top=${face.boundingBox.top.toStringAsFixed(1)}');
        log('   width=${face.boundingBox.width.toStringAsFixed(1)}');
        log('   height=${face.boundingBox.height.toStringAsFixed(1)}');
        log('   right=${face.boundingBox.right.toStringAsFixed(1)}');
        log('   bottom=${face.boundingBox.bottom.toStringAsFixed(1)}');
        log('   center=(${face.boundingBox.center.dx.toStringAsFixed(1)}, ${face.boundingBox.center.dy.toStringAsFixed(1)})');
        log('═══════════════════════════════════════════════════════');

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
      log("Erro: $e");
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

      log('🎯 Foco aplicado no rosto: (${point.dx.toStringAsFixed(2)}, ${point.dy.toStringAsFixed(2)})');

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

      log('🎯 Foco aplicado no centro: (${centerPoint.dx.toStringAsFixed(2)}, ${centerPoint.dy.toStringAsFixed(2)})');

      await Future.delayed(const Duration(milliseconds: 150));

      // Se modo Manual, aplica brightness configurado pelo usuário
      if (_brightnessMode == BrightnessModeConfig.manual) {
        try {
          final brightnessValue = _brightnessPercentToValue(_brightnessPercent);
          await CamerawesomePlugin.setBrightness(brightnessValue);
        } catch (e) {
          log("Erro ao aplicar brightness: $e");
        }
      } else if (_brightnessMode == BrightnessModeConfig.auto) {
        // No modo Auto, reseta brightness para neutro (0.5 = 0%)
        try {
          await CamerawesomePlugin.setBrightness(0.5);
        } catch (e) {
          log("Erro ao resetar brightness: $e");
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
    final mediaQuery = MediaQuery.of(context);
    final screenSize = mediaQuery.size;
    final orientation = mediaQuery.orientation;
    
    // Calcula aspect ratio da tela
    final screenAspectRatio = screenSize.width / screenSize.height;
    final expectedAspectRatio = 16.0 / 9.0;
    
    // Logs para entender o problema do landscape
    log('═══════════════════════════════════════════════════════');
    log('📱 Build - Orientação App: ${_currentOrientation == AppOrientation.portrait ? "Portrait" : "Landscape"}');
    log('📱 Build - Orientação Física: ${orientation == Orientation.portrait ? "Portrait" : "Landscape"}');
    log('📐 Tela: ${screenSize.width.toStringAsFixed(1)}x${screenSize.height.toStringAsFixed(1)}');
    log('📐 Aspect Ratio da tela: ${screenAspectRatio.toStringAsFixed(3)}');
    log('📐 Aspect Ratio esperado (16:9): ${expectedAspectRatio.toStringAsFixed(3)}');
    log('📐 Diferença: ${(screenAspectRatio - expectedAspectRatio).abs().toStringAsFixed(3)}');
    log('═══════════════════════════════════════════════════════');
    
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

class _FacePreviewDecorator extends StatelessWidget {
  final CameraState cameraState;
  final Stream<FaceDetectionModel> faceDetectionStream;
  final AnalysisPreview preview;
  final Rect previewRect;

  const _FacePreviewDecorator({
    required this.cameraState,
    required this.faceDetectionStream,
    required this.preview,
    required this.previewRect,
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
                    
                    // Obtém a transformação de canvas necessária para converter a imagem para o preview
                    // Android espelha o preview mas a imagem de análise não
                    final canvasTransformation = faceModelSnapshot.data!.img
                        ?.getCanvasTransformation(preview);
                    
                    return CustomPaint(
                      painter: FaceContourPainter(
                        model: faceModelSnapshot.requireData,
                        canvasTransformation: canvasTransformation,
                        preview: preview,
                        previewRect: previewRect,
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
  final Rect previewRect;

  FaceContourPainter({
    required this.model,
    this.canvasTransformation,
    this.preview,
    required this.previewRect,
  });

  // Função auxiliar para converter coordenadas manualmente quando preview não está disponível
  Offset _convertPointManually(Offset imagePoint, Size imageSize, Size croppedSize) {
    // As coordenadas do ML Kit estão no espaço da imagem absoluta
    // Precisamos converter para o espaço do cropped primeiro
    // O cropped é a parte visível da imagem no preview
    
    // Calcula a posição relativa no cropped (0.0 a 1.0)
    double xInCropped = imagePoint.dx / imageSize.width;
    double yInCropped = imagePoint.dy / imageSize.height;
    
    // Converte para coordenadas do cropped
    double xInCroppedSpace = xInCropped * croppedSize.width;
    double yInCroppedSpace = yInCropped * croppedSize.height;
    
    // Aplica escala e offset do previewRect para converter para o canvas
    final scaleX = previewRect.width / croppedSize.width;
    final scaleY = previewRect.height / croppedSize.height;
    
    return Offset(
      xInCroppedSpace * scaleX + previewRect.left,
      yInCroppedSpace * scaleY + previewRect.top,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (model.img == null) {
      return;
    }
    
    // ========== LOGS PARA DEBUG DE ESCALA ==========
    log('═══════════════════════════════════════════════════════');
    log('🎨 FaceContourPainter.paint()');
    log('📐 Canvas size: ${size.width.toStringAsFixed(1)}x${size.height.toStringAsFixed(1)}');
    log('📐 Imagem análise (model.img): ${model.img!.width.toStringAsFixed(1)}x${model.img!.height.toStringAsFixed(1)}');
    log('📐 Imagem absoluta: ${model.absoluteImageSize.width.toStringAsFixed(1)}x${model.absoluteImageSize.height.toStringAsFixed(1)}');
    log('📐 Cropped size: ${model.croppedSize.width.toStringAsFixed(1)}x${model.croppedSize.height.toStringAsFixed(1)}');
    log('🔄 Rotação: ${model.imageRotation}');
    log('🔄 Canvas transformation: ${canvasTransformation != null ? "SIM" : "NÃO"}');
    
    // Aplica a transformação de canvas para que os contornos sejam desenhados
    // na orientação correta (Android apenas)
    if (canvasTransformation != null) {
      canvas.save();
      canvas.applyTransformation(canvasTransformation!, size);
      log('✅ Transformação de canvas aplicada');
    }
    
    // Usa o previewRect fornecido diretamente pelo CamerAwesome
    // O convertFromImage retorna coordenadas no espaço do cropped
    final croppedSize = model.croppedSize;
    
    // Calcula a escala do cropped para o previewRect
    final scaleX = previewRect.width / croppedSize.width;
    final scaleY = previewRect.height / croppedSize.height;
    
    log('📐 Preview rect (fornecido): left=${previewRect.left.toStringAsFixed(1)} top=${previewRect.top.toStringAsFixed(1)} width=${previewRect.width.toStringAsFixed(1)} height=${previewRect.height.toStringAsFixed(1)}');
    log('📐 Cropped size: ${croppedSize.width.toStringAsFixed(1)}x${croppedSize.height.toStringAsFixed(1)}');
    log('📐 Scale: scaleX=${scaleX.toStringAsFixed(3)} scaleY=${scaleY.toStringAsFixed(3)}');
    
    // Processa cada face detectada
    for (final Face face in model.faces) {
      log('👤 Processando face: ${model.faces.length} face(s) detectada(s)');
      
      // Inicializa um map de cada tipo de contorno para um Path
      Map<FaceContourType, Path> paths = {
        for (var fct in FaceContourType.values) fct: Path()
      };
      
      // Itera sobre os contornos da face
      int contourCount = 0;
      face.contours.forEach((contourType, faceContour) {
        if (faceContour != null && faceContour.points.isNotEmpty) {
          contourCount++;
          
          // Log do primeiro ponto de cada contorno para debug (apenas os 3 primeiros)
          if (contourCount <= 3) {
            final firstPoint = faceContour.points.first;
            final originalOffset = Offset(firstPoint.x.toDouble(), firstPoint.y.toDouble());
            
            Offset convertedOffset;
            if (preview != null) {
              // Usa convertFromImage se preview estiver disponível
              convertedOffset = preview!.convertFromImage(originalOffset, model.img!);
            } else {
              // Calcula manualmente se preview não estiver disponível
              convertedOffset = _convertPointManually(originalOffset, model.absoluteImageSize, croppedSize);
            }
            
            log('   Contorno $contourType: ${faceContour.points.length} pontos');
            log('      Original: (${originalOffset.dx.toStringAsFixed(1)}, ${originalOffset.dy.toStringAsFixed(1)})');
            log('      Convertido: (${convertedOffset.dx.toStringAsFixed(1)}, ${convertedOffset.dy.toStringAsFixed(1)})');
          }
          
          // Adiciona os pontos do contorno ao Path como polígono
          final convertedPoints = faceContour.points
              .map(
                (element) {
                  final imagePoint = Offset(element.x.toDouble(), element.y.toDouble());
                  if (preview != null) {
                    // Usa convertFromImage se preview estiver disponível
                    final croppedPoint = preview!.convertFromImage(imagePoint, model.img!);
                    return Offset(
                      croppedPoint.dx * scaleX + previewRect.left,
                      croppedPoint.dy * scaleY + previewRect.top,
                    );
                  } else {
                    // Calcula manualmente se preview não estiver disponível
                    return _convertPointManually(imagePoint, model.absoluteImageSize, croppedSize);
                  }
                },
              )
              .toList();
          
          paths[contourType]!.addPolygon(convertedPoints, true);
          
          // Desenha um círculo azul em cada ponto do contorno
          for (var canvasPosition in convertedPoints) {
            canvas.drawCircle(
              canvasPosition,
              4,
              Paint()..color = Colors.blue,
            );
          }
        }
      });
      
      // Remove contornos vazios
      paths.removeWhere((key, value) => value.getBounds().isEmpty);
      
      // Desenha os contornos encontrados como linhas laranjas
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
    
    // Restaura o canvas se a transformação foi aplicada
    if (canvasTransformation != null) {
      canvas.restore();
    }
    
    log('═══════════════════════════════════════════════════════');
  }

  @override
  bool shouldRepaint(FaceContourPainter oldDelegate) {
    return oldDelegate.model != model;
  }
}
