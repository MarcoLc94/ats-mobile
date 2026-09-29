import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/shift_tracker.dart';
import 'order_detail.dart';

class HomeScreen extends StatefulWidget {
  final AtsSession session;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  const HomeScreen(
      {super.key,
      required this.session,
      required this.themeMode,
      required this.onThemeChanged});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int tab = 0;
  int page = 1;
  int total = 0;
  bool loading = false;
  bool cached = false;
  String? error;
  List<Map<String, dynamic>> orders = [];
  List<Map<String, dynamic>> agenda = [];
  List<Map<String, dynamic>> notifications = [];
  late final ShiftTracker tracker;
  bool shiftActive = false;
  bool shiftBusy = false;
  int loadSequence = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    tracker = ShiftTracker(widget.session);
    _refreshShift();
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshShift();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refreshShift() async {
    final value = await tracker.isActive;
    if (mounted) setState(() => shiftActive = value);
  }

  Future<void> _toggleShift() async {
    if (!shiftActive) {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('Iniciar turno'),
                content: const Text(
                    'Durante el turno, ATS verá tu ubicación en el mapa de Operación. Android mostrará una notificación persistente. Puedes terminar el turno aquí cuando quieras.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancelar')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Iniciar turno'))
                ],
              ));
      if (confirmed != true) return;
    }
    if (!mounted) return;
    setState(() => shiftBusy = true);
    try {
      if (shiftActive) {
        final confirmed = await tracker.stop();
        if (!confirmed && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Turno detenido en este teléfono. ATS ocultará la última posición en dos minutos.')));
        }
      } else {
        await tracker.start();
      }
      await _refreshShift();
    } catch (e) {
      await _refreshShift();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => shiftBusy = false);
    }
  }

  Widget _shiftCard() => Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          Icon(shiftActive ? Icons.location_on : Icons.location_off,
              color: shiftActive ? Colors.green : null),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(shiftActive ? 'Turno activo' : 'Fuera de turno',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                Text(
                    shiftActive
                        ? 'Compartiendo ubicación con operación'
                        : 'Tu ubicación no se comparte',
                    style: Theme.of(context).textTheme.bodySmall),
              ])),
          FilledButton.tonal(
              onPressed: shiftBusy ? null : _toggleShift,
              child: Text(shiftActive ? 'Terminar' : 'Iniciar')),
        ]),
      ));

  Future<void> _load() async {
    final selectedTab = tab;
    final selectedPage = page;
    final sequence = ++loadSequence;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (selectedTab == 0) {
        final result = asMap(await widget.session.request(
            'GET', '/service_orders',
            query: {'page': '$selectedPage', 'per_page': '30'}));
        orders = (result['data'] as List? ?? []).map((e) => asMap(e)).toList();
        total =
            (asMap(result['meta'])['total'] as num?)?.toInt() ?? orders.length;
        await widget.session.saveCache('orders:$selectedPage', result);
      } else if (selectedTab == 1) {
        // Agenda is included in the technician sync endpoint, not in a separate route.
        final result = asMap(await widget.session.request('GET', '/sync'));
        agenda = (asMap(result['data'])['agenda_entries'] as List? ?? [])
            .map((e) => asMap(e))
            .toList();
        await widget.session.saveCache('agenda', agenda);
      } else if (selectedTab == 2) {
        final result =
            asMap(await widget.session.request('GET', '/notifications'));
        notifications =
            (result['data'] as List? ?? []).map((e) => asMap(e)).toList();
        await widget.session.saveCache('notifications', notifications);
      }
      if (sequence == loadSequence) cached = false;
    } catch (e) {
      if (sequence == loadSequence) error = e.toString();
      final local = await widget.session.readCache(selectedTab == 0
          ? 'orders:$selectedPage'
          : selectedTab == 1
              ? 'agenda'
              : 'notifications');
      if (selectedTab == 0 && local != null) {
        orders =
            (asMap(local)['data'] as List? ?? []).map((e) => asMap(e)).toList();
        total = (asMap(asMap(local)['meta'])['total'] as num?)?.toInt() ??
            orders.length;
      } else if (selectedTab == 1 && local is List) {
        agenda = local.map((e) => asMap(e)).toList();
      } else if (selectedTab == 2 && local is List) {
        notifications = local.map((e) => asMap(e)).toList();
      }
      if (sequence == loadSequence) cached = local != null;
    } finally {
      if (mounted && sequence == loadSequence) setState(() => loading = false);
    }
  }

  void _select(int value) {
    setState(() => tab = value);
    if (value < 3) _load();
  }

  @override
  Widget build(BuildContext context) {
    const titles = ['Mis órdenes', 'Agenda', 'Avisos', 'Mi cuenta'];
    return Scaffold(
      appBar: AppBar(title: Text(titles[tab]), actions: [
        if (tab < 3)
          IconButton(
              onPressed: loading ? null : _load,
              icon: const Icon(Icons.refresh),
              tooltip: 'Actualizar'),
      ]),
      body: Column(children: [
        if (cached)
          const MaterialBanner(
              content: Text(
                  'Mostrando datos guardados. Actualiza cuando tengas conexión.'),
              actions: [SizedBox.shrink()]),
        if (error != null && !cached)
          Padding(
              padding: const EdgeInsets.all(12),
              child: Text(error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error))),
        if (loading) const LinearProgressIndicator(),
        Expanded(
            child: switch (tab) {
          0 => _orders(),
          1 => _agenda(),
          2 => _notifications(),
          _ => _profile(),
        }),
      ]),
      bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: _select,
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.assignment_outlined),
                selectedIcon: Icon(Icons.assignment),
                label: 'Órdenes'),
            NavigationDestination(
                icon: Icon(Icons.event_outlined),
                selectedIcon: Icon(Icons.event),
                label: 'Agenda'),
            NavigationDestination(
                icon: Icon(Icons.notifications_outlined),
                selectedIcon: Icon(Icons.notifications),
                label: 'Avisos'),
            NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: 'Cuenta'),
          ]),
    );
  }

  Widget _orders() => RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          _shiftCard(),
          if (orders.isEmpty)
            const ListTile(title: Text('No tienes órdenes asignadas.')),
          ...orders.map((order) => Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              child: ListTile(
                title:
                    Text(order['folio']?.toString() ?? 'Orden #${order['id']}'),
                subtitle: Text(
                    '${asMap(order['client'])['name'] ?? 'Cliente'} · ${asMap(order['equipment'])['name'] ?? 'Equipo'}\n${_serviceLabel(order['service_type'])} · ${order['status'] == 'open' ? 'Abierta' : 'Completada'}'),
                isThreeLine: true,
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => OrderDetailScreen(
                          session: widget.session,
                          orderId: (order['id'] as num).toInt())));
                  _load();
                },
              ))),
          if (page > 1 || page * 30 < total)
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              TextButton(
                  onPressed: page > 1
                      ? () {
                          page--;
                          _load();
                        }
                      : null,
                  child: const Text('Anterior')),
              Text('Página $page'),
              TextButton(
                  onPressed: page * 30 < total
                      ? () {
                          page++;
                          _load();
                        }
                      : null,
                  child: const Text('Siguiente')),
            ]),
        ],
      ));

  String _serviceLabel(dynamic value) => switch (value) {
        'preventive' => 'Preventivo',
        'corrective' => 'Correctivo',
        'maintenance' => 'Mantenimiento',
        'rent' => 'Renta',
        'policy' => 'Póliza',
        _ => value?.toString() ?? 'Servicio',
      };

  Widget _agenda() => RefreshIndicator(
      onRefresh: _load,
      child: ListView(children: [
        if (agenda.isEmpty)
          const ListTile(title: Text('No hay visitas programadas.')),
        ...agenda.map((item) => ListTile(
              leading: const Icon(Icons.event_available),
              title: Text(item['title']?.toString() ??
                  item['description']?.toString() ??
                  'Visita'),
              subtitle: Text(
                  '${item['scheduled_on'] ?? ''}\n${asMap(item['client'])['name'] ?? item['notes'] ?? ''}'),
              isThreeLine: true,
            )),
      ]));

  Widget _notifications() => RefreshIndicator(
      onRefresh: _load,
      child: ListView(children: [
        if (notifications.isEmpty)
          const ListTile(title: Text('No tienes avisos.')),
        ...notifications.map((item) => ListTile(
              leading: Icon(item['read_at'] == null
                  ? Icons.notifications_active
                  : Icons.notifications_none),
              title: Text(item['title']?.toString() ?? 'Aviso'),
              subtitle: Text(item['body']?.toString() ?? ''),
              onTap: () async {
                try {
                  await widget.session
                      .request('POST', '/notifications/${item['id']}/read');
                  final orderId = asMap(item['data'])['service_order_id'];
                  if (orderId is num && mounted) {
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => OrderDetailScreen(
                            session: widget.session,
                            orderId: orderId.toInt())));
                  }
                  _load();
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(e.toString())));
                  }
                }
              },
            )),
      ]));

  Widget _profile() => ListView(padding: const EdgeInsets.all(16), children: [
        ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text(widget.session.displayName),
            subtitle: Text(widget.session.user?['email']?.toString() ?? '')),
        const Divider(),
        _shiftCard(),
        SwitchListTile(
            secondary: const Icon(Icons.fingerprint),
            title: const Text('Acceso con biometría'),
            subtitle: const Text(
                'Verifica tu huella y renueva la sesión al abrir la app.'),
            value: widget.session.biometricEnabled,
            onChanged: (value) async {
              try {
                await widget.session.setBiometrics(value);
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(e.toString())));
                }
              }
            }),
        ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Apariencia'),
            trailing: DropdownButton<ThemeMode>(
                value: widget.themeMode,
                items: const [
                  DropdownMenuItem(
                      value: ThemeMode.system, child: Text('Sistema')),
                  DropdownMenuItem(
                      value: ThemeMode.light, child: Text('Claro')),
                  DropdownMenuItem(
                      value: ThemeMode.dark, child: Text('Oscuro')),
                ],
                onChanged: (mode) {
                  if (mode != null) widget.onThemeChanged(mode);
                })),
        const SizedBox(height: 20),
        OutlinedButton.icon(
            onPressed: () async {
              if (shiftActive) {
                try {
                  await tracker.stop();
                } catch (_) {/* Local tracking stops even when offline. */}
              }
              await widget.session.logout();
            },
            icon: const Icon(Icons.logout),
            label: const Text('Cerrar sesión')),
      ]);
}
