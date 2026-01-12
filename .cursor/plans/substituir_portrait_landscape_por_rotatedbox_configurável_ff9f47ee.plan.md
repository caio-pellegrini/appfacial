# Substituir Portrait/Landscape por RotatedBox Configurável

## Objetivo

Substituir a lógica de orientação baseada em `AppOrientation` (portrait/landscape) por valores numéricos de rotação (`cameraRotate`) usando `RotatedBox`, permitindo rotações configuráveis em incrementos de 90 graus.

## Arquivos a Modificar

### 1. `lib/settings_screen.dart`

- **Remover**: Enum `AppOrientation` e campos relacionados
- **Adicionar**: Campo `cameraRotate` (int, valores de 0-3 representando quartos de volta)
- **Atualizar UI**: Substituir RadioListTile de Portrait/Landscape por controle numérico (Slider ou Dropdown) para `cameraRotate`
- **Atualizar SharedPreferences**: Salvar `cameraRotate` ao invés de `appOrientation`
- **Atualizar retorno**: Retornar `cameraRotate` no Map ao invés de `orientation`

### 2. `lib/main.dart`

- **Remover**: 
- Enum `AppOrientation` (mover para settings_screen se necessário para compatibilidade temporária)
- Variável `_currentOrientation` do tipo `AppOrientation`
- Método `_applyOrientation(AppOrientation orientation)`
- Chamadas a `SystemChrome.setPreferredOrientations()` (ou manter apenas portrait fixo)
- **Adicionar**:
- Variável `_cameraRotate` (int, padrão: 0)
- Carregamento do valor de SharedPreferences com chave `'cameraRotate'`
- **Atualizar `_loadSettings()`**: Carregar `cameraRotate` de SharedPreferences
- **Atualizar `_openSettings()`**: Receber e aplicar `cameraRotate` do resultado
- **Atualizar `build()`**: 
- Envolver `CameraAwesomeBuilder` com `RotatedBox(quarterTurns: _cameraRotate)`
- Atualizar `ValueKey` para usar o valor de rotação (ex: `ValueKey('camera_${_cameraRotate}')`)
- **Atualizar `_adjustHardwareFocus()`**: 
- Remover lógica baseada em `isLandscape`
- Ajustar transformações de coordenadas baseadas em `_cameraRotate` ao invés de orientação binária
- Considerar que cada `quarterTurns` representa 90 graus de rotação

### 3. Estrutura de Dados

- **SharedPreferences keys**:
- Remover: `'appOrientation'`
- Adicionar: `'cameraRotate'` (int, padrão: 0)

## Detalhes de Implementação

### Valores de Rotação

- `0` = 0° (sem rotação)
- `1` = 90° (sentido horário)
- `2` = 180°
- `3` = 270° (ou -90°)

### UI de Configuração

Na tela de settings, adicionar um controle:

1. **Rotação da Câmera**: Slider ou Dropdown (0-3) com labels descritivos (0°=sem rotação, 1=90°, 2=180°, 3=270°)

### Lógica de Foco

A função `_adjustHardwareFocus()` precisa ser atualizada para calcular transformações baseadas no valor numérico de `_cameraRotate` ao invés de `isLandscape`. Cada valor de rotação requer transformações diferentes de coordenadas.

### Compatibilidade

- Manter `SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]) `fixo no `main()` para garantir que o app sempre inicie em portrait
- O `RotatedBox` será responsável pela rotação visual, não a orientação do sistema

## Ordem de Execução

1. Atualizar `settings_screen.dart` (UI e lógica de salvamento)
2. Atualizar `main.dart` (remover lógica antiga, adicionar nova)
3. Testar carregamento e salvamento de configurações
4. Testar aplicação de rotação na câmera
5. Ajustar lógica de foco conforme necessário