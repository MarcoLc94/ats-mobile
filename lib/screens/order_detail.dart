import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../core/api.dart';

const checklist = <String, String>{
  'air_filter_cleaning': 'Limpieza de filtro de aire',
  'cabin_filter_cleaning': 'Limpieza de filtro de cabina',
  'oil_cooler_cleaning': 'Limpieza de enfriador de aceite',
  'air_cooler_cleaning': 'Limpieza de enfriador de aire',
  'electrical_panel_cleaning': 'Limpieza de tablero eléctrico',
  'electrical_connections_check': 'Revisión de conexiones eléctricas',
  'oil_level_check': 'Revisión de nivel de aceite',
  'leak_inspection': 'Inspección de fugas',
  'general_cleaning': 'Limpieza general',
  'oil_top_up': 'Relleno de aceite',
  'air_filter_replacement': 'Cambio de filtro de aire',
  'oil_filter_replacement': 'Cambio de filtro de aceite',
  'separator_filter_replacement': 'Cambio de filtro separador',
  'blow_off': 'Soplado',
  'blow_down': 'Purga',
  'intake_valve_function_check': 'Revisión de válvula de admisión',
  'minimum_pressure_valve_cleaning': 'Limpieza de válvula de presión mínima',
  'aftercooler_radiator_cleaning': 'Limpieza de radiador',
  'load_unload_valve_check': 'Revisión de carga y descarga',
  'intake_valve_replacement': 'Cambio de válvula de admisión',
  'minimum_pressure_valve_replacement': 'Cambio de válvula de presión mínima',
  'thermostatic_valve_replacement': 'Cambio de válvula termostática',
};

const readings = <String, String>{
  'pos_cooler': 'Posición de enfriador',
  'oil_temp': 'Temperatura del aceite',
  'air_pressure': 'Presión de aire',
  'hourmeter': 'Horómetro',
  'oil_liters': 'Litros de aceite',
  'bucket_count': 'Cantidad de cubetas',
  'oil_type': 'Tipo de aceite',
};

class OrderDetailScreen extends StatefulWidget {
  final AtsSession session;
  final int orderId;
  const OrderDetailScreen(
      {super.key, required this.session, required this.orderId});
  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  Map<String, dynamic>? order;
  Map<String, dynamic> draft = {};
  final controllers = <String, TextEditingController>{};
  List<XFile> photos = [];
  File? technicianSignature;
  File? clientSignature;
  bool busy = false;
  bool cached = false;
  String? error;

