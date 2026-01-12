---
name: Remover toda lógica de rotação da câmera
overview: Remover completamente toda a funcionalidade de rotação da câmera, incluindo RotatedBox, variável _cameraRotate, configurações de rotação na tela de settings, e simplificar a lógica de foco para usar apenas o padrão (0 graus).
todos:
  - id: "1"
    content: Remover variável _cameraRotate e comentários relacionados em main.dart
    status: pending
  - id: "2"
    content: Remover carregamento de cameraRotate do SharedPreferences em _loadSettings()
    status: pending
    dependencies:
      - "1"
  - id: "3"
    content: Remover currentCameraRotate e newCameraRotate de _openSettings()
    status: pending
    dependencies:
      - "2"
  - id: "4"
    content: Remover RotatedBox do build() e manter apenas CameraAwesomeBuilder
    status: pending
    dependencies:
      - "3"
  - id: "5"
    content: Simplificar _adjustHardwareFocus() para usar apenas lógica padrão (sem switch)
    status: pending
    dependencies:
      - "4"
  - id: "6"
    content: Remover currentCameraRotate e _cameraRotate de settings_screen.dart
    status: pending
  - id: "7"
    content: Remover salvamento de cameraRotate e do retorno em settings_screen.dart
    status: pending
    dependencies:
      - "6"
  - id: "8"
    content: Remover toda a seção de UI de rotação da câmera em settings_screen.dart
    status: pending
    dependencies:
      - "7"
---

# Remover Toda Lógica de Rotação da Câmera

## Objetivo

Remover completamente toda a funcionalidade de rotação da câmera do app, deixando-o funcionar apenas no padrão (0 graus, sem rotação). Isso inclui remover o RotatedBox, a variável _cameraRotate, as configurações de rotação na tela de settings, e simplificar a lógica de foco.

## Arquivos a Modificar

### 1. `lib/main.dart`

#### a) Remover variável `_cameraRotate`

**Localização**: Linha ~123

- Remover: `int _cameraRotate = 0;`

#### b) Remover comentário sobre rotação no `main()`

**Localização**: Linha ~60-61

- Remover comentário sobre rotação

#### c) Remover carregamento de `cameraRotate` do SharedPreferences

**Localização**: Linha ~151 e ~156

- Remover: `final cameraRotate = prefs.getInt('cameraRotate') ?? 0;`
- Remover: `_cameraRotate = cameraRotate.clamp(0, 3);` do setState

#### d) Remover `currentCameraRotate` do `_openSettings()`

**Localização**: Linha ~175

- Remover: `currentCameraRotate: _cameraRotate,` do SettingsScreen

#### e) Remover `newCameraRotate` do resultado de `_openSettings()`

**Localização**: Linha ~183 e ~189

- Remover: `final newCameraRotate = result['cameraRotate'] as int;`
- Remover: `_cameraRotate = newCameraRotate.clamp(0, 3);` do setState

#### f) Remover `RotatedBox` do `build()`

**Localização**: Linha ~444-467

- Remover o `RotatedBox` e manter apenas o `CameraAwesomeBuilder.custom` diretamente

#### g) Simplificar `_adjustHardwareFocus()` para usar apenas lógica padrão

**Localização**: Linha ~240-292

- Remover toda a lógica de switch baseada em `_cameraRotate`
- Para Android: manter apenas a transformação do case 0 (sem rotação)
- Para iOS: manter apenas a lógica do case 0 (sem transformação adicional)

### 2. `lib/settings_screen.dart`

#### a) Remover `currentCameraRotate` do `SettingsScreen`

**Localização**: Linha ~10 e ~16

- Remover: `final int currentCameraRotate;` do StatefulWidget
- Remover: `required this.currentCameraRotate,` do construtor

#### b) Remover `_cameraRotate` do `_SettingsScreenState`

**Localização**: Linha ~26 e ~33

- Remover: `late int _cameraRotate;`
- Remover: `_cameraRotate = widget.currentCameraRotate.clamp(0, 3);` do initState

#### c) Remover salvamento de `cameraRotate` no SharedPreferences

**Localização**: Linha ~40

- Remover: `await prefs.setInt('cameraRotate', _cameraRotate);`

#### d) Remover `cameraRotate` do retorno

**Localização**: Linha ~46

- Remover: `'cameraRotate': _cameraRotate,` do Navigator.pop

#### e) Remover toda a seção de UI de rotação da câmera

**Localização**: Linha ~165-224

- Remover todo o bloco desde o Divider até o Container com DropdownButton de rotação
- Isso inclui: título "Rotação da Câmera", texto explicativo, e o DropdownButton completo

## Detalhes de Implementação

### Simplificação de `_adjustHardwareFocus()`

**Código atual** (com switch baseado em `_cameraRotate`):

```dart
if (Platform.isAndroid) {
  switch (_cameraRotate) {
    case 0:
      double tempX = x;
      x = y;
      y = 1.0 - tempX;
      break;
    // ... outros cases
  }
} else if (Platform.isIOS) {
  switch (_cameraRotate) {
    case 0:
      // Sem transformação adicional
      break;
    // ... outros cases
  }
}
```

**Código novo** (apenas lógica padrão):

```dart
if (Platform.isAndroid) {
  double tempX = x;
  x = y;
  y = 1.0 - tempX;
} else if (Platform.isIOS) {
  // Sem transformação adicional para iOS
}
```

### Remoção do RotatedBox

**Código atual**:

```dart
RotatedBox(
  quarterTurns: _cameraRotate,
  child: CameraAwesomeBuilder.custom(
    // ...
  ),
),
```

**Código novo**:

```dart
CameraAwesomeBuilder.custom(
  // ...
),
```

## Ordem de Execução

1. Remover variável `_cameraRotate` e comentários relacionados em `main.dart`
2. Remover carregamento e salvamento de `cameraRotate` do SharedPreferences
3. Remover `RotatedBox` do `build()`
4. Simplificar `_adjustHardwareFocus()` para usar apenas lógica padrão
5. Remover `currentCameraRotate` e `_cameraRotate` de `settings_screen.dart`
6. Remover toda a seção de UI de rotação da câmera em `settings_screen.dart`
7. Remover `cameraRotate` do retorno de settings

## Resultado Esperado

Após a implementação:

- O app funcionará apenas no padrão (0 graus, sem rotação)
- Não haverá mais configuração de rotação na tela de settings
- A câmera usará apenas a orientação padrão do dispositivo
- A lógica de foco será simplificada para o caso padrão
- O código ficará mais simples e sem dependências de rotação configurável