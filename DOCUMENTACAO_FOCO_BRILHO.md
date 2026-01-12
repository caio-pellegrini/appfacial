# Documentação: Aplicação de Foco e Brilho
12/01/2026

## Visão Geral

O aplicativo detecta rostos usando o Google ML Kit e aplica automaticamente foco e brilho na câmera quando um rosto é detectado. O sistema também possui um fallback que ajusta o foco para o centro da tela quando nenhum rosto é detectado por um período de tempo.

## Fluxo Principal

### 1. Detecção de Rosto

- Cada frame da câmera é processado pelo ML Kit (`_processCameraImage`)
- Quando um rosto é detectado, as coordenadas do centro do rosto são extraídas
- O sistema cancela o timer de "sem rosto" e chama `_focusOnDetectedFace`

### 2. Aplicação de Foco no Rosto Detectado (`_focusOnDetectedFace`)

**Coordenadas:**
1. O centro do rosto é convertido do espaço da imagem ML Kit para o espaço do preview usando `convertFromImage`
2. As coordenadas são normalizadas (0.0-1.0) no espaço do preview espelhado

**Android:**
- O preview está espelhado (câmera frontal), mas o sensor nativo não está
- Para o foco: invertemos o eixo X (`1.0 - normalizedX`) e convertemos para pixels do preview nativo
- Para o feedback visual: também invertemos X, pois o Stack não está espelhado como o preview
- Usa `AndroidFocusSettings(autoCancelDurationInMillis: 5000)`

**iOS:**
- Usa coordenadas normalizadas diretamente (0.0-1.0)
- Não precisa inverter coordenadas

**Aplicação:**
- `CamerawesomePlugin.focusOnPoint()` é chamado com as coordenadas corretas
- Uma bolinha vermelha aparece na posição onde o foco foi aplicado

### 3. Aplicação de Brilho (Modo Manual)

- Após o foco ser aplicado, aguarda 150ms
- No modo manual, aplica o brilho configurado pelo usuário
- `CamerawesomePlugin.setBrightness()` é chamado com o valor convertido
- Uma bolinha azul aparece na mesma posição do foco

### 4. Fallback: Foco no Centro (`_focusOnCenterWhenNoFace`)

- Se nenhum rosto é detectado por 5 segundos, o timer dispara
- O foco é aplicado no centro da tela (0.5, 0.5)
- No Android: converte para pixels do preview nativo
- No iOS: usa coordenadas normalizadas
- No modo manual, também aplica brilho

## Modos de Brilho

- **Off**: Não aplica foco nem brilho
- **Auto**: Aplica apenas o foco (sem ajustar brilho)
- **Manual**: Aplica foco e brilho com o valor configurado pelo usuário

## Feedback Visual

- **Bolinha Vermelha**: Indica onde o foco foi aplicado (dura 300ms)
- **Bolinha Azul**: Indica onde o brilho foi aplicado (dura 300ms, aparece após a vermelha desaparecer)

## Conversão de Coordenadas

O sistema precisa lidar com diferentes espaços de coordenadas:

1. **Imagem ML Kit**: Coordenadas em pixels da imagem de análise
2. **Preview Espelhado**: Coordenadas do preview visual (espelhado para câmera frontal)
3. **Preview Nativo**: Coordenadas do sensor da câmera (não espelhado)
4. **Tela**: Coordenadas da tela para renderização do feedback visual

O método `convertFromImage` do `AnalysisPreview` já faz a conversão correta da imagem ML Kit para o preview, considerando rotação e orientação. Para o Android com câmera frontal, é necessário inverter o eixo X porque:
- O preview visual está espelhado (o que você vê na tela)
- O sensor nativo não está espelhado (o que a câmera realmente vê)

## Estrutura do Código

- `_processCameraImage`: Processa cada frame e detecta rostos
- `_focusOnDetectedFace`: Aplica foco e brilho quando rosto é detectado
- `_focusOnCenterWhenNoFace`: Fallback para quando não há rosto
- `_showFocusFeedbackAt`: Exibe bolinha vermelha de feedback
- `_showBrightnessFeedbackAt`: Exibe bolinha azul de feedback
- `_normalizedToScreenPosition`: Converte coordenadas normalizadas para coordenadas da tela
