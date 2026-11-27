-- Prueba del recorrido completo: consultas → contratación y pago → post venta, sobre un tenant temporal.
\set ON_ERROR_STOP 1
\set T '\'00000000-0000-0000-0000-0000000000f5\''
INSERT INTO tenants (id, name, plan_tier, settings) VALUES (:T, 'Estudio Recorrido', 'pro',
  '{"features": {"journey": true, "rf03": true, "rf10": true, "rf11": true}, "journey": {"review_url": "https://g.page/r/estudio/review"}}')
ON CONFLICT (id) DO UPDATE SET settings = EXCLUDED.settings;
INSERT INTO whatsapp_integrations (tenant_id, phone_number_id, waba_id, access_token, webhook_verify_token)
VALUES (:T, 'TEST_PNID_F', 'W', 'test-token-f', 'tenant-f-test') ON CONFLICT (phone_number_id) DO NOTHING;
INSERT INTO email_integrations (tenant_id, provider, from_email) VALUES (:T, 'mock', 'hola@estudio.test') ON CONFLICT DO NOTHING;
INSERT INTO payment_integrations (tenant_id, provider) VALUES (:T, 'mock') ON CONFLICT DO NOTHING;
INSERT INTO services (id, tenant_id, name, description, duration_min, price, sort_order, bookable) VALUES
  ('00000000-0000-0000-0000-00000000f501', :T, 'Sesión de diagnóstico', 'Relevamiento de 60 minutos', 60, 30000, 1, true),
  ('00000000-0000-0000-0000-00000000f502', :T, 'Informe escrito', 'Se entrega por email', 30, 15000, 2, false)
ON CONFLICT DO NOTHING;
INSERT INTO availability_rules (tenant_id, weekday, start_time, end_time, slot_min) SELECT :T, d, '00:00', '23:59', 60 FROM generate_series(0, 6) d;
INSERT INTO knowledge_items (tenant_id, external_key, keywords, question, answer_text)
VALUES (:T, 'horario', '{horario,horarios}', '¿Cuál es el horario?', 'Atendemos de lunes a viernes de 9 a 18 h.') ON CONFLICT DO NOTHING;

CREATE TEMP TABLE r AS SELECT 0 AS n, NULL::jsonb AS res;
CREATE OR REPLACE FUNCTION pg_temp.m(n INT, txt TEXT, rid TEXT DEFAULT NULL) RETURNS TEXT LANGUAGE plpgsql AS $f$
DECLARE x JSONB;
BEGIN
  x := bot_handle_message(jsonb_build_object('phone_number_id', 'TEST_PNID_F', 'from', '5491144444444', 'text', txt,
         'reply_id', rid, 'message_id', 'j-' || n || '-' || extract(epoch FROM clock_timestamp()), 'contact_name', 'Juan'));
  INSERT INTO r VALUES (n, x);
  RETURN n || ') «' || txt || coalesce(' / ' || rid, '') || '» → ' || left(bot_preview(x), 320);
END $f$;
CREATE OR REPLACE FUNCTION pg_temp.ord() RETURNS UUID LANGUAGE sql AS $f$
  SELECT id FROM service_orders WHERE tenant_id = '00000000-0000-0000-0000-0000000000f5' ORDER BY created_at DESC LIMIT 1
$f$;

\echo ==== Etapa 1: menú y consultas
SELECT pg_temp.m(1, 'Hola');
SELECT pg_temp.m(2, 'Hacer una consulta', 'j:faq');
SELECT pg_temp.m(3, '¿qué horarios tienen?');
SELECT pg_temp.m(4, 'Hola, quiero sacar un turno');
SELECT pg_temp.m(5, 'cancelar');

\echo ==== Etapa 2: contratación, pago y turno
SELECT pg_temp.m(10, 'Contratar', 'j:hire');
SELECT pg_temp.m(11, 'Sesión de diagnóstico', 's' || 'v:00000000-0000-0000-0000-00000000f501');
SELECT pg_temp.m(12, 'Juan Pérez');
SELECT pg_temp.m(13, 'juan@test.com');
SELECT pg_temp.m(14, 'Sí, pagar', 'j:pay');
SELECT (bot_journey_checkout_context(pg_temp.ord()))->>'mock_url' LIKE '%/webhook/servicio-mock?tenant=%' AS link_simulado,
       status FROM service_orders WHERE id = pg_temp.ord();
