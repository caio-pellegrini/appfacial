import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ExposureModeConfig { off, auto, manual }

enum AppOrientation { portrait, landscape }

class SettingsScreen extends StatefulWidget {
  final ExposureModeConfig currentMode;
  final double currentOffset;
  final AppOrientation currentOrientation;

  const SettingsScreen({
    Key? key,
    required this.currentMode,
    required this.currentOffset,
    required this.currentOrientation,
  }) : super(key: key);

  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late ExposureModeConfig _selectedMode;
  late double _offsetValue;
  late AppOrientation _selectedOrientation;

  @override
  void initState() {
    super.initState();
    _selectedMode = widget.currentMode;
    _offsetValue = widget.currentOffset;
    _selectedOrientation = widget.currentOrientation;
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('exposureMode', _selectedMode.index);
    await prefs.setDouble('exposureOffset', _offsetValue);
    await prefs.setInt('appOrientation', _selectedOrientation.index);

    if (mounted) {
      Navigator.pop(context, {
        'mode': _selectedMode,
        'offset': _offsetValue,
        'orientation': _selectedOrientation,
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
            'Modo de Exposição',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 16),

          // Opção Off
          RadioListTile<ExposureModeConfig>(
            title: Text(
              'Desligado (Off)',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              'Não ajusta exposição automaticamente',
              style: TextStyle(color: Colors.grey),
            ),
            value: ExposureModeConfig.off,
            groupValue: _selectedMode,
            activeColor: Colors.blue,
            onChanged: (value) {
              setState(() {
                _selectedMode = value!;
              });
            },
          ),

          // Opção Auto
          RadioListTile<ExposureModeConfig>(
            title: Text(
              'Automático (Auto)',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              'Ajuste automático da câmera apenas',
              style: TextStyle(color: Colors.grey),
            ),
            value: ExposureModeConfig.auto,
            groupValue: _selectedMode,
            activeColor: Colors.blue,
            onChanged: (value) {
              setState(() {
                _selectedMode = value!;
              });
            },
          ),

          // Opção Manual
          RadioListTile<ExposureModeConfig>(
            title: Text('Manual', style: TextStyle(color: Colors.white)),
            subtitle: Text(
              'Ajuste automático + offset configurável',
              style: TextStyle(color: Colors.grey),
            ),
            value: ExposureModeConfig.manual,
            groupValue: _selectedMode,
            activeColor: Colors.blue,
            onChanged: (value) {
              setState(() {
                _selectedMode = value!;
              });
            },
          ),

          // Slider para offset (só aparece se Manual estiver selecionado)
          if (_selectedMode == ExposureModeConfig.manual) ...[
            SizedBox(height: 32),
            Text(
              'Offset de Exposição: ${_offsetValue.toStringAsFixed(1)} EV',
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
              max: 2.0,
              divisions: 20,
              label: '${_offsetValue.toStringAsFixed(1)} EV',
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
                Text('0.0', style: TextStyle(color: Colors.grey)),
                Text('2.0', style: TextStyle(color: Colors.grey)),
              ],
            ),
          ],

          SizedBox(height: 32),
          Divider(color: Colors.grey[800], height: 1),
          SizedBox(height: 32),
          Text(
            'Orientação',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 16),

          // Opção Portrait
          RadioListTile<AppOrientation>(
            title: Text(
              'Retrato (Portrait)',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              'Orientação vertical',
              style: TextStyle(color: Colors.grey),
            ),
            value: AppOrientation.portrait,
            groupValue: _selectedOrientation,
            activeColor: Colors.blue,
            onChanged: (value) {
              setState(() {
                _selectedOrientation = value!;
              });
            },
          ),

          // Opção Landscape
          RadioListTile<AppOrientation>(
            title: Text(
              'Paisagem (Landscape)',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              'Orientação horizontal',
              style: TextStyle(color: Colors.grey),
            ),
            value: AppOrientation.landscape,
            groupValue: _selectedOrientation,
            activeColor: Colors.blue,
            onChanged: (value) {
              setState(() {
                _selectedOrientation = value!;
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
