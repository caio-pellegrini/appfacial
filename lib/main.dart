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
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  
  final cameras = await availableCameras();
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    home: FaceAwareCamera(cameras: cameras),
  ));
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
  
  ExposureModeConfig _exposureMode = ExposureModeConfig.manual;
  double _exposureOffset = 1.0;
  
  static const Duration _noFaceTimeout = Duration(seconds: 5);
  static const Duration _exposureFeedbackDuration = Duration(milliseconds: 300);

  @override
  void initState() {
    super.initState();
    // Opções mais sensíveis para detectar rostos mesmo em condições adversas
    final options = FaceDetectorOptions(
      performanceMode: FaceDetectorMode.accurate, // Mais preciso, detecta melhor contra luz
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
    final modeIndex = prefs.getInt('exposureMode') ?? ExposureModeConfig.manual.index;
    final offset = prefs.getDouble('exposureOffset') ?? 1.0;
    
    setState(() {
      _exposureMode = ExposureModeConfig.values[modeIndex];
      _exposureOffset = offset;
    });
  }

  Future<void> _openSettings() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsScreen(
          currentMode: _exposureMode,
          currentOffset: _exposureOffset,
        ),
      ),
    );

    if (result != null) {
      final newMode = result['mode'] as ExposureModeConfig;
      final newOffset = result['offset'] as double;
      
      // Se mudou de Manual para Auto/Off, reseta o offset
      if (_exposureMode == ExposureModeConfig.manual && 
          newMode != ExposureModeConfig.manual) {
        await _resetExposureOffset();
      }
      
      setState(() {
        _exposureMode = newMode;
        _exposureOffset = newOffset;
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

  void _initializeCamera() async {
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
          } catch(e) {}
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
    
    // Ajuste para rotação 270deg (Android frontal)
    if (Platform.isAndroid && _cameraDescription!.lensDirection == CameraLensDirection.front) {
      double tempX = x;
      x = y;
      y = 1.0 - tempX;
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
          double exposureOffset = _exposureOffset.clamp(_minExposureOffset!, _maxExposureOffset!);
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
          double exposureOffset = _exposureOffset.clamp(_minExposureOffset!, _maxExposureOffset!);
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
    // Para Android frontal em portrait, a imagem vem rotacionada 270°
    // Quando o dispositivo está horizontal, a rotação pode ser diferente,
    // mas como o app está travado em portrait, mantemos a rotação fixa
    final rotation = Platform.isAndroid ? InputImageRotation.rotation270deg : InputImageRotation.rotation0deg;
    
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if(format == null) return null;

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
      return Container(color: Colors.black, child: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final widgetSize = Size(constraints.maxWidth, constraints.maxHeight);

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
                    isFrontCamera: _cameraDescription!.lensDirection == CameraLensDirection.front,
                    rotation: _currentRotation,
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
        }
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
  final bool exposureJustApplied;

  FacePainter({
    required this.faceRectRaw,
    required this.imageSizeRaw,
    required this.widgetSize,
    required this.isFrontCamera,
    required this.rotation,
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

    // ASSUMINDO: O ML Kit retorna coordenadas JÁ no espaço rotacionado (após aplicar rotation)
    // quando você passa rotation no InputImageMetadata
    // Então NÃO precisamos aplicar rotação manualmente aqui
    
    Size displaySize = _getDisplaySize();
    // Usa as coordenadas diretamente, sem conversão
    Rect displayRect = faceRectRaw;
    
    // Calcula escala do CameraPreview (BoxFit.cover)
    double scaleX = widgetSize.width / displaySize.width;
    double scaleY = widgetSize.height / displaySize.height;
    double scale = math.max(scaleX, scaleY);
    
    // Offset do crop
    double scaledWidth = displaySize.width * scale;
    double scaledHeight = displaySize.height * scale;
    double offsetX = (widgetSize.width - scaledWidth) / 2.0;
    double offsetY = (widgetSize.height - scaledHeight) / 2.0;

    // Transforma para coordenadas da tela
    double left = displayRect.left * scale + offsetX;
    double top = displayRect.top * scale + offsetY;
    double width = displayRect.width * scale;
    double height = displayRect.height * scale;

    // Espelha horizontalmente para câmera frontal
    if (isFrontCamera) {
      left = widgetSize.width - left - width;
    }

    // Garante que o retângulo está dentro dos limites da tela
    left = left.clamp(0.0, widgetSize.width);
    top = top.clamp(0.0, widgetSize.height);
    width = width.clamp(0.0, widgetSize.width - left);
    height = height.clamp(0.0, widgetSize.height - top);

    // Só desenha se o retângulo tem tamanho válido
    if (width > 0 && height > 0) {
      Rect finalRect = Rect.fromLTWH(left, top, width, height);
      canvas.drawRect(finalRect, paintRect);
      canvas.drawCircle(finalRect.center, dotRadius, paintDot);
    }
  }

  Size _getDisplaySize() {
    // Após rotação de 90° ou 270°, as dimensões são trocadas
    if (rotation == InputImageRotation.rotation90deg || 
        rotation == InputImageRotation.rotation270deg) {
      return Size(imageSizeRaw.height, imageSizeRaw.width);
    }
    return imageSizeRaw;
  }


  @override
  bool shouldRepaint(FacePainter oldDelegate) {
    return oldDelegate.faceRectRaw != faceRectRaw ||
           oldDelegate.widgetSize != widgetSize ||
           oldDelegate.exposureJustApplied != exposureJustApplied;
  }
}