  String get draftKey => 'order-draft:${widget.orderId}';
  String get orderKey => 'order:${widget.orderId}';
  bool get editable =>
      order?['status'] == 'open' &&
      order?['needs_review'] != true &&
      order?['accepted_at'] != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = asMap(await widget.session
          .request('GET', '/service_orders/${widget.orderId}'));
      await widget.session.saveCache(orderKey, result);
      order = result;
      cached = false;
    } catch (e) {
      error = e.toString();
      final local = await widget.session.readCache(orderKey);
      if (local != null) {
        order = asMap(local);
        cached = true;
      }
    }
    final localDraft = await widget.session.readCache(draftKey);
    draft = localDraft == null ? {} : asMap(localDraft);
    _populateControllers();
    if (mounted) setState(() => busy = false);
  }

  void _populateControllers() {
    for (final item in {...readings, 'comments': 'Comentarios'}.keys) {
      final value = draft.containsKey(item) ? draft[item] : order?[item];
      (controllers[item] ??= TextEditingController()).text =
          value?.toString() ?? '';
    }
    final savedPhotos = draft['_photos'];
    photos = savedPhotos is List
        ? savedPhotos
            .whereType<String>()
            .where((path) => File(path).existsSync())
            .map(XFile.new)
            .toList()
        : [];
    final technicianPath = draft['_technician_signature'];
    final clientPath = draft['_client_signature'];
    technicianSignature =
        technicianPath is String && File(technicianPath).existsSync()
            ? File(technicianPath)
            : null;
    clientSignature = clientPath is String && File(clientPath).existsSync()
        ? File(clientPath)
        : null;
  }

  Future<Directory> _draftDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/ats-order-drafts/${widget.orderId}')
      ..createSync(recursive: true);
  }

  void _change(String field, dynamic value) {
    draft[field] = value;
    widget.session.saveCache(draftKey, draft);
    setState(() {});
  }

  Future<File?> _captureSignature(String title) async {
    final points = <Offset?>[];
    final boundaryKey = GlobalKey();
    return showDialog<File>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                title: Text(title),
                content: SizedBox(
                    width: math.min(
                        360, MediaQuery.sizeOf(dialogContext).width - 100),
                    height: 215,
                    child: Column(children: [
                      const Text('Firma dentro del recuadro'),
                      const SizedBox(height: 8),
                      Expanded(
                          child: RepaintBoundary(
                              key: boundaryKey,
                              child: GestureDetector(
                                onPanStart: (details) => update(
                                    () => points.add(details.localPosition)),
                                onPanUpdate: (details) => update(
                                    () => points.add(details.localPosition)),
                                onPanEnd: (_) => update(() => points.add(null)),
                                child: Container(
                                    color: Colors.white,
                                    child: CustomPaint(
                                      painter: _SignaturePainter(points),
                                      child: const SizedBox.expand(),
                                    )),
                              ))),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => update(points.clear),
                      child: const Text('Borrar')),
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Cancelar')),
                  FilledButton(
                      onPressed: points.length < 3
                          ? null
                          : () async {
                              final boundary =
                                  boundaryKey.currentContext?.findRenderObject()
                                      as RenderRepaintBoundary?;
                              if (boundary == null) return;
                              final image =
                                  await boundary.toImage(pixelRatio: 2.5);
                              final bytes = await image.toByteData(
                                  format: ui.ImageByteFormat.png);
                              if (bytes == null) return;
                              final folder = await _draftDirectory();
                              final file = File(
                                  '${folder.path}/sign-${DateTime.now().microsecondsSinceEpoch}.png');
                              await file.writeAsBytes(
                                  bytes.buffer.asUint8List(),
                                  flush: true);
                              if (dialogContext.mounted) {
                                Navigator.pop(dialogContext, file);
                              }
                            },
                      child: const Text('Guardar firma')),
                ],
              ),
            ));
  }

  Future<void> _pickPhotos() async {
    try {
      final picked =
          await ImagePicker().pickMultiImage(imageQuality: 80, maxWidth: 1800);
      final existing = (order?['service_photos'] as List?)?.length ?? 0;
      if (existing + photos.length + picked.length > 10) {
        throw ApiException(0, 'Se permiten hasta 10 fotos por orden.');
      }
      for (final photo in picked) {
        await _addPhoto(photo);
      }
    } catch (e) {
      if (mounted) _message(e.toString());
    }
  }

  Future<void> _addPhoto(XFile photo) async {
    try {
      final existing = (order?['service_photos'] as List?)?.length ?? 0;
      if (existing + photos.length >= 10) {
        throw ApiException(0, 'Se permiten hasta 10 fotos por orden.');
      }
      if (await photo.length() > 15 * 1024 * 1024) {
        throw ApiException(0, 'Cada foto debe medir menos de 15 MB.');
      }
      final extension = photo.path.split('.').last.toLowerCase();
      if (!['jpg', 'jpeg', 'png', 'webp'].contains(extension)) {
        throw ApiException(0, 'Solo se aceptan fotos JPG, PNG o WebP.');
      }
      final folder = await _draftDirectory();
      final local = await File(photo.path).copy(
          '${folder.path}/photo-${DateTime.now().microsecondsSinceEpoch}-${photos.length}.$extension');
      photos.add(XFile(local.path));
      _change('_photos', photos.map((e) => e.path).toList());
    } catch (e) {
      if (mounted) _message(e.toString());
    }
  }

  void _message(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  Future<bool> _save() async {
    if (order == null || !editable) return false;
    setState(() => busy = true);
    try {
      final fields = <String, String>{
        'lock_version': '${order!['lock_version']}'
      };
      for (final field in checklist.keys) {
        if (draft.containsKey(field)) {
          fields[field] = draft[field] == true ? 'true' : 'false';
        }
      }
      for (final field in [...readings.keys, 'comments']) {
        final value = controllers[field]?.text.trim() ?? '';
        if (value.isNotEmpty || draft.containsKey(field)) fields[field] = value;
      }
      final result = asMap(await widget.session.uploadOrder(
          widget.orderId, fields,
          technicianSignature: technicianSignature,
          clientSignature: clientSignature,
          photos: photos.map((e) => File(e.path)).toList()));
      order = result;
      await widget.session.saveCache(orderKey, result);
      draft.clear();
      await widget.session.saveCache(draftKey, draft);
      final folder = await _draftDirectory();
      if (await folder.exists()) await folder.delete(recursive: true);
      technicianSignature = null;
      clientSignature = null;
      photos = [];
      if (mounted) _message('Orden guardada.');
      return true;
    } on ApiException catch (e) {
      if (mounted) {
        _message(e.status == 409
            ? 'La orden cambió en el servidor. Tu borrador se conserva; revisa la versión nueva antes de guardar.'
            : e.message);
      }
      return false;
    } catch (e) {
      if (mounted) _message('No se pudo guardar. Tu borrador se conserva: $e');
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _complete() async {
    if (!await _save()) return;
    if (!mounted) return;
    final hasTechnician = order?['technician_signature_url'] != null;
    final hasClient = order?['client_signature_url'] != null;
    if (!hasTechnician || !hasClient) {
      _message('Se requieren las firmas del técnico y del cliente.');
      return;
    }
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Completar orden'),
              content: const Text('Al completarla ya no podrás editarla.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Volver')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Completar'))
              ],
            ));
    if (confirmed != true) return;
    setState(() => busy = true);
    try {
      final result = asMap(await widget.session.request(
          'POST', '/service_orders/${widget.orderId}/complete',
          body: {'lock_version': order!['lock_version']}));
      order = result;
      await widget.session.saveCache(orderKey, result);
      if (mounted) _message('Orden completada.');
    } catch (e) {
      if (mounted) _message(e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _accept() async {
    if (busy || cached) return;
    setState(() => busy = true);
    try {
      final result = asMap(await widget.session
          .request('POST', '/service_orders/${widget.orderId}/accept'));
      order = result;
      await widget.session.saveCache(orderKey, result);
      if (mounted) _message('Orden aceptada. Ya puedes registrar el servicio.');
    } catch (e) {
      if (mounted) _message(e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = order;
    return Scaffold(
      appBar: AppBar(
          title: Text(item?['folio']?.toString() ?? 'Orden #${widget.orderId}'),
          actions: [
            IconButton(
                onPressed: busy ? null : _load, icon: const Icon(Icons.refresh))
          ]),
      body: item == null
          ? Center(
              child: busy
                  ? const CircularProgressIndicator()
                  : Text(error ?? 'No se pudo cargar la orden.'))
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (cached)
                const Card(
                    child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                            'Sin conexión: se muestra la última copia guardada. El borrador se conserva localmente.'))),
              if (error != null && !cached)
                Text(error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                asMap(item['client'])['name']?.toString() ??
                                    'Cliente',
                                style: Theme.of(context).textTheme.titleLarge),
                            Text(
                                '${asMap(item['equipment'])['name'] ?? 'Equipo'} · ${asMap(item['equipment'])['serial_number'] ?? 'Sin serie'}'),
                            Text(
                                '${item['service_type'] == 'preventive' ? 'Preventivo' : item['service_type'] == 'corrective' ? 'Correctivo' : item['service_type']} · ${item['status']}'),
                            if (item['start_date'] != null)
                              Text('Fecha: ${item['start_date']}'),
                          ]))),
              const SizedBox(height: 14),
              _OrderTimingCard(order: item),
              if (item['status'] == 'open' && item['accepted_at'] == null) ...[
                const SizedBox(height: 8),
                FilledButton.icon(
                    onPressed: busy || cached ? null : _accept,
                    icon: const Icon(Icons.task_alt),
                    label: const Text('Aceptar orden de servicio')),
                const SizedBox(height: 8),
              ],
              Text('Checklist', style: Theme.of(context).textTheme.titleLarge),
              ...checklist.entries.map((entry) => CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(entry.value),
                    value: draft[entry.key] == true ||
                        (draft[entry.key] == null && item[entry.key] == true),
                    onChanged: editable
                        ? (value) => _change(entry.key, value == true)
                        : null,
                  )),
              const SizedBox(height: 12),
              Text('Lecturas y notas',
                  style: Theme.of(context).textTheme.titleLarge),
              ...{
                ...readings,
                'comments': 'Comentarios'
              }.entries.map((entry) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: TextField(
                    controller: controllers[entry.key],
                    enabled: editable,
                    maxLines: entry.key == 'comments' ? 4 : 1,
                    keyboardType: entry.key == 'comments' ||
                            entry.key == 'oil_type'
                        ? TextInputType.text
                        : const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                        labelText: entry.value,
                        border: const OutlineInputBorder()),
                    onChanged: (value) => _change(entry.key, value),
                  ))),
              if (editable) ...[
                const SizedBox(height: 12),
                Text('Evidencia',
                    style: Theme.of(context).textTheme.titleLarge),
                OutlinedButton.icon(
                    onPressed: _pickPhotos,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: Text('Elegir fotos (${photos.length}/10)')),
                OutlinedButton.icon(
                    onPressed: () async {
                      final shot = await ImagePicker().pickImage(
                          source: ImageSource.camera,
                          imageQuality: 80,
                          maxWidth: 1800);
                      if (shot != null) await _addPhoto(shot);
                    },
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('Tomar foto')),
                if (item['service_photos'] is List)
                  Text(
                      'Fotos guardadas: ${(item['service_photos'] as List).length}'),
                ...photos.map((photo) => ListTile(
                      leading: const Icon(Icons.image_outlined),
                      title: Text(photo.name),
                      trailing: IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Quitar foto',
                          onPressed: () async {
                            photos.remove(photo);
                            await File(photo.path).delete();
                            _change(
                                '_photos', photos.map((e) => e.path).toList());
                          }),
                    )),
                OutlinedButton.icon(
                    onPressed: () async {
                      final file = await _captureSignature('Firma del técnico');
                      if (file != null) {
                        technicianSignature = file;
                        _change('_technician_signature', file.path);
                      }
                    },
                    icon: const Icon(Icons.draw),
                    label: Text(technicianSignature != null ||
                            item['technician_signature_url'] != null
                        ? 'Cambiar firma del técnico'
                        : 'Firmar como técnico')),
                if (technicianSignature != null)
                  Image.file(technicianSignature!, height: 70),
                OutlinedButton.icon(
                    onPressed: () async {
                      final file = await _captureSignature('Firma del cliente');
                      if (file != null) {
                        clientSignature = file;
                        _change('_client_signature', file.path);
                      }
                    },
                    icon: const Icon(Icons.draw),
                    label: Text(clientSignature != null ||
                            item['client_signature_url'] != null
                        ? 'Cambiar firma del cliente'
                        : 'Solicitar firma del cliente')),
                if (clientSignature != null)
                  Image.file(clientSignature!, height: 70),
                const SizedBox(height: 10),
                FilledButton.icon(
                    onPressed: busy || cached ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Guardar avance')),
                FilledButton.tonalIcon(
                    onPressed: busy || cached ? null : _complete,
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Completar orden')),
              ] else if (item['status'] == 'completed')
                const ListTile(
                    leading: Icon(Icons.check_circle),
                    title: Text('Orden completada')),
              if (busy)
                const Center(
                    child: Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator())),
            ]),
    );
  }
}

