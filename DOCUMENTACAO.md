# 📚 Documentação do Projeto AppFacial

## 🎯 Visão Geral

Este é um aplicativo Flutter que utiliza **reconhecimento facial em tempo real** para ajustar automaticamente o foco e a exposição da câmera quando detecta um rosto. O app funciona como uma câmera inteligente que "segue" o rosto do usuário.

---

## 🔍 Como Funciona o Reconhecimento Facial

### 1. **Tecnologia Utilizada: Google ML Kit Face Detection**

O projeto usa o pacote `google_mlkit_face_detection` que é uma biblioteca oficial do Google para detecção facial em dispositivos móveis. Esta biblioteca:

- **Funciona offline** (não precisa de internet)
- **Processa em tempo real** (baixa latência)
- **Usa machine learning** (modelos pré-treinados)
- **Otimizado para mobile** (usa GPU quando disponível)

### 2. **Configuração do Detector**

No arquivo `main.dart`, linhas 74-81, o detector é configurado assim:

```dart
final options = FaceDetectorOptions(
  performanceMode: FaceDetectorMode.accurate,  // Modo preciso (mais lento, mas melhor)
  enableContours: false,                        // Não detecta contornos faciais
  enableClassification: false,                  // Não classifica expressões
  minFaceSize: 0.1,                            // Tamanho mínimo do rosto (10% da imagem)
);
```

**O que cada parâmetro significa:**
- `performanceMode.accurate`: Prioriza precisão sobre velocidade (melhor para condições adversas de luz)
- `minFaceSize: 0.1`: Detecta rostos que ocupam pelo menos 10% da imagem (torna mais sensível)

---

## 📷 Como o Rosto é Reconhecido

### Fluxo Completo de Detecção:

#### **Passo 1: Inicialização da Câmera** (linhas 163-195)
```dart
_controller = CameraController(
  _cameraDescription!,
  ResolutionPreset.high,  // Alta resolução
  enableAudio: false,
  imageFormatGroup: Platform.isAndroid 
    ? ImageFormatGroup.nv21 
    : ImageFormatGroup.bgra8888,
);
```

- Seleciona a câmera frontal (ou primeira disponível)
- Configura resolução alta para melhor detecção
- Inicia um **stream de imagens** (`startImageStream`)

#### **Passo 2: Processamento de Cada Frame** (linhas 197-270)

Para cada frame capturado pela câmera:

1. **Conversão para InputImage** (linha 202)
   ```dart
   final inputImage = _inputImageFromCameraImage(image);
   ```
   - Converte o formato bruto da câmera (`CameraImage`) para o formato que o ML Kit entende (`InputImage`)
   - Ajusta a rotação baseada na plataforma (Android/iOS) e orientação (Portrait/Landscape)

2. **Detecção Facial** (linha 208)
   ```dart
   final faces = await _faceDetector.processImage(inputImage);
   ```
   - O ML Kit analisa a imagem usando modelos de machine learning
   - Retorna uma lista de `Face` objetos (pode detectar múltiplos rostos)
   - Cada `Face` contém um `boundingBox` (retângulo com coordenadas do rosto)

3. **Processamento do Resultado**
   - Se **rosto detectado**: atualiza UI e ajusta foco/exposição
   - Se **nenhum rosto**: inicia timer de fallback (após 5 segundos, ajusta para o centro)

#### **Passo 3: Conversão de Coordenadas** (função `_inputImageFromCameraImage`, linhas 425-484)

Esta é uma parte **crítica** e complexa do código:

- **Problema**: A câmera fornece imagens em um formato/rotação específica, mas o ML Kit precisa de uma rotação diferente
- **Solução**: O código calcula a rotação correta baseada em:
  - Plataforma (Android vs iOS)
  - Tipo de câmera (frontal vs traseira)
  - Orientação do app (Portrait vs Landscape)

**Exemplo para Android frontal em Portrait:**
```dart
rotation = InputImageRotation.rotation270deg;  // Rotação de 270 graus
```

---

## ✅ O Que Acontece DEPOIS que Reconhece o Rosto

### 1. **Atualização Visual Imediata** (linhas 234-238)

