# Documentação: Sistema de Rotação da Câmera
(Aviso: documentação legada - o sistema de rotação foi removido)

## Visão Geral

O sistema de rotação da câmera permite que o usuário configure a rotação da visualização da câmera em incrementos de 90 graus (0°, 90°, 180°, 270°). A rotação é aplicada visualmente através do widget `RotatedBox` e também ajusta a lógica de foco automático para funcionar corretamente em cada orientação.

## Componentes Principais

### 1. Armazenamento de Configuração

**Localização**: `lib/main.dart` - método `_loadSettings()` (linha ~147-158)

A configuração de rotação é armazenada no `SharedPreferences` com a chave `'cameraRotate'`:

```dart
final cameraRotate = prefs.getInt('cameraRotate') ?? 0;
_cameraRotate = cameraRotate.clamp(0, 3);
```

**Valores possíveis**:
- `0` = 0° (sem rotação)
- `1` = 90° (sentido horário)
- `2` = 180°
- `3` = 270° (ou -90°)

**Valor padrão**: `0` (sem rotação)

### 2. Variável de Estado

**Localização**: `lib/main.dart` - classe `_FaceAwareCameraState` (linha ~123)

```dart
int _cameraRotate = 0;
```

Esta variável armazena o valor atual da rotação da câmera e é atualizada quando:
- As configurações são carregadas do `SharedPreferences`
- O usuário altera a rotação na tela de settings

### 3. Aplicação Visual da Rotação

**Localização**: `lib/main.dart` - método `build()` (linha ~444-467)

A rotação é aplicada visualmente envolvendo o `CameraAwesomeBuilder` com um `RotatedBox`:

```dart
RotatedBox(
  quarterTurns: _cameraRotate,
  child: CameraAwesomeBuilder.custom(
    saveConfig: SaveConfig.photo(),
    previewFit: CameraPreviewFit.contain,
    // ... outras configurações
  ),
),
```

**Como funciona**:
- `RotatedBox` é um widget do Flutter que rotaciona seu filho em incrementos de 90 graus
- `quarterTurns` especifica quantos quartos de volta (90°) aplicar
- `0` = sem rotação, `1` = 90°, `2` = 180°, `3` = 270°
- A rotação é aplicada tanto ao preview da câmera quanto aos overlays (contornos da face)

### 4. Interface de Configuração

**Localização**: `lib/settings_screen.dart` (linha ~165-224)

A tela de configurações permite ao usuário selecionar a rotação através de um `DropdownButton`:

```dart
DropdownButton<int>(
  value: _cameraRotate,
  items: [
    DropdownMenuItem<int>(value: 0, child: Text('0°')),
    DropdownMenuItem<int>(value: 1, child: Text('90°')),
    DropdownMenuItem<int>(value: 2, child: Text('180°')),
    DropdownMenuItem<int>(value: 3, child: Text('270°')),
  ],
  onChanged: (value) {
    if (value != null) {
      setState(() {
        _cameraRotate = value;
      });
    }
  },
),
```

**Fluxo de dados**:
1. O valor atual é passado para `SettingsScreen` via `currentCameraRotate: _cameraRotate`
2. O usuário seleciona um novo valor no dropdown
3. Ao salvar, o valor é armazenado no `SharedPreferences` e retornado via `Navigator.pop`
4. O valor retornado é aplicado em `_openSettings()` através de `setState`

### 5. Ajuste de Coordenadas para Foco Automático

**Localização**: `lib/main.dart` - método `_adjustHardwareFocus()` (linha ~240-292)

Quando a câmera está rotacionada, as coordenadas do ponto de foco precisam ser transformadas para corresponder à orientação visual. A lógica é diferente para Android e iOS:

#### Android

```dart
if (Platform.isAndroid) {
  switch (_cameraRotate) {
    case 0: // 0° - sem rotação
      double tempX = x;
      x = y;
      y = 1.0 - tempX;
      break;
    case 1: // 90° - sentido horário
      double tempX = x;
      x = 1.0 - y;
      y = tempX;
      break;
    case 2: // 180°
      double tempX = x;
      x = 1.0 - y;
      y = 1.0 - tempX;
      break;
    case 3: // 270° (ou -90°)
      double tempX = x;
      x = y;
      y = tempX;
      break;
  }
}
```

**Explicação das transformações**:
- **Case 0 (0°)**: Troca X por Y e inverte Y (transformação padrão para câmera frontal Android)
- **Case 1 (90°)**: Inverte Y e troca com X (rotação horária)
- **Case 2 (180°)**: Inverte ambos X e Y (rotação completa)
- **Case 3 (270°)**: Troca X por Y sem inversão (rotação anti-horária)

#### iOS

```dart
else if (Platform.isIOS) {
  switch (_cameraRotate) {
    case 0: // 0° - sem rotação
      // Sem transformação adicional
      break;
    case 1: // 90° - sentido horário
      double tempX = x;
      x = y;
      y = 1.0 - tempX;
      break;
    case 2: // 180°
      x = 1.0 - x;
      y = 1.0 - y;
      break;
    case 3: // 270° (ou -90°)
      double tempX = x;
      x = 1.0 - y;
      y = tempX;
      break;
  }
}
```

