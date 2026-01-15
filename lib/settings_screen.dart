import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum BrightnessModeConfig { off, auto, manual }

class SettingsScreen extends StatefulWidget {
  final BrightnessModeConfig currentMode;
  final double currentOffset;
  final bool currentShowVisualFeedback;

  const SettingsScreen({
    super.key,
    required this.currentMode,
    required this.currentOffset,
    required this.currentShowVisualFeedback,
  });

  @override
  SettingsScreenState createState() => SettingsScreenState();
}

class SettingsScreenState extends State<SettingsScreen> {
  late BrightnessModeConfig _selectedMode;
  late double _offsetValue;
  late bool _showVisualFeedback;

  @override
  void initState() {
    super.initState();
    _selectedMode = widget.currentMode;
    _offsetValue = widget.currentOffset.clamp(0.0, 100.0);
    _showVisualFeedback = widget.currentShowVisualFeedback;
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('brightnessMode', _selectedMode.index);
    await prefs.setDouble('brightnessPercent', _offsetValue);
    await prefs.setBool('showVisualFeedback', _showVisualFeedback);

    if (mounted) {
      Navigator.pop(context, {
        'mode': _selectedMode,
        'offset': _offsetValue,
        'showVisualFeedback': _showVisualFeedback,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        title: Text('Configurações', style: TextStyle(color: Colors.white)),
        iconTheme: IconThemeData(color: Colors.white),
      ),
      body: ListView(
        padding: EdgeInsets.all(16),
        children: [
          Text(
            'Modo de Brilho',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 16),

          // Opção Off
          RadioListTile<BrightnessModeConfig>(
            title: Text(
              'Desligado',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              'Não ajusta brilho automaticamente',
              style: TextStyle(color: Colors.grey),
            ),
            value: BrightnessModeConfig.off,
            groupValue: _selectedMode,
            activeColor: Colors.blue,
            onChanged: (value) {
              setState(() {
                _selectedMode = value!;
              });
            },
          ),

          // Opção Auto
          RadioListTile<BrightnessModeConfig>(
            title: Text(
              'Automático (Recomendado)',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              'Ajuste automático da câmera apenas',
              style: TextStyle(color: Colors.grey),
            ),
            value: BrightnessModeConfig.auto,
            groupValue: _selectedMode,
            activeColor: Colors.blue,
            onChanged: (value) {
              setState(() {
                _selectedMode = value!;
              });
            },
          ),

          // Opção Manual
          RadioListTile<BrightnessModeConfig>(
            title: Text('Manual', style: TextStyle(color: Colors.white)),
            subtitle: Text(
              'Ajuste automático + brilho configurável',
              style: TextStyle(color: Colors.grey),
            ),
            value: BrightnessModeConfig.manual,
            groupValue: _selectedMode,
            activeColor: Colors.blue,
            onChanged: (value) {
              setState(() {
                _selectedMode = value!;
              });
            },
          ),

          // Slider para brilho (só aparece se Manual estiver selecionado)
          if (_selectedMode == BrightnessModeConfig.manual) ...[
            SizedBox(height: 32),
            Text(
              'Brilho: ${_offsetValue.toStringAsFixed(0)}%',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 8),
            Slider(
              value: _offsetValue,
              min: 0.0,
              max: 100.0,
              label: '${_offsetValue.toStringAsFixed(0)}%',
              activeColor: Colors.blue,
              onChanged: (value) {
                setState(() {
                  // Efeito de "snap" no 50: se estiver entre 45 e 55, gruda no 50
                  const snapZone = 5.0; // Zona de tolerância de 5% de cada lado
                  const snapValue = 50.0;
                  if ((value - snapValue).abs() <= snapZone) {
                    _offsetValue = snapValue;
                  } else {
                    _offsetValue = value;
                  }
                });
              },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('0% (Escuro)', style: TextStyle(color: Colors.grey)),
                Text('50%', style: TextStyle(color: Colors.grey)),
                Text('100% (Claro)', style: TextStyle(color: Colors.grey)),
              ],
            ),
          ],

          SizedBox(height: 32),
          Text(
            'Feedback Visual',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 16),
          SwitchListTile(
            title: Text(
              'Exibir feedback visual',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              'Mostra bolinhas de foco/brilho e contornos da face',
              style: TextStyle(color: Colors.grey),
            ),
            value: _showVisualFeedback,
            activeColor: Colors.blue,
            onChanged: (value) {
              setState(() {
                _showVisualFeedback = value;
              });
            },
          ),

          SizedBox(height: 32),
          ElevatedButton(
            onPressed: _saveSettings,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              padding: EdgeInsets.symmetric(vertical: 16),
            ),
            child: Text('Salvar', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
  }
}
