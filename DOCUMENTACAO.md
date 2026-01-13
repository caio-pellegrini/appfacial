# 📚 Documentação do Projeto AppFacial

## 🎯 Visão Geral

Este é um aplicativo Flutter que utiliza **reconhecimento facial em tempo real** para ajustar automaticamente o foco e o brilho da câmera quando detecta um rosto. O app funciona como uma câmera inteligente que "segue" o rosto do usuário, desenhando contornos faciais e pontos de referência em tempo real.

---

## 🔍 Como Funciona o Reconhecimento Facial

### 1. **Tecnologia Utilizada: Google ML Kit Face Detection**

O projeto usa o pacote `google_mlkit_face_detection` que é uma biblioteca oficial do Google para detecção facial em dispositivos móveis. Esta biblioteca:

- **Funciona offline** (não precisa de internet)
- **Processa em tempo real** (baixa latência)
- **Usa machine learning** (modelos pré-treinados)
- **Otimizado para mobile** (usa GPU quando disponível)

### 2. **Configuração do Detector**

No arquivo `main.dart`, linhas 146-152, o detector é configurado assim:

```dart
final options = FaceDetectorOptions(
  performanceMode: FaceDetectorMode.accurate,
  enableContours: true,      // Habilita contornos faciais
  enableLandmarks: true,      // Habilita landmarks (pontos faciais)
  enableClassification: false,
  minFaceSize: 0.1,          // Tamanho mínimo do rosto (10% da imagem)
);
```

**O que cada parâmetro significa:**
- `performanceMode.accurate`: Prioriza precisão sobre velocidade (melhor para condições adversas de luz)
- `enableContours: true`: Detecta contornos faciais detalhados (olhos, nariz, boca, etc.)
- `enableLandmarks: true`: Detecta pontos específicos do rosto
- `minFaceSize: 0.1`: Detecta rostos que ocupam pelo menos 10% da imagem (torna mais sensível)

---

## 📷 Como o Rosto é Reconhecido

### Fluxo Completo de Detecção:

#### **Passo 1: Inicialização da Câmera** (linhas 446-468)

O app usa o pacote **CamerAwesome** (`camerawesome: ^2.1.0`) que oferece uma API moderna e simplificada:

```dart
CameraAwesomeBuilder.custom(
  saveConfig: SaveConfig.photo(),
  previewFit: CameraPreviewFit.contain,
  sensorConfig: SensorConfig.single(
    aspectRatio: CameraAspectRatios.ratio_4_3,
    flashMode: FlashMode.auto,
    sensor: Sensor.position(SensorPosition.front),
  ),
  onImageForAnalysis: (img) => _processCameraImage(img),
  imageAnalysisConfig: AnalysisConfig(
    androidOptions: const AndroidAnalysisOptions.nv21(width: 1024),
    maxFramesPerSecond: 5,
    autoStart: true,
  ),
  builder: (CameraState state, AnalysisPreview preview) {
    return _buildCameraLayout(state, preview);
  },
)
```

**Características principais:**
- Usa câmera frontal (`SensorPosition.front`)
- Processa até 5 frames por segundo para análise
- Formato NV21 no Android (otimizado para performance)
- `previewFit: contain` mantém o aspect ratio e centraliza a imagem

#### **Passo 2: Processamento de Cada Frame** (função `_processCameraImage`, linhas 228-268)

Para cada frame capturado pela câmera:

1. **Conversão para InputImage** (linha 233)
   ```dart
   final inputImage = img.toInputImage();
   ```
   - Usa uma extensão `MLKitUtils` (linhas 12-55) que converte `AnalysisImage` (formato do CamerAwesome) para `InputImage` (formato do ML Kit)
   - A rotação é automaticamente convertida usando `InputImageRotation.values.byName(rotation.name)`

2. **Detecção Facial** (linha 234)
   ```dart
   final faces = await _faceDetector.processImage(inputImage);
   ```
   - O ML Kit analisa a imagem usando modelos de machine learning
   - Retorna uma lista de `Face` objetos (pode detectar múltiplos rostos)
   - Cada `Face` contém:
     - `boundingBox`: Retângulo com coordenadas do rosto
     - `contours`: Map com contornos faciais (olhos, nariz, boca, etc.)
     - `landmarks`: Pontos específicos do rosto

3. **Emissão no Stream** (linhas 236-243)
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
   - Cria um modelo `FaceDetectionModel` com os dados da detecção
   - Emite no stream para que o `FaceContourPainter` possa desenhar os contornos

4. **Processamento do Resultado**
   - Se **rosto detectado**: ajusta foco/brilho e cancela timer de fallback
   - Se **nenhum rosto**: inicia timer de fallback (após 5 segundos, ajusta para o centro)

