---
name: Trocar previewOnly para custom e usar previewRect
overview: Trocar CameraAwesomeBuilder.previewOnly para CameraAwesomeBuilder.custom com as propriedades especificadas, modificar o builder para receber previewSize e previewRect, e usar previewRect diretamente no FaceContourPainter em vez de calcular manualmente.
todos:
  - id: change_to_custom
    content: Trocar CameraAwesomeBuilder.previewOnly para CameraAwesomeBuilder.custom com previewFit, aspectRatio 4:3, flashMode e zoom
    status: completed
  - id: update_builder_signature
    content: Modificar assinatura do builder para receber (state, previewSize, previewRect) em vez de (cameraModeState, preview)
    status: completed
    dependencies:
      - change_to_custom
  - id: add_preview_rect_to_decorator
    content: Adicionar parâmetro previewRect ao _FacePreviewDecorator e passá-lo para FaceContourPainter
    status: completed
    dependencies:
      - update_builder_signature
  - id: update_painter_constructor
    content: Adicionar parâmetro previewRect ao FaceContourPainter e remover cálculo manual do previewRect
    status: completed
    dependencies:
      - add_preview_rect_to_decorator
  - id: simplify_coordinate_conversion
    content: Simplificar conversão de coordenadas para usar previewRect fornecido diretamente
    status: completed
    dependencies:
      - update_painter_constructor
---

# Trocar previewOnly para CameraAwesomeBuilder.custom e usar previewRect

## Objetivo

Trocar `CameraAwesomeBuilder.previewOnly` para `CameraAwesomeBuilder.custom` com as propriedades especificadas e usar `previewRect` diretamente fornecido pelo builder em vez de calcular manualmente.

## Arquivos a Modificar

### 1. `lib/main.dart`

#### 1.1 Trocar previewOnly para custom

- Substituir `CameraAwesomeBuilder.previewOnly` por `CameraAwesomeBuilder.custom`
- Adicionar `previewFit: CameraPreviewFit.contain`
- Alterar `aspectRatio` de `CameraAspectRatios.ratio_16_9` para `CameraAspectRatios.ratio_4_3`
- Adicionar `flashMode: FlashMode.auto` no `sensorConfig`
- Adicionar `zoom` no `sensorConfig` (verificar se existe no estado ou usar valor padrão)

#### 1.2 Modificar assinatura do builder

- Alterar de `builder: (cameraModeState, preview)` para `builder: (state, previewSize, previewRect)`
- O builder agora recebe 3 parâmetros em vez de 2
- `previewSize`: Size do preview
- `previewRect`: Rect do preview no canvas (já calculado pelo CamerAwesome)

#### 1.3 Atualizar _FacePreviewDecorator

- Adicionar parâmetro `previewRect: Rect` no construtor
- Passar `previewRect` do builder para o decorator
- Passar `previewRect` para o `FaceContourPainter`

#### 1.4 Modificar FaceContourPainter

- Adicionar parâmetro `previewRect: Rect` no construtor
- Remover cálculo manual do `previewRect` (linhas 640-659)
- Usar `previewRect` diretamente fornecido
- Ajustar cálculo de escala:
  - `scaleX = previewRect.width / croppedSize.width`
  - `scaleY = previewRect.height / croppedSize.height`
  - Usar o scale apropriado (provavelmente scaleX ou scaleY dependendo do aspect ratio)

#### 1.5 Ajustar conversão de coordenadas

- Manter uso de `preview.convertFromImage()` para converter do espaço da imagem para o espaço do cropped
- Aplicar escala e offset usando `previewRect` fornecido:
  ```dart
  final canvasOffset = Offset(
    convertedOffset.dx * (previewRect.width / croppedSize.width) + previewRect.left,
    convertedOffset.dy * (previewRect.height / croppedSize.height) + previewRect.top,
  );
  ```


#### 1.6 Verificar zoom

- Se não houver variável de estado para zoom, usar valor padrão (ex: 1.0) ou adicionar ao estado se necessário

## Mudanças Específicas

### CameraAwesomeBuilder.custom

```dart
CameraAwesomeBuilder.custom(
  previewFit: CameraPreviewFit.contain,
  sensorConfig: SensorConfig.single(
    aspectRatio: CameraAspectRatios.ratio_4_3,
    flashMode: FlashMode.auto,
    sensor: Sensor.position(SensorPosition.front),
    zoom: 1.0, // ou valor do estado se existir
  ),
  onImageForAnalysis: (img) => _processCameraImage(img),
  imageAnalysisConfig: AnalysisConfig(...),
  builder: (state, previewSize, previewRect) {
    return _FacePreviewDecorator(
      cameraState: state,
      faceDetectionStream: _faceDetectionController.stream,
      preview: preview, // ainda necessário para convertFromImage
      previewRect: previewRect, // novo parâmetro
    );
  },
)
```

### FaceContourPainter

- Remover cálculo manual do previewRect
- Usar `previewRect` fornecido diretamente
- Simplificar cálculo de escala usando `previewRect.width/height` e `croppedSize.width/height`

## Benefícios

- Elimina cálculo manual do previewRect (mais preciso)
- Usa valores fornecidos diretamente pelo CamerAwesome
- Código mais simples e confiável
- Suporta diferentes aspect ratios (4:3 em vez de 16:9)