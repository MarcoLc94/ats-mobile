# ATS Técnicos (Android)

Aplicación Flutter basada en el armazón Android de BitLearn Mobile, adaptada a la API `/api/mobile/v1` del backend ATS `supabase`. La app original de BitLearn no se modifica.

## Alcance actual

- Acceso con correo y contraseña; refresh token rotatorio en Android Keystore mediante `flutter_secure_storage`.
- Acceso biométrico opcional: requiere una sesión guardada y renueva el token con el servidor antes de mostrar datos.
- Órdenes asignadas con paginación, detalle, checklist, lecturas, comentarios, fotos, firmas y finalización.
- Agenda y avisos de la API; ajustes de tema, biometría y cierre de sesión.
- Copia local cifrada de órdenes y borradores de texto. Fotos y firmas pendientes se guardan en el directorio privado de la app hasta confirmar el guardado. Los conflictos HTTP 409 conservan el borrador y requieren revisión manual.
- Botón visible para iniciar y terminar el turno. Durante el turno, Android mantiene un servicio de ubicación en primer plano con notificación persistente y envía coordenadas recientes por HTTPS. El mapa web usa WebSocket para mostrarlas al instante.

La app muestra datos guardados sin conexión. Las escrituras requieren conexión y confirmación del servidor; no intenta completar órdenes en segundo plano sin que el técnico vea el resultado. La API de push actual acepta tokens **Expo**, que una app Flutter no emite. Los avisos se consultan al abrir la pestaña o al actualizarla; para push nativo hará falta agregar FCM al backend y configurar Firebase para Android.

La ubicación se comparte solo con turno activo; el técnico puede detenerlo desde la app. Si Android detiene el servicio por cierre forzoso, reinicio o política de batería del fabricante, la última coordenada desaparece del mapa al quedar desactualizada. El WebSocket se usa entre backend y mapa web, no para enviar ubicación desde Android: Android limita las conexiones persistentes cuando la app está cerrada. El turno también expira en el servidor después de 12 horas.

## Preparación

1. Instalar Flutter con Dart 3.6 o superior y el SDK de Android.
2. Ejecutar `flutter pub get` y `flutter analyze`.
3. Ejecutar `flutter run --dart-define=ATS_API_BASE_URL=https://api.productos-ats.com.mx/api/mobile/v1`.
4. Para distribuir un APK/AAB, configurar la firma de release en Gradle. No hay claves de firma en este repositorio.

La URL configurada debe ser HTTPS. No incluir contraseñas, llaves de Firebase ni tokens en `--dart-define`. El `applicationId` Android es `com.ats.systems.technician`; confirmarlo antes de registrar la app en Play Console o Firebase.

## Dependencia del backend

El detalle de una orden debe devolver `status: "open" | "completed" | "cancelled"`. La rama de backend `fix/mobile-service-order-response` corrige esa respuesta; debe integrarse en `supabase` antes de usar la app con la API de producción.

Los técnicos ven únicamente órdenes asignadas a su cuenta. La creación de nuevas órdenes desde móvil queda pendiente de definir: la API permite `POST /service_orders`, pero actualmente no expone catálogos móviles de clientes y equipos para elegirlos de forma segura.

## Pruebas antes de producción

Validar en un Android real el inicio de sesión, bloqueo biométrico, actualización de una orden asignada, firma de ambos participantes, foto, conflicto de edición y finalización. Comprobar también que el equipo y cliente son los esperados y que no aparecen órdenes de otro técnico.

Validar el turno con la pantalla encendida, bloqueada y tras sacar la app de recientes. Verificar el aviso persistente, la precisión indicada por el dispositivo, el fin de turno y el indicador de posición desactualizada en ATS. Android no permite garantizar seguimiento después de **Forzar detención** en ajustes del sistema.