#### **Passo 3: Desenho dos Contornos** (classe `FaceContourPainter`, linhas 552-631)

Esta classe é responsável por desenhar os contornos faciais e pontos na tela:

1. **Transformação de Canvas** (linhas 569-572)
   ```dart
   if (canvasTransformation != null) {
     canvas.save();
     canvas.applyTransformation(canvasTransformation!, size);
   }
   ```
   - Aplica transformação de canvas para Android (espelha o preview da câmera frontal)

2. **Conversão de Coordenadas** (linhas 590-601)
   ```dart
   final pointInPreview = preview!.convertFromImage(originalPoint, model.img!);
   return Offset(
     pointInPreview.dx * scaleToCanvasX + preview!.offset.dx,
     pointInPreview.dy * scaleToCanvasY + preview!.offset.dy,
   );
   ```
   - Converte coordenadas do espaço da imagem ML Kit para o espaço do canvas
   - Usa `convertFromImage` do `AnalysisPreview` para mapear corretamente
   - Aplica escala e offset para ajustar ao tamanho real do preview na tela

3. **Desenho dos Contornos** (linhas 603-621)
   - Desenha pontos azuis em cada coordenada do contorno
   - Desenha linhas laranjas conectando os pontos de cada contorno

---

## ✅ O Que Acontece DEPOIS que Reconhece o Rosto

### 1. **Ajuste Automático de Foco e Brilho** (função `_adjustHardwareFocus`, linhas 270-354)

Esta é a funcionalidade principal do app! Quando detecta um rosto:

#### **a) Calcula o Ponto de Foco** (linhas 273-296)

```dart
var x = faceRect.center.dx / imageSize.width;
var y = faceRect.center.dy / imageSize.height;

// Ajuste para rotação/orientação
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
}
```

- Pega o centro do retângulo do rosto
- Converte para coordenadas normalizadas (0.0 a 1.0)
- Ajusta para rotação/orientação (código específico para Android/iOS e Portrait/Landscape)

#### **b) Aplica Foco** (linhas 315-319)

```dart
await CamerawesomePlugin.focusOnPoint(
  previewSize: previewSize,
  position: point,
  androidFocusSettings: null,
);
```

- Usa a API do CamerAwesome para focar no ponto do rosto

#### **c) Ajusta Brilho** (linhas 323-338)

**Modos de Brilho:**
- **Off**: Não ajusta nada
- **Auto**: Ajusta automaticamente (brightness = 0.5 = neutro)
- **Manual**: Ajusta automaticamente + aplica offset configurável pelo usuário (-100% a +100%)

```dart
if (_brightnessMode == BrightnessModeConfig.manual) {
  final brightnessValue = _brightnessPercentToValue(_brightnessPercent);
  await CamerawesomePlugin.setBrightness(brightnessValue);
} else if (_brightnessMode == BrightnessModeConfig.auto) {
  await CamerawesomePlugin.setBrightness(0.5);
}
```

#### **d) Feedback Visual** (linhas 340-350)

```dart
setState(() {
  _brightnessJustApplied = true;  // Mostra bolinha vermelha
});
```

- Uma bolinha vermelha aparece no centro da tela por 300ms
- Indica visualmente que o ajuste foi aplicado

### 2. **Timer de Fallback** (função `_startNoFaceTimer`, linhas 356-364)

Se nenhum rosto for detectado por 5 segundos:

```dart
_noFaceTimer = Timer(_noFaceTimeout, () {
  _adjustBrightnessToCenter();
});
```

- Ajusta foco e brilho para o centro da tela (0.5, 0.5)
- Útil quando o usuário não está olhando para a câmera

---

## 🛠️ Arquitetura do Código

### 1. **Estrutura de Arquivos**

```
lib/
├── main.dart              # Arquivo principal (632 linhas)
│   ├── MLKitUtils         # Extensão para converter AnalysisImage → InputImage
│   ├── FaceDetectionModel # Modelo de dados para detecção
│   ├── FaceAwareCamera    # Widget principal
│   ├── _FacePreviewDecorator # Widget que gerencia o desenho
│   └── FaceContourPainter # CustomPainter que desenha contornos
└── settings_screen.dart   # Tela de configurações
```

### 2. **Componentes Principais**

#### **a) FaceDetectionModel** (linhas 82-113)

Classe que encapsula os dados de uma detecção facial:

```dart
class FaceDetectionModel {
  final List<Face> faces;
  final Size absoluteImageSize;
  final InputImageRotation imageRotation;
  final AnalysisImage? img;
  
  Size get croppedSize => img?.croppedSize ?? absoluteImageSize;
}
```

#### **b) StreamController** (linha 130)

```dart
late StreamController<FaceDetectionModel> _faceDetectionController;
```

