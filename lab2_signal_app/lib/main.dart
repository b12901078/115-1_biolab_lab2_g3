import 'dart:async';
import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EMG BLE Test',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const BleTestPage(),
    );
  }
}

class BleTestPage extends StatefulWidget {
  const BleTestPage({super.key});

  @override
  State<BleTestPage> createState() => _BleTestPageState();
}

class _BleTestPageState extends State<BleTestPage> {
  BluetoothDevice? device;
  BluetoothCharacteristic? emgCharacteristic;
  StreamSubscription<List<int>>? dataSubscription;

  String status = '尚未連線';
  String receivedData = '等待資料...';
  String rawData = '-';

  double? emgValue;
  String receiveBuffer = '';
  bool isBusy = false;

  // 波形圖設定
  static const double displayWindowSeconds = 5.0;
  static const int maxStoredPoints = 3000;

  final Stopwatch _clock = Stopwatch();
  final List<FlSpot> _emgPoints = [];
  Timer? _chartTimer;

  bool isPlotting = true;
  int totalSamples = 0;

  @override
  void initState() {
    super.initState();
    _clock.start();

    // 固定刷新頻率，避免每收到一筆 BLE 資料就重建整個畫面。
    _chartTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted || !isPlotting) return;

      final now = _clock.elapsedMilliseconds / 1000.0;
      final cutoff = now - displayWindowSeconds;

      // 移除已經超出畫面時間範圍的資料。
      _emgPoints.removeWhere((point) => point.x < cutoff);

