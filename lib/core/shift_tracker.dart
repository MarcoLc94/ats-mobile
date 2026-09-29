import 'dart:async';
import 'dart:math' as math;
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
  var liveTracking = false;
  var idle = false;
  var unchangedReports = 0;
  DateTime? lastSent;
  Position? movementAnchor;
  StreamSubscription<Position>? positions;
  Timer? heartbeat;
  late Future<void> Function(Position, bool) send;

  bool movedSinceLastReport(Position position) {
    final previous = movementAnchor;
    if (previous == null) return true;
    final distance = Geolocator.distanceBetween(previous.latitude,
        previous.longitude, position.latitude, position.longitude);
    // GPS jitter is not movement: compare against the reported accuracy.
    final threshold = math.max(
        20.0, math.min(100.0, math.max(previous.accuracy, position.accuracy)));
    return distance >= threshold;
  }

  Future<void> configurePositionStream() async {
    await positions?.cancel();
    if (stopped) return;
    final interval = liveTracking && !idle
        ? 5
        : liveTracking
            ? 15
            : 60;
    final distance = liveTracking && !idle
        ? 0
        : liveTracking
            ? 20
            : 50;
    positions = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.medium,
        distanceFilter: distance,
        intervalDuration: Duration(seconds: interval),
      ),
    ).listen((position) => send(position, false), onError: (_) {});
  }

  Future<void> stop() async {
    if (stopped) return;
    stopped = true;
    heartbeat?.cancel();
    await positions?.cancel();
    service.stopSelf();
  }

  send = (Position position, bool heartbeatReport) async {
    if (stopped || sending) return;
    final now = DateTime.now();
    final moved = movedSinceLastReport(position);
    if (liveTracking && idle && moved) {
      idle = false;
      unchangedReports = 0;
      await configurePositionStream();
    }
    if (liveTracking && idle && !moved && !heartbeatReport) return;
    final minimumInterval = liveTracking && !idle ? 5 : 60;
    if (lastSent != null &&
        now.difference(lastSent!) < Duration(seconds: minimumInterval)) {
      return;
    }
    sending = true;
    try {
      await prefs.reload();
      if (prefs.getBool('shift_active') != true) {
        await stop();
        return;
      }
      final response = asMap(
          await session.request('POST', '/location_tracking/position', body: {
        'position': {
          'latitude': position.latitude,
          'longitude': position.longitude,
          'accuracy_meters': position.accuracy,
          'recorded_at': position.timestamp.toUtc().toIso8601String(),
        }
      }));
      lastSent = now;
      if (response['live_tracking'] == true) {
        if (!liveTracking) {
          liveTracking = true;
          idle = false;
          unchangedReports = 0;
          await configurePositionStream();
        } else if (!idle) {
          unchangedReports = moved ? 0 : unchangedReports + 1;
          if (unchangedReports >= 3) {
            idle = true;
            await configurePositionStream();
          }
        }
      } else if (liveTracking) {
        liveTracking = false;
        idle = false;
        unchangedReports = 0;
        await configurePositionStream();
      }
      if (moved) movementAnchor = position;
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
  };

  service.on('stopTracking').listen((_) => stop());
  await configurePositionStream();
  heartbeat = Timer.periodic(const Duration(seconds: 90), (_) async {
    if (stopped || sending) return;
    if (liveTracking &&
        !idle &&
        lastSent != null &&
        DateTime.now().difference(lastSent!) < const Duration(seconds: 90)) {
      return;
    }
    try {
      final point = await Geolocator.getCurrentPosition(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: const Duration(seconds: 20),
        ),
      );
      await send(point, true);
    } catch (_) {/* GPS may be temporarily unavailable. */}
  });
}
