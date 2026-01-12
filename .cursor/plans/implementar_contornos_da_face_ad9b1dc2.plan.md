---
name: Implementar contornos da face
overview: Implementar o desenho dos contornos da face seguindo a documentação oficial do CamerAwesome, adicionando StreamController para emitir resultados de detecção, CustomPainter para desenhar contornos e pontos, e integrando com o código existente mantendo a funcionalidade de foco e brightness.
todos:
  - id: update_face_detector
    content: "Atualizar FaceDetectorOptions para habilitar enableContours: true e enableLandmarks: true"
    status: completed
  - id: create_face_model
    content: Criar classe FaceDetectionModel para armazenar dados de detecção (faces, absoluteImageSize, imageRotation, img)
    status: completed
  - id: add_stream_controller
    content: Adicionar StreamController<FaceDetectionModel> e inicializar/fechar no initState/dispose
    status: completed
    dependencies:
      - create_face_model
  - id: modify_process_image
    content: Modificar _processCameraImage para emitir FaceDetectionModel no stream após detecção
    status: completed
    dependencies:
      - create_face_model
      - add_stream_controller
  - id: update_builder
    content: Modificar builder do CameraAwesomeBuilder para receber AnalysisPreview e armazenar em _preview
    status: completed
  - id: create_decorator_widget
    content: Criar widget _FacePreviewDecorator com StreamBuilder para ouvir faceDetectionController e sensorConfig$
    status: completed
    dependencies:
      - add_stream_controller
      - update_builder
  - id: create_custom_painter
    content: Criar FaceContourPainter (CustomPainter) para desenhar contornos (linhas laranjas) e pontos (círculos azuis)
    status: completed
    dependencies:
      - create_face_model
  - id: integrate_painter
    content: Integrar FaceContourPainter no _FacePreviewDecorator usando CustomPaint widget
    status: completed
    dependencies:
      - create_decorator_widget
      - create_custom_painter
---

# Implementação de Contornos da Face

## Objetivo

Adicionar desenho dos contornos faciais seguindo a documentação oficial do CamerAwesome, mantendo toda a funcionalidade existente (foco automático, brightness, fallback, logs).

## Arquivos a Modificar

### 1. `lib/main.dart`

#### 1.1 Atualizar FaceDetectorOptions

- Alterar `enableContours: false` para `enableContours: true` na linha 119
- Adicionar `enableLandmarks: true` (opcional, mas útil para contornos)

#### 1.2 Criar modelo FaceDetectionModel

- Criar classe `FaceDetectionModel` para armazenar:
  - `List<Face> faces`
  - `Size absoluteImageSize`
  - `InputImageRotation imageRotation`
  - `AnalysisImage? img` (para usar `getCanvasTransformation`)

#### 1.3 Adicionar StreamController

- Adicionar `StreamController<FaceDetectionModel> _faceDetectionController` como variável de estado
- Inicializar no `initState()`
- Fechar no `dispose()`

#### 1.4 Modificar `_processCameraImage`

- Em vez de apenas processar e ajustar foco, também emitir resultado no stream:
  ```dart
  _faceDetectionController.add(
    FaceDetectionModel(
      faces: faces,
      absoluteImageSize: inputImage.metadata!.size,
      imageRotation: inputImage.metadata!.rotation,
      img: img,
    ),
  );
  ```


#### 1.5 Modificar builder do CameraAwesomeBuilder

- Alterar assinatura do builder de `(cameraModeState, preview)` para receber `preview` como `AnalysisPreview`
- Armazenar `preview` em variável de estado `_preview`
- Retornar widget `_FacePreviewDecorator` em vez de `SizedBox.shrink()`

#### 1.6 Criar widget `_FacePreviewDecorator`

- Widget que usa `StreamBuilder` para ouvir `_faceDetectionController.stream`
- Usa `StreamBuilder` aninhado para `cameraState.sensorConfig$` (para detectar câmera frontal/traseira)
- Retorna `CustomPaint` com `FaceContourPainter`

#### 1.7 Criar CustomPainter `FaceContourPainter`

- Recebe `FaceDetectionModel`, `CanvasTransformation?`, e `AnalysisPreview?`
- No método `paint()`:
  - Aplicar `canvasTransformation` se existir (Android)
  - Para cada face:
    - Criar map de `FaceContourType` para `Path`
    - Iterar sobre `face.contours`
    - Converter pontos usando `preview.convertFromImage()`
    - Desenhar círculos azuis nos pontos (raio 4)
    - Adicionar pontos ao Path como polígono
  - Desenhar paths como linhas laranjas (strokeWidth 2)
  - Restaurar canvas se transformação foi aplicada

#### 1.8 Manter funcionalidade existente

- Manter bolinha vermelha no fallback (quando `_brightnessJustApplied` e sem rosto)
- Manter todos os logs atuais
- Manter lógica de foco e brightness

## Fluxo de Dados

```
AnalysisImage → _processCameraImage() 
  → FaceDetector.processImage() 
  → FaceDetectionModel 
  → StreamController.add() 
  → StreamBuilder 
  → FaceContourPainter 
  → Canvas.drawPath() + Canvas.drawCircle()
```

## Dependências

- Não precisa adicionar novas dependências (StreamController é do Dart core)
- Verificar se `AnalysisPreview` e métodos `convertFromImage()` e `getCanvasTransformation()` estão disponíveis na versão atual do camerawesome

## Considerações

- A transformação de canvas é necessária apenas no Android para lidar com espelhamento da câmera frontal
- Os contornos serão desenhados apenas quando houver rosto detectado
- A bolinha vermelha do fallback continuará aparecendo quando não houver rosto por 5 segundos
- Manter compatibilidade com portrait e landscape