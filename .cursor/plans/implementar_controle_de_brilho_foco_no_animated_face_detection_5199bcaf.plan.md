---
name: Implementar controle de brilho/foco no animated_face_detection
overview: Implementar controle de brilho/foco, fallback de 5 segundos e feedback visual (bolinhas e contornos) no animated_face_detection, seguindo exatamente o padrão do projeto appfacial.
todos:
  - id: "1"
    content: Criar enum BrightnessModeConfig em brightness_mode_config.dart e exportar no animated_face_detection.dart
    status: pending
  - id: "2"
    content: Adicionar campos brightnessMode, brightnessPercent e showVisualFeedback ao DetectionConfig
    status: pending
    dependencies:
      - "1"
  - id: "3"
    content: Adicionar variáveis de estado para brilho/foco e feedback visual no FaceDetectionPageAndroid
    status: pending
    dependencies:
      - "1"
      - "2"
  - id: "4"
    content: "Implementar métodos auxiliares: _brightnessPercentToValue, _normalizedToScreenPosition, _loadBrightnessConfig"
    status: pending
    dependencies:
      - "3"
  - id: "5"
    content: Implementar _focusOnDetectedFace seguindo exatamente o padrão do appfacial
    status: pending
    dependencies:
      - "4"
  - id: "6"
    content: Implementar _startNoFaceTimer e _focusOnCenterWhenNoFace para fallback de 5 segundos
    status: pending
    dependencies:
      - "5"
  - id: "7"
    content: Implementar _showFocusFeedbackAt e _showBrightnessFeedbackAt para bolinhas de feedback
    status: pending
    dependencies:
      - "4"
  - id: "8"
    content: Modificar _processCameraImage para chamar _focusOnDetectedFace quando rosto detectado e iniciar timer quando não detectado
    status: pending
    dependencies:
      - "5"
      - "6"
  - id: "9"
    content: Atualizar initState para carregar configurações e builder para atualizar _currentPreview
    status: pending
    dependencies:
      - "3"
      - "4"
  - id: "10"
    content: Adicionar overlays de bolinhas (vermelha e verde) no Stack do build()
    status: pending
    dependencies:
      - "7"
      - "9"
  - id: "11"
    content: Atualizar dispose() para cancelar todos os timers
    status: pending
    dependencies:
      - "6"
      - "7"
  - id: "12"
    content: Atualizar DetectionWidget para receber e verificar showVisualFeedback antes de desenhar contornos
    status: pending
    dependencies:
      - "2"
  - id: "13"
    content: Verificar se FaceDetectionModel precisa do campo img para desenhar contornos corretamente
    status: pending
---

# Plano: Implementar Controle de Brilho/Foco no animated_face_detection

## Visão Geral

Este plano implementa o controle de brilho/foco no projeto `animated_face_detection`, seguindo **exatamente** o padrão do projeto `appfacial`. Inclui: modo de brilho (off/auto/manual), aplicação de foco/brilho quando rosto detectado, fallback de 5 segundos sem rosto, e feedback visual (bolinhas e contornos).

## Estrutura da Implementação

```
animated_face_detection/
├── lib/src/core/models/
│   ├── brightness_mode_config.dart (NOVO - enum)
│   └── detection_config.dart (ATUALIZAR - adicionar campos)
├── lib/src/screens/
│   └── face_detection_page_android.dart (ATUALIZAR - lógica completa)
└── lib/src/core/custom_painters/
    └── android_face_detector_painter.dart (ATUALIZAR - respeitar showVisualFeedback)
```

## 1. Criar Enum BrightnessModeConfig

**Arquivo**: `lib/src/core/models/brightness_mode_config.dart` (NOVO)

Criar arquivo novo com o enum exatamente como no `appfacial`:

```dart
enum BrightnessModeConfig { off, auto, manual }
```

**Exportar no**: `lib/animated_face_detection.dart`

- Adicionar: `export './src/core/models/brightness_mode_config.dart';`

## 2. Atualizar DetectionConfig

**Arquivo**: `lib/src/core/models/detection_config.dart`

Adicionar três campos opcionais ao construtor:

```dart
final BrightnessModeConfig? brightnessMode; // default: BrightnessModeConfig.auto
final double? brightnessPercent; // default: 0.0
final bool? showVisualFeedback; // default: false
```

**Código completo a adicionar:**

