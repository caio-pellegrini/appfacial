import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum BrightnessModeConfig { off, auto, manual }

class SettingsScreen extends StatefulWidget {
  final BrightnessModeConfig currentMode;
  final double currentOffset;
  final int currentCameraRotate;

  const SettingsScreen({
    Key? key,
    required this.currentMode,
    required this.currentOffset,
    required this.currentCameraRotate,
  }) : super(key: key);

  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late BrightnessModeConfig _selectedMode;
  late double _offsetValue;
  late int _cameraRotate;

  @override
  void initState() {
    super.initState();
    _selectedMode = widget.currentMode;
    _offsetValue = widget.currentOffset;
    _cameraRotate = widget.currentCameraRotate.clamp(0, 3);
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('brightnessMode', _selectedMode.index);
    await prefs.setDouble('brightnessPercent', _offsetValue);
    await prefs.setInt('cameraRotate', _cameraRotate);

    if (mounted) {
      Navigator.pop(context, {
        'mode': _selectedMode,
        'offset': _offsetValue,
        'cameraRotate': _cameraRotate,
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
              'Desligado (Off)',
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
              'Automático (Auto)',
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
              min: -100.0,
              max: 100.0,
              divisions: 20, // Step de 10%: (-100 a +100) / 20 = 10
              label: '${_offsetValue.toStringAsFixed(0)}%',
              activeColor: Colors.blue,
              onChanged: (value) {
                setState(() {
                  _offsetValue = value;
                });
              },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('-100% (Escuro)', style: TextStyle(color: Colors.grey)),
                Text('0%', style: TextStyle(color: Colors.grey)),
                Text('+100% (Claro)', style: TextStyle(color: Colors.grey)),
              ],
            ),
          ],

          SizedBox(height: 32),
          Divider(color: Colors.grey[800], height: 1),
          SizedBox(height: 32),
          Text(
            'Rotação da Câmera',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 16),
          Text(
            'Selecione a rotação da câmera (em incrementos de 90°)',
            style: TextStyle(
              color: Colors.grey,
              fontSize: 14,
            ),
          ),
          SizedBox(height: 16),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey[700]!),
            ),
            child: DropdownButton<int>(
              value: _cameraRotate,
              isExpanded: true,
              dropdownColor: Colors.grey[900],
              style: TextStyle(color: Colors.white),
              underline: SizedBox(),
              items: [
                DropdownMenuItem<int>(
                  value: 0,
                  child: Text('0°'),
                ),
                DropdownMenuItem<int>(
                  value: 1,
                  child: Text('90°'),
                ),
                DropdownMenuItem<int>(
                  value: 2,
                  child: Text('180°'),
                ),
                DropdownMenuItem<int>(
                  value: 3,
                  child: Text('270°'),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _cameraRotate = value;
                  });
                }
              },
            ),
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