**Explicação das transformações**:
- **Case 0 (0°)**: Sem transformação (iOS já trata corretamente)
- **Case 1 (90°)**: Troca X por Y e inverte Y
- **Case 2 (180°)**: Inverte ambos X e Y
- **Case 3 (270°)**: Inverte Y e troca com X

**Nota importante**: As transformações são diferentes entre Android e iOS porque cada plataforma trata a orientação da câmera de forma diferente nativamente.

## Fluxo Completo

### Carregamento Inicial

1. App inicia → `initState()` é chamado
2. `_loadSettings()` é executado
3. `SharedPreferences` é consultado para `'cameraRotate'`
4. Se não existir, usa valor padrão `0`
5. `_cameraRotate` é atualizado via `setState()`
6. `RotatedBox` aplica a rotação no `build()`

### Alteração pelo Usuário

1. Usuário abre settings → `_openSettings()` é chamado
2. `SettingsScreen` recebe `currentCameraRotate: _cameraRotate`
3. Usuário seleciona nova rotação no dropdown
4. Usuário clica em "Salvar" → `_saveSettings()` é executado
5. Novo valor é salvo no `SharedPreferences` com chave `'cameraRotate'`
6. Valor é retornado via `Navigator.pop` com chave `'cameraRotate'`
7. `_openSettings()` recebe o resultado e atualiza `_cameraRotate` via `setState()`
8. `RotatedBox` reaplica a rotação no próximo `build()`

### Aplicação de Foco

1. Face é detectada → `_adjustHardwareFocus()` é chamado
2. Coordenadas do centro da face são normalizadas (0.0 a 1.0)
3. Transformações são aplicadas baseadas em `_cameraRotate` e plataforma (Android/iOS)
4. Coordenadas transformadas são usadas para focar na face

## Considerações Importantes

### Rotação do Dispositivo

O app permite rotação automática do dispositivo (não está travado em portrait). Isso significa que:
- O dispositivo pode estar em qualquer orientação (portrait, landscape)
- A rotação configurável (`_cameraRotate`) é aplicada **além** da rotação do dispositivo
- O `RotatedBox` rotaciona o preview visualmente, independente da orientação do dispositivo

### Preview Fit

O `previewFit` está configurado como `CameraPreviewFit.contain`, o que significa:
- A imagem da câmera mantém seu aspect ratio
- A imagem é centralizada e pode ter barras pretas se necessário
- Funciona bem em todas as orientações

### Compatibilidade com Contornos

Os contornos da face são desenhados sobre o preview rotacionado. Como o `RotatedBox` envolve todo o `CameraAwesomeBuilder`, os overlays (incluindo os contornos) são rotacionados junto com o preview, mantendo o alinhamento correto.

## Estrutura de Arquivos

### `lib/main.dart`

- **Variável de estado**: `int _cameraRotate = 0;` (linha ~123)
- **Carregamento**: `_loadSettings()` (linha ~147-158)
- **Aplicação visual**: `RotatedBox` no `build()` (linha ~444-467)
- **Ajuste de foco**: `_adjustHardwareFocus()` (linha ~240-292)
- **Atualização**: `_openSettings()` (linha ~168-193)

### `lib/settings_screen.dart`

- **Parâmetro**: `final int currentCameraRotate;` (linha ~10)
- **Estado local**: `late int _cameraRotate;` (linha ~26)
- **UI**: `DropdownButton` para seleção (linha ~192-223)
- **Salvamento**: `_saveSettings()` (linha ~36-49)

## Como Reimplementar

Se precisar reimplementar a rotação no futuro:

1. **Adicionar variável de estado**:
   ```dart
   int _cameraRotate = 0;
   ```

2. **Carregar do SharedPreferences**:
   ```dart
   final cameraRotate = prefs.getInt('cameraRotate') ?? 0;
   _cameraRotate = cameraRotate.clamp(0, 3);
   ```

3. **Aplicar visualmente com RotatedBox**:
   ```dart
   RotatedBox(
     quarterTurns: _cameraRotate,
     child: CameraAwesomeBuilder.custom(...),
   )
   ```

4. **Adicionar UI de configuração**:
   - DropdownButton com valores 0-3
   - Salvar no SharedPreferences com chave `'cameraRotate'`

5. **Ajustar lógica de foco**:
   - Implementar switch baseado em `_cameraRotate`
   - Usar transformações diferentes para Android e iOS
   - Seguir as fórmulas documentadas acima

## Notas Finais

- A rotação é aplicada apenas visualmente, não altera a orientação nativa da câmera
- As transformações de coordenadas são necessárias porque o sistema de foco trabalha com coordenadas da imagem original, não da visualização rotacionada
- A diferença entre Android e iOS nas transformações reflete como cada plataforma trata a orientação da câmera nativamente
- O valor é sempre validado com `.clamp(0, 3)` para garantir que está no range válido
