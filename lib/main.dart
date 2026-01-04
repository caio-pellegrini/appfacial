import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Trava em modo retrato para simplificar a lógica de desenho
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

  // Guardamos os dados CRUS do ML Kit
  Rect? _faceRectRaw;
  Size? _imageSizeRaw;
  InputImageRotation _currentRotation = InputImageRotation.rotation0deg;

  @override
  void initState() {
    super.initState();
    final options = FaceDetectorOptions(
      performanceMode: FaceDetectorMode.fast,
      enableContours: false,
      enableClassification: false,
    );
    _faceDetector = FaceDetector(options: options);
    _initializeCamera();
  }

  void _initializeCamera() async {
    _cameraDescription = widget.cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => widget.cameras.first,
    );

    _controller = CameraController(
      _cameraDescription!,
      ResolutionPreset.veryHigh, // Full HD se disponível
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    try {
      await _controller!.initialize();
      if (mounted) {
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
      if (inputImage == null) return;

      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isNotEmpty) {
        final face = faces.first;
        
        // 1. Foco de Hardware (Usa uma aproximação normalizada)
        await _adjustHardwareFocus(face.boundingBox, image);

        // 2. Atualiza a UI com os dados CRUS para o pintor desenhar
        setState(() {
          _faceRectRaw = face.boundingBox;
          _imageSizeRaw = Size(image.width.toDouble(), image.height.toDouble());
          _currentRotation = inputImage.metadata!.rotation;
        });

      } else {
        if (_faceRectRaw != null) {
          setState(() {
            _faceRectRaw = null;
          });
        }
        // Reseta foco se perder o rosto
        try {
           await _controller?.setExposurePoint(null);
           await _controller?.setFocusPoint(null);
        } catch(e) {}
      }
    } catch (e) {
      print("Erro: $e");
    } finally {
      _isProcessing = false;
    }
  }

  // Foco de Hardware (Mantido simples, pois o hardware lida melhor com imprecisões)
  Future<void> _adjustHardwareFocus(Rect faceRect, CameraImage image) async {
    if (_controller == null) return;
    double imgW = image.width.toDouble();
    double imgH = image.height.toDouble();
    
    // Centro normalizado (0.0 - 1.0)
    double x = faceRect.center.dx / imgW;
    double y = faceRect.center.dy / imgH;

    // Ajuste básico para frontal Android (rotação e espelho)
    if (Platform.isAndroid && _cameraDescription!.lensDirection == CameraLensDirection.front) {
       double tempX = x;
       x = y; // Troca eixos devido a rotação de 90/270
       y = 1 - tempX; // Espelha o novo Y
    }
    Offset point = Offset(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));

    try {
      await _controller!.setExposureMode(ExposureMode.auto);
      await _controller!.setFocusMode(FocusMode.auto);
      await _controller!.setExposurePoint(point);
      await _controller!.setFocusPoint(point);
    } catch (e) {}
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    // No Android, a imagem da câmera frontal geralmente vem rotacionada 270 graus
    // em relação à orientação retrato do celular.
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
    _controller?.dispose();
    _faceDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return Container(color: Colors.black, child: Center(child: CircularProgressIndicator()));
    }

    // O LayoutBuilder nos dá o tamanho exato da tela disponível para desenhar
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final widgetSize = Size(constraints.maxWidth, constraints.maxHeight);

          return Stack(
            fit: StackFit.expand,
            children: [
               // O Preview da câmera (que corta a imagem para preencher a tela)
               Center(
                  child: CameraPreview(_controller!),
               ),

              // O Pintor que desenha por cima
              if (_faceRectRaw != null && _imageSizeRaw != null)
                CustomPaint(
                  painter: FacePainter(
                    faceRectRaw: _faceRectRaw!,
                    imageSizeRaw: _imageSizeRaw!,
                    widgetSize: widgetSize,
                    isFrontCamera: _cameraDescription!.lensDirection == CameraLensDirection.front,
                    rotation: _currentRotation,
                  ),
                  child: Container(),
                ),
            ],
          );
        }
      ),
    );
  }
}

// --- PINTOR CORRIGIDO COM NOVA LÓGICA DE ESCALA ---
class FacePainter extends CustomPainter {
  final Rect faceRectRaw;
  final Size imageSizeRaw;
  final Size widgetSize;
  final bool isFrontCamera;
  final InputImageRotation rotation;

  FacePainter({
    required this.faceRectRaw,
    required this.imageSizeRaw,
    required this.widgetSize,
    required this.isFrontCamera,
    required this.rotation,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paintRect = Paint()
      ..color = Colors.white.withOpacity(0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final Paint paintDot = Paint()
      ..color = Colors.yellow
      ..style = PaintingStyle.fill;

    // --- NOVA LÓGICA DE TRADUÇÃO ---
    
    // 1. Determina as dimensões reais da imagem se ela estivesse "em pé"
    bool isRotated = rotation == InputImageRotation.rotation90deg || rotation == InputImageRotation.rotation270deg;
    double imageWidth = isRotated ? imageSizeRaw.height : imageSizeRaw.width;
    double imageHeight = isRotated ? imageSizeRaw.width : imageSizeRaw.height;

    // 2. Calcula a escala necessária para preencher a tela (BoxFit.cover)
    double scaleX = widgetSize.width / imageWidth;
    double scaleY = widgetSize.height / imageHeight;
    // Usa a maior escala para garantir que preencha tudo (o que causa o corte)
    double scale = math.max(scaleX, scaleY);

    // 3. Calcula o retângulo final na tela
    Rect finalRect;
    
    if (Platform.isAndroid && isFrontCamera && isRotated) {
      // Lógica específica para Android Frontal (que é o caso mais comum de erro)
      // A imagem vem deitada (ex: 1280x720). O rosto está nessas coordenadas.
      // Precisamos inverter Eixos e Espelhar horizontalmente.

      // Troca X por Y e aplica escala
      double left = faceRectRaw.top * scale;
      double top = faceRectRaw.left * scale;
      double width = faceRectRaw.height * scale;
      double height = faceRectRaw.width * scale;

      // Espelhamento Horizontal: subtrai a posição X da largura total da tela
      left = widgetSize.width - left - width;

      // Ajusta o offset vertical se houver corte em cima/embaixo
      double offsetY = (widgetSize.height - (imageHeight * scale)) / 2.0;
      top += offsetY;

      finalRect = Rect.fromLTWH(left, top, width, height);

    } else {
      // Fallback para outros casos (iOS ou câmera traseira) - Lógica simplificada
       double left = faceRectRaw.left * scaleX;
       double top = faceRectRaw.top * scaleY;
       double width = faceRectRaw.width * scaleX;
       double height = faceRectRaw.height * scaleY;
       if (isFrontCamera) {
          left = widgetSize.width - left - width; // Espelha
       }
      finalRect = Rect.fromLTWH(left, top, width, height);
    }
    
    // Desenha o quadrado
    canvas.drawRect(finalRect, paintRect);

    // Desenha a bolinha no centro
    canvas.drawCircle(finalRect.center, 5.0, paintDot);
  }

  @override
  bool shouldRepaint(FacePainter oldDelegate) {
    return oldDelegate.faceRectRaw != faceRectRaw;
  }
}