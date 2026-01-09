# Plano de Migração: Camera -> Camerawesome (AppFacial POC)

O objetivo é substituir a dependência `camera` pela `camerawesome` no projeto `appfacial`, adaptando as configurações para o padrão da nova biblioteca (Brilho 0.0 a 1.0).

## 1. Preparação

- Atualizar `pubspec.yaml`:
    - Remover `camera`.
    - Adicionar `camerawesome: ^2.1.0`.

## 2. Adaptação de Configurações (Offset -> Brightness)

### Ajuste de Exposição

- **Antigo (`camera`)**: EV (-2.0 a +2.0).
- **Novo (`camerawesome`)**: Brightness (0.0 a 1.0).
- **Mudança**:
    - A configuração passará a armazenar diretamente o valor de **Brightness**.
    - **Intervalo**: `0.0` (Escuro) a `1.0` (Claro).
    - **Neutro**: `0.5`.
    - Não haverá fórmula de conversão.

### Ponto de Foco e Exposição

- **`camera`**: `setExposurePoint` + `setFocusPoint`.
- **`camerawesome`**: `focusOnPoint(previewSize, position)`.
- **Impacto**: Unificação em uma única chamada que gerencia foco e exposição automática (AE) no ponto.

### Stream de Imagem

- **`camera`**: `startImageStream`.
- **`camerawesome`**: `onImageForAnalysis`.

## 3. Implementação em `lib/main.dart`

O arquivo será refatorado para usar `CameraAwesomeBuilder`.

### Estrutura Nova

- Substituir `CameraController` por `CameraAwesomeBuilder.custom`.
- Integrar o `FaceDetector` no callback `onImageForAnalysis`.

### Lógica de Exposição (`_applyExposure`)

- **Entrada**: Retângulo da face detectada.
- **Cálculo**:

    1. Calcular centro da face (x, y) relativo à imagem (0.0 - 1.0).
    2. Ajustar rotação (especialmente frontal Android).

- **Execução**:

    1. Chamar `CamerawesomePlugin.focusOnPoint` com o ponto calculado.
    2. Se modo **Manual**: Chamar `CamerawesomePlugin.setBrightness` com o valor configurado (0.0 a 1.0).
    3. Se modo **Auto**: Chamar `CamerawesomePlugin.setBrightness(0.5)` (Neutro).

### Fallback (Sem Rosto)

- Manter timer de 5s.
- Ao expirar:

    1. `focusOnPoint(0.5, 0.5)` (Centro).
    2. Se modo **Manual**: Reaplicar brightness configurado.
    3. Se modo **Auto**: Resetar brightness para 0.5.

## 4. Atualização da Tela de Configurações (`lib/settings_screen.dart`)

- **Slider**:
    - Alterar Range: `min: 0.0`, `max: 1.0`.
    - Alterar Divisões: `10` (saltos de 0.1) ou `20` (saltos de 0.05).
    - Valor Padrão: `0.5`.
- **Labels**: Remover referências a "EV", usar "Brilho".


Observações:
Comandos em flutter deve utilizar fvm flutter.