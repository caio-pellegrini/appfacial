---
name: Implementar controle de brilho/foco no face_recognition
overview: Adicionar configurações de modo de brilho (off/auto/manual), slider de brilho e feedback visual na tela de settings do face_recognition, e passar essas configurações para o animated_face_detection via DetectionConfig.
todos:
  - id: "1"
    content: Atualizar SettingsApp entity para incluir brightnessMode, brightnessPercent e showVisualFeedback com métodos toMap/fromMap/copyWith
    status: pending
  - id: "2"
    content: Adicionar UI de configuração de brilho na settings_page.dart (RadioListTile para modo, Slider para brilho quando manual, SwitchListTile para feedback visual)
    status: pending
    dependencies:
      - "1"
  - id: "3"
    content: Atualizar SettingsController para salvar/carregar configurações de brilho do SettingsApp
    status: pending
    dependencies:
      - "1"
  - id: "4"
    content: Atualizar RecognitionService para ler configurações do GlobalStore e passar para DetectionConfig
    status: pending
    dependencies:
      - "1"
      - "2"
      - "3"
---

# Plano: Implementar Controle de Brilho/Foco no face_recognition

## Visão Geral

Este plano adiciona as configurações de controle de brilho/foco no projeto `face_recognition`, permitindo que o usuário configure o modo de brilho (off/auto/manual), o valor do brilho quando em modo manual, e o feedback visual. Essas configurações serão passadas para o `animated_face_detection` via `DetectionConfig`.

## Fluxo de Dados

```
Settings Page (UI)
    ↓
SettingsController (salva/carrega)
    ↓
SettingsApp Entity (armazena)
    ↓
GlobalStore (acesso global)
    ↓
RecognitionService (lê e passa)
    ↓
DetectionConfig (para animated_face_detection)
```

## Implementação

### 1. Atualizar `SettingsApp` Entity

**Arquivo**: `lib/app/modules/settings/domain/entities/settings_app.dart`

Adicionar três campos opcionais à classe `SettingsApp`:

- `int? brightnessMode` - Modo de brilho (0=off, 1=auto, 2=manual)
- `double? brightnessPercent` - Valor do brilho em percentual (-100.0 a 100.0)
- `bool? showVisualFeedback` - Exibir feedback visual (bolinhas e contornos)

**Mudanças necessárias:**

- Adicionar campos no construtor (opcionais)
- Adicionar campos no `copyWith()`
- Adicionar campos no `toMap()`
- Adicionar campos no `fromMap()` com valores padrão:
  - `brightnessMode`: `1` (auto) se não existir
  - `brightnessPercent`: `0.0` se não existir
  - `showVisualFeedback`: `false` se não existir

### 2. Atualizar Tela de Settings

**Arquivo**: `lib/app/modules/settings/presentation/pages/settings_page.dart`

Adicionar nova seção após o campo Token (antes dos botões de rotação):

**Seção "Controle de Brilho":**

- Título: "Controle de Brilho"
- RadioListTile para modo:
  - "Desligado (Off)" - `brightnessMode = 0`
  - "Automático (Auto)" - `brightnessMode = 1` (padrão)
  - "Manual" - `brightnessMode = 2`
- Slider de brilho (visível apenas quando modo = manual):
  - Range: -100.0 a 100.0
  - Divisions: 20 (step de 10%)
  - Label: "Brilho: X%"
  - Labels: "-100% (Escuro)", "0%", "+100% (Claro)"

**Seção "Feedback Visual":**

- SwitchListTile:
  - Título: "Exibir feedback visual"
  - Subtítulo: "Mostra bolinhas de foco/brilho e contornos da face"
  - Valor: `showVisualFeedback`

**Estado local:**

- Adicionar variáveis: `_brightnessMode`, `_brightnessPercent`, `_showVisualFeedback`
- Carregar valores do `SettingsApp` no `_init()`
- Salvar valores no método de salvar

### 3. Atualizar `SettingsController`

**Arquivo**: `lib/app/modules/settings/presentation/controller/settings_controller.dart`

Adicionar métodos para salvar/carregar configurações de brilho:

**Método para salvar:**

- Atualizar `SettingsApp` com novos valores de brilho
- Salvar via `SettingsStore.saveSettingsDatabase()`
- Atualizar `GlobalStore.setSettingsApp()`

**Método para carregar:**

- Ler do `SettingsApp` atual
- Retornar valores padrão se não existir:
  - `brightnessMode = 1` (auto)
  - `brightnessPercent = 0.0`
  - `showVisualFeedback = false`

### 4. Atualizar `RecognitionService`

**Arquivo**: `lib/app/modules/face_recognition/presentation/helper/recognition_service.dart`

**Modificar métodos `startFullDetection()` e `startBasicDetection()`:**

1. Ler configurações de brilho do `GlobalStore` ou `SettingsApp`:
   ```dart
   final brightnessMode = _globalStore.settingsApp?.brightnessMode ?? 1; // default: auto
   final brightnessPercent = _globalStore.settingsApp?.brightnessPercent ?? 0.0;
   final showVisualFeedback = _globalStore.settingsApp?.showVisualFeedback ?? false;
   ```

2. Passar para `DetectionConfig`:

   - Adicionar parâmetros `brightnessMode`, `brightnessPercent`, `showVisualFeedback` ao construtor de `DetectionConfig`
   - Nota: Esses campos ainda não existem no `DetectionConfig` - serão adicionados no projeto `animated_face_detection`

## Valores Padrão

- **brightnessMode**: `1` (auto) - aplica apenas foco automático
- **brightnessPercent**: `0.0` - brilho neutro
- **showVisualFeedback**: `false` - não exibe feedback visual

## Compatibilidade

- Todas as mudanças são aditivas
- Se as configurações não existirem, usam valores padrão
- Não quebra funcionalidades existentes
- Configurações são opcionais no `SettingsApp`

## Arquivos a Modificar

1. `lib/app/modules/settings/domain/entities/settings_app.dart`
2. `lib/app/modules/settings/presentation/pages/settings_page.dart`
3. `lib/app/modules/settings/presentation/controller/settings_controller.dart`
4. `lib/app/modules/face_recognition/presentation/helper/recognition_service.dart`

## Notas Importantes

- As configurações serão passadas para `animated_face_detection` via `DetectionConfig`
- O enum `BrightnessModeConfig` será criado no projeto `animated_face_detection`
- Os valores são armazenados no `SettingsApp` e persistidos no banco de dados local
- O `GlobalStore` fornece acesso global às configurações