class _OrderTimingCard extends StatefulWidget {
  final Map<String, dynamic> order;
  const _OrderTimingCard({required this.order});

  @override
  State<_OrderTimingCard> createState() => _OrderTimingCardState();
}

class _OrderTimingCardState extends State<_OrderTimingCard> {
  Timer? timer;

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.order['status'] == 'open') setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  String duration(String field) {
    final start = DateTime.tryParse(widget.order[field]?.toString() ?? '');
    if (start == null) return '—';
    final status = widget.order['status'];
    final endValue = status == 'completed'
        ? widget.order['completed_at']
        : status == 'cancelled'
            ? widget.order['cancelled_at']
            : null;
    final end = status == 'open'
        ? DateTime.now()
        : DateTime.tryParse(endValue?.toString() ?? '');
    if (end == null) return '—';
    final seconds = math.max(0, end.difference(start).inSeconds);
    final days = seconds ~/ 86400;
    final hours = (seconds % 86400) ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final rest = seconds % 60;
    return '${days > 0 ? '$days d ' : ''}${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Tiempos de la orden',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('Tiempo total: ${duration('assigned_at')}'),
            Text('Tiempo asignado: ${duration('accepted_at')}'),
            if (widget.order['assigned_at'] == null)
              const Text('Esta asignación no tiene hora registrada.'),
          ]),
        ),
      );
}

class _SignaturePainter extends CustomPainter {
  final List<Offset?> points;
  _SignaturePainter(this.points);
  @override
  void paint(Canvas canvas, Size size) {
    final ink = Paint()
      ..color = Colors.black
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    for (var index = 1; index < points.length; index++) {
      final previous = points[index - 1];
      final current = points[index];
      if (previous != null && current != null) {
        canvas.drawLine(previous, current, ink);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SignaturePainter oldDelegate) => true;
}