```dart
class DetectionConfig {
  // ... campos existentes ...
  
  final BrightnessModeConfig? brightnessMode;
  final double? brightnessPercent;
  final bool? showVisualFeedback;

  DetectionConfig({
    required this.steps,
    // ... parâmetros existentes ...
    this.brightnessMode,
    this.brightnessPercent,
    this.showVisualFeedback,
  }) {
    // ... assert existente ...
  }
}
```

**Valores padrão:**

- `brightnessMode`: `null` → usar `BrightnessModeConfig.auto` internamente
- `brightnessPercent`: `null` → usar `0.0` internamente
- `showVisualFeedback`: `null` → usar `false` internamente

## 3. Atualizar FaceDetectionPageAndroid - Variáveis de Estado

**Arquivo**: `lib/src/screens/face_detection_page_android.dart`

**Adicionar no início da classe `_FaceDetectionScreenAndroidState` (após linha ~88):**

```dart
// Variáveis para controle de brilho/foco (do appfacial)
AnalysisPreview? _currentPreview;
Timer? _noFaceTimer;
BrightnessModeConfig _brightnessMode = BrightnessModeConfig.auto;
double _brightnessPercent = 0.0;
bool _showVisualFeedback = false;

// Variáveis para feedback visual (do appfacial)
Offset? _focusPositionNormalized;
bool _showFocusFeedback = false;
Timer? _focusFeedbackTimer;
Completer<void>? _focusFeedbackCompleter;
Offset? _brightnessPositionNormalized;
bool _showBrightnessFeedback = false;
Timer? _brightnessFeedbackTimer;

// Constantes (do appfacial)
static const Duration _noFaceTimeout = Duration(seconds: 5);
static const Duration _brightnessFeedbackDuration = Duration(milliseconds: 300);
```

## 4. Adicionar Métodos Auxiliares (do appfacial)

**Arquivo**: `lib/src/screens/face_detection_page_android.dart`

**Adicionar após o método `_setTakePhoto` (após linha ~403):**

```dart
// Converter percentual de brilho para valor (0.0-1.0)
// Fonte: appfacial/lib/main.dart linha 127-129
double _brightnessPercentToValue(double percent) {
  return ((percent + 100.0) / 200.0).clamp(0.0, 1.0);
}

// Converter coordenadas normalizadas para posição na tela
// Fonte: appfacial/lib/main.dart linha 131-146
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

// Carregar configurações do DetectionConfig
void _loadBrightnessConfig() {
  _brightnessMode = widget.config.brightnessMode ?? BrightnessModeConfig.auto;
  _brightnessPercent = (widget.config.brightnessPercent ?? 0.0).clamp(-100.0, 100.0);
  _showVisualFeedback = widget.config.showVisualFeedback ?? false;
}
```

## 5. Implementar Método de Foco no Rosto Detectado

**Arquivo**: `lib/src/screens/face_detection_page_android.dart`

**Adicionar método completo (fonte: appfacial/lib/main.dart linha 308-372):**

```dart
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

    debugPrint('🎯 Foco: (${focusPosition.dx.toStringAsFixed(2)}, ${focusPosition.dy.toStringAsFixed(2)})');

    await _showFocusFeedbackAt(normalizedPositionForFeedback);

    if (_brightnessMode == BrightnessModeConfig.manual) {
      await Future.delayed(const Duration(milliseconds: 150));
      try {
        final brightnessValue = _brightnessPercentToValue(_brightnessPercent);
        await CamerawesomePlugin.setBrightness(brightnessValue);
        // Mostrar bolinha verde na mesma posição
        await _showBrightnessFeedbackAt(normalizedPositionForFeedback);
      } catch (e) {
        debugPrint("Erro ao aplicar brightness: $e");
      }
    }
  } catch (e) {
    debugPrint("Erro ao ajustar foco: $e");
  }
}
```

**Import necessário:**

```dart
import 'dart:io';
import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:camerawesome/pigeon.dart';
```

## 6. Implementar Fallback de 5 Segundos

**Arquivo**: `lib/src/screens/face_detection_page_android.dart`

**Adicionar métodos (fonte: appfacial/lib/main.dart linha 374-434):**

```dart
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

    debugPrint('🎯 Foco centro: (${focusPosition.dx.toStringAsFixed(2)}, ${focusPosition.dy.toStringAsFixed(2)})');

    await _showFocusFeedbackAt(normalizedCenter);

    await Future.delayed(const Duration(milliseconds: 150));

    if (_brightnessMode == BrightnessModeConfig.manual) {
      try {
        final brightnessValue = _brightnessPercentToValue(_brightnessPercent);
        await CamerawesomePlugin.setBrightness(brightnessValue);
        // Mostrar bolinha verde no centro
        await _showBrightnessFeedbackAt(normalizedCenter);
      } catch (e) {
        debugPrint("Erro ao aplicar brightness: $e");
      }
    }
  } catch (e) {
    debugPrint("Erro ao ajustar brilho para centro: $e");
  }
}
```

