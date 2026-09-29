import 'dart:async';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

class ShiftTracker {
  final AtsSession session;
  ShiftTracker(this.session);
  final service = FlutterBackgroundService();

  Future<bool> get isActive async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getBool('shift_active') ?? false) &&
        await service.isRunning();
  }

  Future<void> start() async {
    await reconcile();
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw ApiException(
          0, 'Activa la ubicación del teléfono para iniciar el turno.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw ApiException(
          0, 'Autoriza la ubicación para compartirla durante el turno.');
    }
    await session.request('POST', '/location_tracking/start');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('pending_shift_stop');
    await prefs.setBool('shift_active', true);
    try {
      if (!await service.startService()) {
        throw ApiException(0, 'No se pudo iniciar el servicio de ubicación.');
      }
    } catch (_) {
      await prefs.setBool('shift_active', false);
      await session.request('POST', '/location_tracking/stop');
      rethrow;
    }
  }

  Future<bool> stop() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('shift_active', false);
    service.invoke('stopTracking');
    try {
      await session.request('POST', '/location_tracking/stop');
      await prefs.remove('pending_shift_stop');
      return true;
    } catch (_) {
      await prefs.setBool('pending_shift_stop', true);
      return false;
    }
  }

  Future<void> reconcile() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('pending_shift_stop') != true) return;
    try {
      await session.request('POST', '/location_tracking/stop');
      await prefs.remove('pending_shift_stop');
    } catch (_) {
      // A future app launch retries. The map hides stale coordinates meanwhile.
    }
  }
}

Future<void> configureShiftService() async {
  await FlutterBackgroundService().configure(
    androidConfiguration: AndroidConfiguration(
      onStart: trackShiftInBackground,
      autoStart: false,
      autoStartOnBoot: false,
      isForegroundMode: true,
      initialNotificationTitle: 'ATS · turno activo',
      initialNotificationContent: 'Compartiendo tu ubicación con operación',
      foregroundServiceTypes: [AndroidForegroundType.location],
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
}

@pragma('vm:entry-point')
Future<void> trackShiftInBackground(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  if (prefs.getBool('shift_active') != true) {
    service.stopSelf();
    return;
  }

  final session = AtsSession();
  await session.initialize();
  var stopped = false;
  var sending = false;
  DateTime? lastSent;
  StreamSubscription<Position>? positions;
  Timer? heartbeat;

  Future<void> stop() async {
    if (stopped) return;
    stopped = true;
    heartbeat?.cancel();
    await positions?.cancel();
    service.stopSelf();
  }

  Future<void> send(Position position) async {
    if (stopped || sending) return;
    final now = DateTime.now();
    if (lastSent != null &&
        now.difference(lastSent!) < const Duration(seconds: 20)) {
      return;
    }
    sending = true;
    try {
      await prefs.reload();
      if (prefs.getBool('shift_active') != true) {
        await stop();
        return;
      }
      await session.request('POST', '/location_tracking/position', body: {
        'position': {
          'latitude': position.latitude,
          'longitude': position.longitude,
          'accuracy_meters': position.accuracy,
          'recorded_at': position.timestamp.toUtc().toIso8601String(),
        }
      });
      lastSent = now;
    } on ApiException catch (error) {
      if (error.status == 401 || error.status == 403 || error.status == 409) {
        await prefs.setBool('shift_active', false);
        await stop();
      }
    } catch (_) {
      // A later position or heartbeat retries when connectivity returns.
    } finally {
      sending = false;
    }
  }

  service.on('stopTracking').listen((_) => stop());
  positions = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
    accuracy: LocationAccuracy.medium,
    distanceFilter: 20,
    intervalDuration: const Duration(seconds: 30),
  )).listen(send, onError: (_) {});
  heartbeat = Timer.periodic(const Duration(seconds: 75), (_) async {
    if (stopped || sending) return;
    try {
      final point = await Geolocator.getCurrentPosition(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: const Duration(seconds: 20),
        ),
      );
      await send(point);
    } catch (_) {/* GPS may be temporarily unavailable. */}
  });
}