```dart
setState(() {
  _faceRectRaw = face.boundingBox;           // Salva coordenadas do rosto
  _imageSizeRaw = Size(image.width, image.height);  // Salva tamanho da imagem
  _currentRotation = inputImage.metadata!.rotation;  // Salva rotação
});
```

- Atualiza o estado do widget
- Isso dispara o `FacePainter` que desenha um retângulo branco ao redor do rosto
- Desenha uma bolinha amarela no centro do rosto (feedback visual)

### 2. **Ajuste Automático de Foco e Exposição** (função `_adjustHardwareFocus`, linhas 272-359)

Esta é a funcionalidade principal do app! Quando detecta um rosto:

#### **a) Calcula o Ponto de Foco** (linhas 280-311)
```dart
double centerX = faceRect.center.dx;
double centerY = faceRect.center.dy;
double x = centerX / image.width;   // Normaliza para 0.0-1.0
double y = centerY / image.height;  // Normaliza para 0.0-1.0
```

- Pega o centro do retângulo do rosto
- Converte para coordenadas normalizadas (0.0 a 1.0)
- Ajusta para rotação/orientação (código complexo nas linhas 286-309)

#### **b) Aplica Foco e Exposição** (linhas 314-344)
```dart
await _controller!.setExposureMode(ExposureMode.auto);
await _controller!.setFocusMode(FocusMode.auto);
await _controller!.setExposurePoint(point);  // Foca no rosto!
await _controller!.setFocusPoint(point);     // Expõe no rosto!
```

**Modos de Exposição:**
- **Off**: Não ajusta nada
- **Auto**: Ajusta automaticamente (offset = 0.0)
- **Manual**: Ajusta automaticamente + aplica offset configurável pelo usuário

#### **c) Feedback Visual** (linhas 347-357)
```dart
setState(() {
  _exposureJustApplied = true;  // Bolinha fica vermelha e maior
});
```

- A bolinha amarela no centro do rosto fica **vermelha e maior** por 300ms
- Indica visualmente que o ajuste foi aplicado

### 3. **Desenho do Retângulo na Tela** (classe `FacePainter`, linhas 566-839)

Esta classe é responsável por desenhar o retângulo ao redor do rosto. É **muito complexa** porque:

- Precisa converter coordenadas do espaço do ML Kit para o espaço da tela
- Precisa lidar com diferentes rotações (Portrait/Landscape)
- Precisa espelhar horizontalmente para câmera frontal
- Precisa calcular escala do `CameraPreview` (que usa `BoxFit.cover`)

**Principais cálculos:**
1. **Conversão de coordenadas** (linhas 631-671)
2. **Cálculo de escala** (linhas 674-682)
3. **Aplicação de offsets** (linhas 684-693)
4. **Espelhamento** (linhas 710-721)

---

## 🛠️ O Que Você Precisa Saber para Codificar

### 1. **Conceitos de Flutter Essenciais**

- **StatefulWidget**: O app usa `StatefulWidget` para gerenciar estado
- **setState()**: Usado para atualizar a UI quando detecta rosto
- **CustomPainter**: Classe `FacePainter` desenha o retângulo na tela
- **Streams**: A câmera fornece um stream contínuo de imagens

### 2. **Conceitos de Câmera**

- **CameraController**: Controla a câmera do dispositivo
- **CameraImage**: Formato bruto dos frames da câmera
- **ExposurePoint/FocusPoint**: Coordenadas normalizadas (0.0-1.0) onde focar
- **ExposureOffset**: Ajuste manual de brilho (em EV - Exposure Value)

### 3. **Conceitos de ML Kit**

- **InputImage**: Formato que o ML Kit entende
- **FaceDetector**: Objeto que detecta rostos
- **Face.boundingBox**: Retângulo com coordenadas do rosto detectado
- **InputImageRotation**: Rotação da imagem (0°, 90°, 180°, 270°)

### 4. **Pontos Críticos do Código**

#### **a) Processamento Assíncrono**
```dart
bool _isProcessing = false;  // Evita processar múltiplos frames simultaneamente

void _processCameraImage(CameraImage image) async {
  if (_isProcessing) return;  // ⚠️ IMPORTANTE: Evita sobrecarga
  _isProcessing = true;
  // ... processa ...
  _isProcessing = false;
}
```