- Usado para comunicação reativa entre detecção e desenho
- Permite que o `FaceContourPainter` seja atualizado automaticamente quando novos rostos são detectados

#### **c) _FacePreviewDecorator** (linhas 498-550)

Widget que gerencia o desenho dos contornos:

- Usa `StreamBuilder` para escutar mudanças no `faceDetectionStream`
- Cria o `FaceContourPainter` quando há dados disponíveis
- Obtém `canvasTransformation` para lidar com espelhamento no Android

### 3. **Dependências Principais** (pubspec.yaml)

```yaml
camerawesome: ^2.1.0                    # Câmera moderna e simplificada
google_mlkit_face_detection: ^0.12.0   # Detecção facial
shared_preferences: ^2.2.2             # Salvar configurações
```

### 4. **Fluxo de Dados Simplificado**

```
Câmera → AnalysisImage → InputImage → FaceDetector → Face[]
                                                          ↓
                                    FaceDetectionModel (Stream)
                                                          ↓
                                    _FacePreviewDecorator (StreamBuilder)
                                                          ↓
                                    FaceContourPainter (CustomPaint)
                                                          ↓
                                    Desenho na Tela (Contornos + Pontos)
```

---

## 🎓 Conceitos Avançados

### 1. **Transformações de Coordenadas**

O código faz várias transformações complexas:

- **Espaço da imagem ML Kit** → **Espaço do preview (cropped)** → **Espaço do canvas**
- Usa `preview.convertFromImage()` para mapear coordenadas
- Aplica escala e offset baseado em `previewSize` e `canvasSize`
- Diferentes para Portrait vs Landscape
- Diferentes para Android vs iOS (espelhamento)

### 2. **Orientação e Rotação**

- **AppOrientation**: Configuração do app (Portrait/Landscape)
- **DeviceOrientation**: Orientação física do dispositivo
- **InputImageRotation**: Rotação que o ML Kit espera
- **KeyedSubtree**: Força reconstrução do CameraAwesome quando orientação muda

```dart
KeyedSubtree(
  key: ValueKey(_currentOrientation),
  child: CameraAwesomeBuilder.custom(...),
)
```

### 3. **CameraPreviewFit.contain**

O preview usa `CameraPreviewFit.contain`, o que significa:
- A imagem mantém o aspect ratio
- A imagem fica centralizada na tela
- Pode haver áreas pretas nas bordas
- Precisa calcular `previewSize`, `scaleToCanvasX/Y` e `offset` para desenhar corretamente

### 4. **CanvasTransformation**

No Android, a câmera frontal espelha o preview, mas a imagem de análise não. O `getCanvasTransformation()` retorna uma transformação que corrige isso:

```dart
final canvasTransformation = faceModelSnapshot.data!.img
    ?.getCanvasTransformation(preview);
```

---

## 🐛 Pontos de Atenção

1. **Performance**: O processamento é feito em background, mas pode ser pesado em dispositivos antigos (5 FPS)
2. **Rotação**: A lógica de rotação é complexa e pode ter bugs em alguns dispositivos
3. **Threading**: Tudo roda na thread principal (UI thread), o que pode causar lag
4. **Orientação**: Mudanças de orientação requerem reconstrução do CameraAwesome (usando KeyedSubtree)

---

## 📝 Resumo Executivo

**O que o app faz:**
1. Abre a câmera frontal usando CamerAwesome
2. Processa cada frame em tempo real (5 FPS)
3. Detecta rostos usando Google ML Kit (com contornos e landmarks)
4. Desenha contornos faciais e pontos na tela em tempo real
5. Ajusta foco e brilho automaticamente no rosto
6. Permite configurar modo de brilho e orientação

**Tecnologias principais:**
- Flutter (framework)
- CamerAwesome (câmera moderna)
- Google ML Kit (machine learning)
- CustomPainter (desenho customizado)
- Streams (programação reativa)

**Complexidade:**
- ⭐⭐⭐⭐ (4/5) - Código intermediário/avançado
- Principal dificuldade: transformações de coordenadas e mapeamento entre espaços

---

## 🚀 Próximos Passos para Desenvolver

1. **Entenda o fluxo básico**: Câmera → ML Kit → Stream → Desenho
2. **Estude as transformações de coordenadas**: É a parte mais complexa
3. **Teste em diferentes dispositivos**: Android e iOS podem se comportar diferente
4. **Experimente com os parâmetros**: `minFaceSize`, `performanceMode`, `maxFramesPerSecond`
5. **Adicione features**: Por exemplo, detectar múltiplos rostos, salvar fotos, etc.

---

**Última atualização**: Baseado na análise do código em `main.dart` (632 linhas) e `settings_screen.dart` (234 linhas).