## 7. Implementar Feedback Visual (Bolinhas)

**Arquivo**: `lib/src/screens/face_detection_page_android.dart`

**Adicionar métodos (fonte: appfacial/lib/main.dart linha 264-306):**

```dart
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
```

**Import necessário:**

```dart
import 'dart:async';
```

## 8. Modificar _processCameraImage

**Arquivo**: `lib/src/screens/face_detection_page_android.dart`

**Modificar método `_processCameraImage` (após linha ~445, dentro do try):**

Adicionar após `_faceDetectionController.add(...)`:

```dart
// Aplicar foco/brilho quando rosto detectado (do appfacial)
if (detectedFaces.isNotEmpty) {
  final face = detectedFaces.first;
  
  // Atualizar _currentPreview se necessário
  // Nota: _currentPreview será atualizado no builder do CameraAwesomeBuilder
  
  _noFaceTimer?.cancel();
  _noFaceTimer = null;
  
  // Aplicar foco/brilho no rosto detectado
  // Nota: precisamos do AnalysisImage original (img) para converter coordenadas
  // O AnalysisImage está disponível no parâmetro do método
  if (_brightnessMode != BrightnessModeConfig.off) {
    final faceRect = face.boundingBox;
    _focusOnDetectedFace(faceRect, inputImage.metadata!.size, img);
  }
} else {
  // Iniciar timer de fallback se não há rosto (do appfacial)
  if (_brightnessMode != BrightnessModeConfig.off) {
    if (_noFaceTimer == null || !_noFaceTimer!.isActive) {
      _startNoFaceTimer();
    }
  }
}
```

**IMPORTANTE**: Manter toda a lógica existente de `_processImage` intacta. A nova lógica deve ser adicionada **após** o `_faceDetectionController.add()` e **antes** do `await _processImage()`.

## 9. Atualizar initState

**Arquivo**: `lib/src/screens/face_detection_page_android.dart`

**Adicionar no `initState` (após linha ~104):**

```dart
_loadBrightnessConfig();
```

## 10. Atualizar builder do CameraAwesomeBuilder

**Arquivo**: `lib/src/screens/face_detection_page_android.dart`

**Modificar o builder (linha ~159):**

Adicionar atualização do `_currentPreview`:

```dart
builder: (state, preview) {
  _cameraState = state;
  
  // Atualizar _currentPreview (do appfacial)
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && _currentPreview != preview) {
      setState(() {
        _currentPreview = preview;
      });
    }
  });
  
  return DetectionWidget(
    isAnimatedCircleIndicator: widget.config.isAnimatedCircleIndicator,
    cameraState: state,
    faceDetectionStream: _faceDetectionController.stream,
    previewSize: PreviewSize(
      width: preview.previewSize.width,
      height: preview.previewSize.height,
    ),
    previewRect: preview.rect,
    showVisualFeedback: _showVisualFeedback, // NOVO: passar flag
  );
},
```

## 11. Adicionar Overlays de Bolinhas no build()

**Arquivo**: `lib/src/screens/face_detection_page_android.dart`

**Adicionar no Stack do `build()` (após o `DetectionWidget`, antes do `FaceDetectionStepOverlay`):**

```dart
// Overlays de feedback visual (bolinhas) - do appfacial
if (_showVisualFeedback && _showFocusFeedback && _focusPositionNormalized != null)
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
if (_showVisualFeedback && _showBrightnessFeedback && _brightnessPositionNormalized != null)
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
            color: Colors.green,
            shape: BoxShape.circle,
          ),
        ),
      );
    },
  ),
```

**Fonte**: appfacial/lib/main.dart linha 474-511

## 12. Atualizar dispose()

**Arquivo**: `lib/src/screens/face_detection_page_android.dart`

**Adicionar no `dispose()` (após linha ~130):**

```dart
_noFaceTimer?.cancel();
_focusFeedbackTimer?.cancel();
_brightnessFeedbackTimer?.cancel();
```

## 13. Atualizar DetectionWidget

**Arquivo**: `lib/src/screens/components/detection_widget.dart`

**Adicionar parâmetro:**

```dart
final bool? showVisualFeedback;

const DetectionWidget({
  // ... parâmetros existentes ...
  this.showVisualFeedback,
});
```