SELECT x->>'first_payment' AS primer_pago, x #>> '{wa,0,message,interactive,body,text}' AS mensaje, x #>> '{notify,type}' AS aviso
  FROM (SELECT bot_journey_paid(:T, 'mock', 'mock-' || pg_temp.ord(), pg_temp.ord(), 'mock-ref', '{}') AS x) y;
SELECT (bot_journey_paid(:T, 'mock', 'mock-' || pg_temp.ord(), pg_temp.ord(), 'mock-ref', '{}'))->>'duplicate' AS pago_repetido;
SELECT kind, subject FROM email_outbox WHERE tenant_id = :T;
SELECT pg_temp.m(15, 'Elegir turno', 'j:book:' || pg_temp.ord());
SELECT pg_temp.m(16, '2');
SELECT pg_temp.m(17, '1');
SELECT pg_temp.m(18, 'Confirmar', 'bk:confirm');
SELECT so.status, so.booking_id IS NOT NULL AS con_turno, b.ends_at - b.starts_at AS duracion
  FROM service_orders so LEFT JOIN bookings b ON b.id = so.booking_id WHERE so.id = pg_temp.ord();

\echo ==== Cliente conocido: segunda compra sin volver a pedir datos (servicio sin turno)
SELECT pg_temp.m(20, 'quiero contratar');
SELECT pg_temp.m(21, '2');
SELECT pg_temp.m(22, 'Sí, pagar', 'j:pay');
SELECT x #>> '{wa,0,message,text}' AS mensaje_sin_turno
  FROM (SELECT bot_journey_paid(:T, 'mock', 'mock-' || pg_temp.ord(), pg_temp.ord(), '', '{}') AS x) y;

\echo ==== Etapa 3: post venta (mis compras, encuesta, ayuda)
SELECT pg_temp.m(30, 'Mis compras y ayuda', 'j:post');
SELECT pg_temp.m(31, '1');
SELECT pg_temp.m(32, 'Todo bien', 'j:ok');
-- El turno ya pasó y el informe se pagó hace un día: las dos compras reciben la encuesta, una sola vez
UPDATE bookings SET starts_at = NOW() - INTERVAL '5 hours', ends_at = NOW() - INTERVAL '4 hours' WHERE tenant_id = :T;
UPDATE service_orders SET paid_at = NOW() - INTERVAL '25 hours' WHERE tenant_id = :T;
SELECT x->>'to' AS para, x #>> '{message,interactive,body,text}' AS encuesta FROM bot_journey_survey_due() x;
SELECT count(*) AS segunda_pasada FROM bot_journey_survey_due();
SELECT pg_temp.m(33, '😀 Muy bien', 'jr:5:' || (SELECT id FROM service_orders WHERE tenant_id = :T AND booking_id IS NOT NULL));
SELECT pg_temp.m(34, '😞 Mal', 'jr:1:' || (SELECT id FROM service_orders WHERE tenant_id = :T AND booking_id IS NULL));
SELECT pg_temp.m(35, 'El informe llegó incompleto');
SELECT number IS NOT NULL AS ticket, (SELECT number FROM service_orders WHERE id = service_order_id) AS compra FROM support_tickets WHERE tenant_id = :T;
SELECT number, status, rating FROM service_orders WHERE tenant_id = :T ORDER BY created_at;
\echo ==== Un número ajeno no puede usar los botones de otra compra
SELECT bot_preview(bot_handle_message(jsonb_build_object('phone_number_id', 'TEST_PNID_F', 'from', '5491100000002', 'text', 'Elegir turno',
       'reply_id', 'j:book:' || pg_temp.ord(), 'message_id', 'j-ajeno'))) AS ajeno;

DELETE FROM tenants WHERE id = :T;
\echo ==== JOURNEY_CLEAN_OK