      setState(() {});
    });
  }

  // 開始掃描並連線
  Future<void> scanAndConnect() async {
    if (isBusy) return;

    setState(() {
      isBusy = true;
      status = '正在掃描 BLE 裝置...';
      receivedData = '等待資料...';
      rawData = '-';
      emgValue = null;
      receiveBuffer = '';
    });

    try {
      if (!await FlutterBluePlus.isSupported) {
        throw Exception('此裝置不支援 BLE');
      }

      await FlutterBluePlus.adapterState
          .where((state) => state == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 15));

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 8),
      );

      await FlutterBluePlus.isScanning
          .where((scanning) => !scanning)
          .first
          .timeout(const Duration(seconds: 12));

      final results = FlutterBluePlus.lastScanResults;
      ScanResult? target;

      for (final result in results) {
        final name = result.advertisementData.advName.isNotEmpty
            ? result.advertisementData.advName
            : result.device.platformName;

        if (name.toLowerCase().contains('hmsoft')) {
          target = result;
          break;
        }
      }

      if (target == null) {
        throw Exception('找不到 HMSoft，請確認模組已開機並正在廣播');
      }

      device = target.device;

      if (mounted) {
        setState(() {
          status = '找到 HMSoft，正在連線...';
        });
      }

      await device!.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
      );

      final services = await device!.discoverServices();
      BluetoothCharacteristic? foundCharacteristic;

      for (final service in services) {
        if (service.serviceUuid == Guid('FFE0')) {
          for (final characteristic in service.characteristics) {
            if (characteristic.characteristicUuid == Guid('FFE1')) {
              foundCharacteristic = characteristic;
              break;
            }
          }
        }

        if (foundCharacteristic != null) break;
      }

      if (foundCharacteristic == null) {
        throw Exception('找不到 FFE0 Service 或 FFE1 Characteristic');
      }

      if (!foundCharacteristic.properties.notify) {
        throw Exception('FFE1 不支援 Notification');
      }

      emgCharacteristic = foundCharacteristic;

      // 先監聽資料，再啟用 Notification
      dataSubscription = emgCharacteristic!.onValueReceived.listen(
        handleReceivedData,
        onError: (Object error) {
          if (!mounted) return;
          setState(() {
            status = '資料接收錯誤：$error';
          });
        },
      );

      await emgCharacteristic!.setNotifyValue(true);

      if (mounted) {
        setState(() {
          status = '已連線，正在接收 EMG 資料';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          status = '錯誤：$e';
        });
      }

      debugPrint('BLE error: $e');
    } finally {
      if (mounted) {
        setState(() {
          isBusy = false;
        });
      }
    }
  }

  // 處理 BLE 收到的位元組資料。
  // 一個 BLE notification 可能只有半行，也可能同時包含多行，
  // 因此不能假設每個 notification 就是一筆 EMG 數值。
  void handleReceivedData(List<int> value) {
    if (value.isEmpty) return;

    final hex = value
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join(' ')
        .toUpperCase();

    final text = ascii.decode(value, allowInvalid: true);

    debugPrint('Received HEX: $hex');
    debugPrint('Received TEXT: $text');

    receiveBuffer += text;

    // 避免異常資料沒有換行時，buffer 無限制增長。
    if (receiveBuffer.length > 4096 && !receiveBuffer.contains('\n')) {
      receiveBuffer = receiveBuffer.substring(receiveBuffer.length - 512);
    }

    bool gotValidSample = false;

    while (receiveBuffer.contains('\n')) {
      final newlineIndex = receiveBuffer.indexOf('\n');
      final line = receiveBuffer.substring(0, newlineIndex).trim();
      receiveBuffer = receiveBuffer.substring(newlineIndex + 1);

      if (line.isEmpty) continue;

      // 同時接受「512」與「EMG:512」兩種 Arduino 輸出格式。
      final match = RegExp(
        r'^(?:EMG:\s*)?(-?\d+(?:\.\d+)?)$',
        caseSensitive: false,
      ).firstMatch(line);

      if (match == null) {
        debugPrint('無法解析的資料行：$line');
        continue;
      }

      final parsedValue = double.tryParse(match.group(1)!);
      if (parsedValue == null) continue;

      emgValue = parsedValue;
      receivedData = line;
      rawData = hex;
      totalSamples++;

      if (isPlotting) {
        final timeSeconds = _clock.elapsedMilliseconds / 1000.0;
        _emgPoints.add(FlSpot(timeSeconds, parsedValue));

        if (_emgPoints.length > maxStoredPoints) {
          _emgPoints.removeRange(
            0,
            _emgPoints.length - maxStoredPoints,
          );
        }
      }

      gotValidSample = true;
    }

    // 數值顯示也使用節流刷新；圖表則由 50 ms timer 更新。
    if (gotValidSample && mounted) {
      setState(() {});
    }
  }

  // 中斷連線
  Future<void> disconnectDevice() async {
    await dataSubscription?.cancel();
    dataSubscription = null;

    final currentDevice = device;
    emgCharacteristic = null;
    device = null;

    if (currentDevice != null) {
      await currentDevice.disconnect();
    }

    if (mounted) {
      setState(() {
        status = '已中斷連線';
        receivedData = '等待資料...';
        emgValue = null;
        receiveBuffer = '';
      });
    }
  }

  void clearWaveform() {
    setState(() {
      _emgPoints.clear();
      totalSamples = 0;
    });
  }

  @override
  void dispose() {
    _chartTimer?.cancel();
    dataSubscription?.cancel();
    device?.disconnect();
    _clock.stop();
    super.dispose();
  }

  Widget _buildWaveformChart() {
    final now = _clock.elapsedMilliseconds / 1000.0;
    final minX = (now - displayWindowSeconds).clamp(0.0, double.infinity);

    return SizedBox(
      height: 270,
      child: _emgPoints.isEmpty
          ? const Center(
              child: Text(
                '等待 EMG 資料...',
                style: TextStyle(color: Colors.grey, fontSize: 16),
              ),
            )
          : LineChart(
              LineChartData(
                minX: minX,
                maxX: now < displayWindowSeconds
                    ? displayWindowSeconds
                    : now,
                minY: 0,
                maxY: 1023,
                clipData: const FlClipData.all(),
                gridData: FlGridData(
                  show: true,
                  horizontalInterval: 256,
                  verticalInterval: 1,
                ),
                borderData: FlBorderData(show: true),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  leftTitles: AxisTitles(
                    axisNameWidget: const Text('ADC'),
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 42,
                      interval: 256,
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    axisNameWidget: const Text('時間（秒）'),
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      interval: 1,
                      getTitlesWidget: (value, meta) {
                        return SideTitleWidget(
                          axisSide: meta.axisSide,
                          child: Text(
                            value.toStringAsFixed(0),
                            style: const TextStyle(fontSize: 10),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                lineTouchData: const LineTouchData(enabled: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: List<FlSpot>.of(_emgPoints),
                    isCurved: false,
                    barWidth: 1.5,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(show: false),
                  ),
                ],
              ),
              duration: Duration.zero,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('即時生理訊號監測'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '連線狀態：$status',
                style: const TextStyle(fontSize: 15),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: isBusy || device != null ? null : scanAndConnect,
                child: Text(isBusy ? '處理中...' : '掃描並連線 HM-10'),
              ),
              OutlinedButton(
                onPressed: device == null ? null : disconnectDevice,
                child: const Text('中斷連線'),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            '即時波形',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            '最近 ${displayWindowSeconds.toInt()} 秒',
                            style: const TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _buildWaveformChart(),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.tonal(
                            onPressed: () {
                              setState(() {
                                isPlotting = !isPlotting;
                              });
                            },
                            child: Text(isPlotting ? '暫停繪圖' : '繼續繪圖'),
                          ),
                          OutlinedButton(
                            onPressed: clearWaveform,
                            child: const Text('清除波形'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '目前訊號數值',
                        style: TextStyle(fontSize: 16),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        emgValue?.toStringAsFixed(0) ?? '--',
                        style: const TextStyle(
                          fontSize: 38,
                          fontWeight: FontWeight.bold,
                        ),
                      )//,
                      //const SizedBox(height: 8),
                      //Text('最近收到的資料：$receivedData'),
                      //Text('累積接收筆數：$totalSamples'),
                      //const SizedBox(height: 8),
                      //const Text('最近一次收到的原始 Hex：'),
                      //SelectableText(rawData),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