**Passar para o painter (se necessário):**

O `AndroidFaceDetectorPainter` já recebe o `model` que contém as faces. A verificação de `showVisualFeedback` será feita no painter.

## 14. Atualizar AndroidFaceDetectorPainter

**Arquivo**: `lib/src/core/custom_painters/android_face_detector_painter.dart`

**Adicionar verificação de showVisualFeedback:**

O painter já desenha contornos. Precisamos garantir que ele só desenhe quando `showVisualFeedback` for true. Como o `DetectionWidget` não passa essa flag diretamente, podemos:

**Opção A**: Passar via `DetectionConfig` através do `AnimatedFaceDetection.instance` (se já existe configuração global)

**Opção B**: Adicionar flag ao `FaceDetectionModel` (não recomendado, quebra compatibilidade)

**Opção C**: Verificar através de uma variável global ou singleton

**Recomendação**: Usar `AnimatedFaceDetection.instance` para armazenar temporariamente a flag, ou adicionar ao `DetectionWidget` e passar para o painter.

**Implementação recomendada:**

No `DetectionWidget`, verificar antes de renderizar o `CustomPaint`:

```dart
@override
Widget build(BuildContext context) {
  return IgnorePointer(
    child: StreamBuilder(
      stream: cameraState.sensorConfig$,
      builder: (_, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox();
        } else {
          return StreamBuilder<FaceDetectionModel>(
            stream: faceDetectionStream,
            builder: (_, faceModelSnapshot) {
              // Verificar showVisualFeedback antes de desenhar
              if (showVisualFeedback == false) {
                return const SizedBox();
              }
              
              if (!faceModelSnapshot.hasData) return const SizedBox();
              return CustomPaint(
                // ... resto do código ...
              );
            },
          );
        }
      },
    ),
  );
}
```

## 15. Atualizar FaceDetectionModel (se necessário)

**Arquivo**: `lib/src/core/models/face_detection_model.dart`

**Verificar se precisa adicionar `AnalysisImage? img`:**

O `appfacial` usa `AnalysisImage? img` no `FaceDetectionModel` para desenhar contornos. Verificar se o `animated_face_detection` precisa do mesmo.

**Se necessário, adicionar:**

```dart
final AnalysisImage? img;

FaceDetectionModel({
  // ... campos existentes ...
  this.img,
});
```

E atualizar onde o modelo é criado em `_processCameraImage`:

```dart
_faceDetectionController.add(
  FaceDetectionModel(
    faces: detectedFaces,
    absoluteImageSize: inputImage.metadata!.size,
    rotation: 0,
    imageRotation: img.inputImageRotation,
    croppedSize: img.croppedSize,
    img: img, // NOVO
  ),
);
```

## Resumo de Arquivos a Modificar

1. **NOVO**: `lib/src/core/models/brightness_mode_config.dart`
2. **ATUALIZAR**: `lib/src/core/models/detection_config.dart`
3. **ATUALIZAR**: `lib/src/screens/face_detection_page_android.dart` (mudanças extensas)
4. **ATUALIZAR**: `lib/src/screens/components/detection_widget.dart`
5. **ATUALIZAR**: `lib/src/core/custom_painters/android_face_detector_painter.dart` (se necessário)
6. **ATUALIZAR**: `lib/src/core/models/face_detection_model.dart` (se necessário para contornos)
7. **ATUALIZAR**: `lib/animated_face_detection.dart` (exportar novo enum)

## Notas Importantes

- **Manter compatibilidade**: Todas as mudanças devem ser aditivas. Valores padrão garantem comportamento atual.
- **Seguir padrão do appfacial**: Usar exatamente os mesmos métodos, constantes e lógica.
- **Não quebrar funcionalidades existentes**: A lógica de detecção de passos (blink, smile, etc.) deve continuar funcionando.
- **Testar em Android e iOS**: A lógica de coordenadas é diferente entre plataformas.
- **Timer de fallback**: Deve cancelar quando rosto é detectado.
- **Feedback visual**: Bolinhas aparecem apenas quando `showVisualFeedback` é true.

## Validações

1. Modo `off`: Não aplica foco nem brilho
2. Modo `auto`: Aplica apenas foco quando rosto detectado
3. Modo `manual`: Aplica foco + brilho quando rosto detectado
4. Fallback: Após 5 segundos sem rosto, aplica foco (e brilho se manual) no centro
5. Feedback visual: Bolinhas vermelhas (foco) e verdes (brilho) aparecem quando configurado
6. Contornos: Aparecem apenas quando `showVisualFeedback` é true