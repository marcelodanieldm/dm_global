# Servicio de Feedback — DM Global

Sistema SaaS de gestión de reseñas para comercios turísticos (hoteles, excursiones, traslados y alquiler de vehículos). Automatiza el ciclo completo de recolección de feedback, filtrado de reseñas negativas y respuesta con asistencia de IA.

---

## Índice

- [Arquitectura general](#arquitectura-general)
- [Stack tecnológico](#stack-tecnológico)
- [Instalación y configuración](#instalación-y-configuración)
- [Variables de entorno](#variables-de-entorno)
- [Modelos de datos](#modelos-de-datos)
- [API REST — Endpoints](#api-rest--endpoints)
- [Panel de administración](#panel-de-administración)
- [Google Apps Scripts](#google-apps-scripts)
- [Copiloto de Respuestas con IA](#copiloto-de-respuestas-con-ia)
- [Flujo operativo completo](#flujo-operativo-completo)
- [Internacionalización](#internacionalización)
- [Despliegue en producción](#despliegue-en-producción)

---

## Arquitectura general

```
┌─────────────────────────────────────────────────────────────────┐
│  GOOGLE WORKSPACE                                                │
│                                                                  │
│  Google Forms ──► OnboardingCliente.gs ──► Google Sheets        │
│                                                   │              │
│            ClienteFeedbackDiario.gs ◄─────────────┤             │
│            AlertasCriticas.gs       ◄─────────────┤             │
│            InformeSemanal.gs        ◄─────────────┤             │
│            Copiloto.gs (despacho)   ◄─────────────┘             │
└─────────────────────────────┬───────────────────────────────────┘
                              │ HTTP GET/POST
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  DJANGO — dm_global  (este proyecto)                             │
│                                                                  │
│  /api/v1/licencias/validar/     ← billing gate                  │
│  /api/v1/servicio-feedback/     ← stats, alertas                │
│  /feedback/<uuid>/<token>/      ← portal de valoración          │
│  /admin/                        ← panel de gestión              │
│                                                                  │
│  AI: Google Gemini Pro          ← borradores de respuesta        │
│  Stripe / Mercado Pago          ← webhooks de renovación         │
└─────────────────────────────────────────────────────────────────┘
```

---

## Stack tecnológico

| Capa | Tecnología |
|---|---|
| Backend | Django 4.2, Python 3.11+ |
| ORM | Django ORM (PostgreSQL en prod, SQLite en dev) |
| Panel admin | Django Admin (built-in) con acciones personalizadas |
| IA | Google Gemini Pro vía REST API (`requests`) |
| Pagos | Stripe · Mercado Pago (webhooks) |
| Automatización | Google Apps Script (6 archivos `.gs`) |
| Email | GmailApp (GAS) · Django `send_mail` (alertas) |
| WhatsApp | Twilio (stub preparado, descomentar para activar) |

---

## Instalación y configuración

```bash
# 1. Clonar y crear entorno virtual
git clone <repo_url>
cd dm_global
python -m venv venv && source venv/bin/activate   # Windows: venv\Scripts\activate

# 2. Instalar dependencias
pip install -r requirements.txt

# 3. Configurar variables de entorno
cp .env.example .env   # editar con los valores reales

# 4. Aplicar migraciones
python manage.py migrate

# 5. Crear superusuario
python manage.py createsuperuser

# 6. Arrancar servidor de desarrollo
python manage.py runserver
```

### Verificar instalación

```bash
python manage.py check                    # debe retornar 0 errores
python manage.py check --deploy           # solo warnings de HTTPS (esperados en dev)
```

---

## Variables de entorno

Crear `.env` en la raíz del proyecto:

```env
# Django
DJANGO_SECRET_KEY=tu-clave-secreta-de-al-menos-50-caracteres
DEBUG=true

# Base de datos PostgreSQL (producción)
DB_NAME=dm_feedback
DB_USER=postgres
DB_PASSWORD=
DB_HOST=localhost
DB_PORT=5432

# Copiloto de Respuestas con IA
# Obtener en: https://aistudio.google.com/app/apikey
# Vacía en dev → el copiloto se deshabilita silenciosamente
GEMINI_API_KEY=

# Google Sheets API (aprovisionamiento automático de planillas)
# Requiere cuenta de servicio descargada desde Google Cloud Console
GOOGLE_SERVICE_ACCOUNT_FILE=ruta/al/service-account.json
GOOGLE_SHEETS_TEMPLATE_ID=id-del-sheet-plantilla-maestra

# Pasarelas de pago (webhooks de renovación de licencias)
# Stripe
STRIPE_WEBHOOK_SECRET=whsec_...

# Mercado Pago
MP_ACCESS_TOKEN=APP_USR-...
MP_WEBHOOK_SECRET=...
```

---

## Modelos de datos

### `LicenciaFeedback` — Billing engine

Controla el acceso al servicio por comercio. El Apps Script llama al endpoint `/validar/` antes de cada ejecución; si la licencia está vencida o pausada, recibe HTTP 403 y se detiene automáticamente.

| Campo | Tipo | Descripción |
|---|---|---|
| `id_comercio` | CharField PK | Legible: `HOTEL-TERRAZAS-01`. El cliente lo pega en CONFIG de su planilla. |
| `nombre_comercio` | CharField | Solo para uso interno del admin. |
| `tipo_negocio` | TextChoices | `HOTEL` · `TOUR` · `TRANSFER` · `ALQUILER` · `RESTO` |
| `email_facturacion` | EmailField | Identificación rápida y auditoría. |
| `esta_activa` | BooleanField | `False` → servicio suspendido inmediatamente. |
| `fecha_vencimiento` | DateField | Se extiende +30 días vía `renovar_suscripcion()` por webhook. |
| `ultima_renovacion` | DateTimeField | Timestamp del último cobro exitoso. |
| `pasarela_activa` | TextChoices | `stripe` · `mp` · `manual` |
| `stripe_customer_id` | CharField unique | ID de cliente en Stripe (`cus_...`). |
| `stripe_subscription_id` | CharField | ID de suscripción activa en Stripe (`sub_...`). |
| `mp_preapproval_id` | CharField | ID de débito automático en Mercado Pago. |

**Método clave:**
```python
licencia.renovar_suscripcion(dias=30, pasarela=PasarelaPago.STRIPE)
# Aplica max(hoy, fecha_vencimiento) + 30d → sin brechas ni retroceders
```

### `ServicioFeedbackConfig` — Configuración por comercio

Almacena las credenciales de integración con Google.

| Campo | Tipo | Descripción |
|---|---|---|
| `id` | UUIDField PK | `comercio_id` que el cliente usa en su planilla. |
| `api_token` | UUIDField | Token de autenticación para el sistema portal+UUID. |
| `google_review_link` | URLField | Destino de los turistas con 4-5 estrellas. |
| `google_sheet_url` | URLField | Planilla aprovisionada automáticamente. |
| `estado_suscripcion` | TextChoices | `ACTIVO` · `INACTIVO` · `DEMO` |
| `tipo_negocio` | TextChoices | Igual que `LicenciaFeedback`. |

### `RespuestaFeedback` — Operaciones de turistas

Registra cada respuesta del portal de valoración.

| Campo | Tipo | Descripción |
|---|---|---|
| `token_feedback` | UUIDField unique | Generado por GAS al aprobar el borrador. |
| `calificacion` | IntegerField | 1-5 estrellas. `>= 4` → Google Reviews. `<= 3` → queja privada. |
| `comentario` | TextField | Queja privada (formulario web, 1-3 estrellas). |
| `comentario_turista` | TextField | Opinión cruda para el Copiloto IA. |
| `borrador_respuesta_ia` | TextField | Borrador generado por Gemini Pro. |
| `estado_copiloto` | TextChoices | `PENDIENTE` · `APROBADO` |
| `alerta_email_at` | DateTimeField | Timestamp de alerta crítica enviada (1-2 estrellas). |
| `alerta_whatsapp_at` | DateTimeField | Timestamp de alerta WhatsApp (set por GAS tras ACK). |

---

## API REST — Endpoints

### Licencias (billing gate)

```
GET  /api/v1/licencias/validar/?id_comercio=HOTEL-TERRAZAS-01
```

Consumido por `ClienteFeedbackDiario.gs` antes de cada ejecución nocturna.

| HTTP | Caso |
|---|---|
| 200 `{"autorizado": true}` | Licencia activa y vigente |
| 401 `{"autorizado": false, "error": "Licencia inexistente."}` | ID no encontrado |
| 403 `{"autorizado": false, "error": "..."}` | Suspendida o vencida |
| 405 | Método != GET |

### Portal de valoración (turistas)

```
GET  /feedback/<uuid:comercio_id>/<uuid:token_feedback>/         → portal de estrellas
POST /feedback/<uuid:comercio_id>/<uuid:token_feedback>/         → guarda calificacion
GET  /feedback/<uuid:comercio_id>/<uuid:token_feedback>/queja/   → formulario privado
POST /feedback/<uuid:comercio_id>/<uuid:token_feedback>/queja/   → guarda comentario + IA
```

### Alertas críticas (Apps Script ← CRM)

```
GET  /api/v1/servicio-feedback/alertas-criticas/
     ?comercio_id=<UUID>&token=<UUID>
     → lista de alertas 1-2★ pendientes de WhatsApp

POST /api/v1/servicio-feedback/alertas-criticas/ack/
     ?comercio_id=<UUID>&token=<UUID>
     body: {"ids": ["uuid1", "uuid2"]}
     → marca alerta_whatsapp_at
```

### Stats semanales (para InformeSemanal.gs)

```
GET  /api/v1/servicio-feedback/stats/
     ?comercio_id=<UUID>&token=<UUID>&dias=7
     → {"total_respuestas": N, "positivas": N, "contenidas": N, "redirigidas_a_google": N}
```

### Panel cliente (CRM login)

```
GET  /feedback/activar/          → formulario de alta del servicio
GET  /panel/                     → dashboard con credenciales y stats
GET  /panel/<uuid:comercio_id>/  → acceso directo por UUID (sin login)
```

---

## Panel de administración

Acceder en `/admin/` con las credenciales del superusuario.

### `LicenciaFeedbackAdmin`

- **Lista**: ID comercio · Tipo · Estado (badge de color) · Fecha vencimiento · Días restantes · Botón toggle
- **Toggle de un clic**: columna "Activar/Pausar" → llama a `/admin/servicios/licencia/<pk>/toggle/` y regresa al listado
- **Acciones masivas**: "Activar seleccionadas" · "Pausar seleccionadas"
- **Colores de estado**: Verde=Activa · Naranja=Por vencer (≤7d) · Rojo=Vencida · Gris=Pausada

### `RespuestaFeedbackAdmin`

- **Lista**: Organización · Tipo · Estado badge · Última sincronización
- **Filtros**: `estado_suscripcion` · `tipo_negocio`
- **Búsqueda**: por nombre de organización

---

## Google Apps Scripts

Los 6 archivos `.gs` en `servicios/static/apps_script/` son la plantilla maestra para el editor de Google Apps Script.

### Flujo de archivos

```
OnboardingCliente.gs          ← trigger: Al enviar el formulario de alta
   └─ Copia planilla maestra, inyecta CONFIG, envía email de bienvenida

AprobacionBorrador.gs         ← botón: "🚀 APROBAR Y CARGAR DATOS"
   └─ BORRADOR → OPERACIONES (PENDIENTE) + genera TOKEN_FEEDBACK por fila

ClienteFeedbackDiario.gs      ← trigger diario: 08:00 hs
   └─ GET /api/v1/licencias/validar/ → envía emails por idioma y tipo

AlertasCriticas.gs            ← trigger cada 30 min
   └─ GET /alertas-criticas/ → WhatsApp (Twilio) para 1-2★

InformeSemanal.gs             ← trigger lunes 08:00 hs
   └─ GET /stats/ → email HTML ejecutivo al gerente

google_apps_script_copiloto.js ← botón: "🚀 Despachar Respuesta"
   └─ Lee borrador (col I, editable) → GmailApp.sendEmail → pinta fila verde
```

### Layout de la pestaña OPERACIONES

| Col | Campo | Origen |
|---|---|---|
| A | Nombre Turista | Operador |
| B | Email / Contacto | Operador |
| C | Idioma (`es`·`en`·`pt`·`fr`·`de`) | Operador |
| D | Fecha de Registro | Operador |
| E | Estado Envío | `ClienteFeedbackDiario.gs` |
| F | Canal (`email`·`whatsapp`) | Operador |
| G | Calificación (1-5) | Sincronizado desde portal Django |
| H | Comentario del Turista | Sincronizado desde Django |
| **I** | **Borrador IA** | **Gemini Pro vía Django — editable por el gerente** |
| **J** | **Estado Copiloto** | **`google_apps_script_copiloto.js`** |

### Layout de la pestaña CONFIG

| Celda | Contenido | Inyectado por |
|---|---|---|
| B1 | ID de Licencia (`HOTEL-TERRAZAS-01`) | `OnboardingCliente.gs` |
| B2 | Enlace Google Reviews | `OnboardingCliente.gs` |
| B3 | Correo del Gerente | `OnboardingCliente.gs` |
| B4 | Email reporte semanal | `OnboardingCliente.gs` |

### Configuración inicial de Apps Script

```javascript
// Ejecutar una sola vez desde el editor (Archivo → Ejecutar → configurarPropiedades)
PropertiesService.getScriptProperties().setProperties({
  DM_ID_PLANTILLA_MAESTRA: '1A2B3C...ID_DEL_SHEET_TEMPLATE',
  DM_ID_CARPETA_CLIENTES:  '1X2Y3Z...ID_CARPETA_DRIVE',
  DM_EMAIL_ADMIN:          'admin@dmglobal.com',

  // Para WhatsApp (Twilio)
  TWILIO_SID:   'ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
  TWILIO_TOKEN: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
  TWILIO_FROM:  'whatsapp:+14155238886',
});
```

---

## Copiloto de Respuestas con IA

El Copiloto usa Google Gemini Pro para generar borradores de respuesta empática cuando un turista da 1-3 estrellas y deja un comentario.

### Flujo

```
Turista da 1-3★ → formulario /queja/ → POST a Django
   │
   ├─ comentario_turista guardado en DB
   │
   └─ ai_service.generar_borrador_respuesta()
         │
         ├─ Sin GEMINI_API_KEY → "" (silencioso)
         ├─ Timeout (12s)     → "" + log WARNING
         ├─ HTTP 429/5xx      → "" + log WARNING
         ├─ JSON inesperado   → "" + log WARNING
         └─ OK                → texto en el idioma del turista
               │
               └─ borrador_respuesta_ia guardado en DB
                     │
                     └─ estado_copiloto = PENDIENTE

Gerente abre Google Sheet
   └─ Col I muestra el borrador (editable)
   └─ Clic en "🚀 Despachar Respuesta"
         └─ GmailApp.sendEmail al turista
         └─ Col J → RESPUESTA_ENVIADA
         └─ Fila pintada en verde (#d4edda)
```

### Prompt del sistema (por idioma)

El prompt le ordena a Gemini actuar como gerente del comercio, pedir disculpas específicas por el problema mencionado y responder en máximo 3 líneas, sin saludos formales.

Idiomas soportados: `es` · `en` · `pt` · `fr` · `de`

### Degradación graceful

Si la IA no está disponible (sin API key, timeout, rate-limit), el flujo continúa sin interrupciones: `comentario_turista` se guarda, `borrador_respuesta_ia` queda vacío y el operador puede redactarlo manualmente desde el admin.

---

## Flujo operativo completo

```
1. ALTA DEL COMERCIO (una vez)
   Google Forms de alta → OnboardingCliente.gs
   → copia planilla maestra en Drive del cliente
   → inyecta CONFIG (ID licencia, link reviews, email gerente)
   → email de bienvenida con botón "Abrir planilla"

2. OPERACIÓN DIARIA (cada noche)
   Operador carga pasajeros en BORRADOR
   → clic "🚀 APROBAR Y CARGAR DATOS" (AprobacionBorrador.gs)
   → genera TOKEN_FEEDBACK por fila (UUID)
   → mueve registros a OPERACIONES (PENDIENTE)

3. VALIDACIÓN Y ENVÍO (trigger 08:00)
   ClienteFeedbackDiario.gs
   → GET /api/v1/licencias/validar/?id_comercio=...
     - 200: procede → emails en el idioma del turista con link al portal
     - 403: detiene todo (licencia vencida/suspendida por DM Global)

4. PORTAL DE CALIFICACIÓN (tiempo real)
   Turista hace clic en el email
   → /feedback/<id>/<token>/   ← 5 estrellas táctiles
     - 4-5★ → redirect a Google Reviews (reseña pública)
     - 1-3★ → formulario privado (/queja/)
                → guarda comentario_turista
                → Gemini genera borrador_respuesta_ia

5. ALERTAS CRÍTICAS (cada 30 min)
   AlertasCriticas.gs
   → GET /alertas-criticas/ (1-2★ sin WhatsApp)
   → Twilio WhatsApp al gerente con datos del turista
   → POST /ack/ marca alerta_whatsapp_at

6. DESPACHO DE RESPUESTA (manual, botón)
   Gerente revisa Col I (borrador IA), edita si quiere
   → clic "🚀 Despachar Respuesta" (google_apps_script_copiloto.js)
   → email al turista con el texto aprobado
   → Col J = RESPUESTA_ENVIADA, fila verde

7. INFORME SEMANAL (lunes 08:00)
   InformeSemanal.gs
   → GET /stats/?dias=7
   → email HTML ejecutivo al gerente:
     enviadas · tasa de respuesta · reseñas en Google · quejas contenidas
```

---

## Internacionalización

Todos los mensajes al turista (email y WhatsApp) están disponibles en 5 idiomas:

| Código | Idioma |
|---|---|
| `es` | Español (default) |
| `en` | English |
| `pt` | Português |
| `fr` | Français |
| `de` | Deutsch |

El idioma se determina desde la columna C de OPERACIONES y se propaga al portal Django vía el parámetro `?lang=XX` en la URL del email.

---

## Despliegue en producción

### Checklist

- [ ] Configurar todas las variables de entorno en `.env`
- [ ] Cambiar `DEBUG=false`
- [ ] Configurar PostgreSQL (no SQLite)
- [ ] Ejecutar `python manage.py collectstatic`
- [ ] Configurar Nginx/Gunicorn o plataforma PaaS
- [ ] Actualizar `ALLOWED_HOSTS` con el dominio real
- [ ] Obtener y configurar `GEMINI_API_KEY`
- [ ] Configurar `GOOGLE_SERVICE_ACCOUNT_FILE` para aprovisionamiento automático
- [ ] Reemplazar `https://TU-DOMINIO.com` en los 6 archivos GAS con el dominio real
- [ ] Ejecutar `configurarPropiedades()` en Apps Script (una vez por planilla)
- [ ] Crear los triggers de tiempo en Apps Script
- [ ] Configurar Stripe/Mercado Pago webhooks apuntando a `/api/v1/licencias/`

### Estructura de archivos clave

```
dm_global/
├── dm_global/
│   ├── settings.py          ← variables de entorno y GEMINI_API_KEY
│   └── urls.py              ← rutas raíz (admin + servicios)
├── servicios/
│   ├── models.py            ← LicenciaFeedback, ServicioFeedbackConfig, RespuestaFeedback
│   ├── views.py             ← todos los endpoints Django
│   ├── urls.py              ← /api/, /feedback/, /panel/
│   ├── ai_service.py        ← cliente Gemini Pro (fallos silenciosos)
│   ├── admin.py             ← panel con toggle de un clic
│   ├── forms.py             ← formulario de alta del servicio
│   ├── sheets_provisioning.py ← Google Drive API para planillas
│   └── static/apps_script/
│       ├── OnboardingCliente.gs
│       ├── AprobacionBorrador.gs
│       ├── ClienteFeedbackDiario.gs
│       ├── AlertasCriticas.gs
│       ├── InformeSemanal.gs
│       └── google_apps_script_copiloto.js
├── templates/servicios/
│   ├── activar_feedback.html
│   ├── dashboard_feedback.html
│   └── feedback/
│       ├── portal.html      ← 5 estrellas táctiles (mobile-first)
│       ├── queja.html       ← formulario privado
│       └── gracias.html     ← confirmación
├── migrations/
│   └── 0001_initial.py
└── requirements.txt
```

---

## Licencia y autoría

Desarrollado para **DM Global** como Add-on premium del CRM interno.  
Soporte técnico: soporte@dmglobal.com