#### **b) Timer de Fallback**
```dart
static const Duration _noFaceTimeout = Duration(seconds: 5);

// Se não detecta rosto por 5 segundos, ajusta para o centro
_noFaceTimer = Timer(_noFaceTimeout, () {
  _adjustExposureToCenter();
});
```

#### **c) Persistência de Configurações**
```dart
// Salva configurações usando SharedPreferences
await prefs.setInt('exposureMode', _exposureMode.index);
await prefs.setDouble('exposureOffset', _exposureOffset);
```

### 5. **Estrutura de Arquivos**

```
lib/
├── main.dart              # Arquivo principal (840 linhas)
│   ├── FaceAwareCamera    # Widget principal
│   └── FacePainter        # Desenha retângulo do rosto
└── settings_screen.dart   # Tela de configurações
```

### 6. **Dependências Principais** (pubspec.yaml)

```yaml
camera: ^0.11.0                        # Acesso à câmera
google_mlkit_face_detection: ^0.10.0   # Detecção facial
shared_preferences: ^2.2.2             # Salvar configurações
```

### 7. **Fluxo de Dados Simplificado**

```
Câmera → CameraImage → InputImage → FaceDetector → Face[] 
                                                      ↓
                                              boundingBox (coordenadas)
                                                      ↓
                                    Ajuste de Foco/Exposição + Desenho na Tela
```

---

## 🎓 Conceitos Avançados que Você Encontrará

### 1. **Transformações de Coordenadas**

O código faz várias transformações complexas:
- **Espaço da imagem bruta** → **Espaço rotacionado (ML Kit)** → **Espaço da tela**
- Diferentes para Portrait vs Landscape
- Diferentes para Android vs iOS
- Diferentes para câmera frontal vs traseira

### 2. **Orientação e Rotação**

- **AppOrientation**: Configuração do app (Portrait/Landscape)
- **DeviceOrientation**: Orientação física do dispositivo
- **InputImageRotation**: Rotação que o ML Kit espera

### 3. **BoxFit.cover e Escala**

O `CameraPreview` usa `BoxFit.cover`, o que significa:
- A imagem pode ser cortada para preencher a tela
- Precisa calcular offsets e escala para desenhar o retângulo corretamente

---

## 🐛 Pontos de Atenção

1. **Performance**: O processamento é feito em background, mas pode ser pesado em dispositivos antigos
2. **Rotação**: A lógica de rotação é complexa e pode ter bugs em alguns dispositivos
3. **Threading**: Tudo roda na thread principal (UI thread), o que pode causar lag
4. **Logs**: O código tem muitos `log()` para debug (linhas 216-231, 602-752)

---

## 📝 Resumo Executivo

**O que o app faz:**
1. Abre a câmera frontal
2. Processa cada frame em tempo real
3. Detecta rostos usando Google ML Kit
4. Ajusta foco e exposição automaticamente no rosto
5. Desenha um retângulo ao redor do rosto detectado
6. Permite configurar modo de exposição e orientação

**Tecnologias principais:**
- Flutter (framework)
- Google ML Kit (machine learning)
- Camera plugin (acesso à câmera)
- CustomPainter (desenho customizado)

**Complexidade:**
- ⭐⭐⭐⭐ (4/5) - Código intermediário/avançado
- Principal dificuldade: transformações de coordenadas e rotações

---

## 🚀 Próximos Passos para Desenvolver

1. **Entenda o fluxo básico**: Câmera → ML Kit → Ajuste de foco
2. **Estude as transformações de coordenadas**: É a parte mais complexa
3. **Teste em diferentes dispositivos**: Android e iOS podem se comportar diferente
4. **Experimente com os parâmetros**: `minFaceSize`, `performanceMode`, etc.
5. **Adicione features**: Por exemplo, detectar múltiplos rostos, salvar fotos, etc.

---

**Última atualização**: Baseado na análise do código em `main.dart` (840 linhas) e `settings_screen.dart` (233 linhas).
