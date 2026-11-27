-- Pruebas de fase 2 (RF-03 reservas, RF-04 suscripciones) sobre un tenant de prueba que se borra al final.
\set ON_ERROR_STOP 1
INSERT INTO tenants (id, name, plan_tier, settings) VALUES
  ('00000000-0000-0000-0000-0000000000c3', 'Estudio Prueba', 'pro', '{"features": {"rf03": true, "rf04": true}}')
ON CONFLICT (id) DO UPDATE SET settings = EXCLUDED.settings;
INSERT INTO whatsapp_integrations (tenant_id, phone_number_id, waba_id, access_token, webhook_verify_token)
VALUES ('00000000-0000-0000-0000-0000000000c3', 'TEST_PNID_C', 'TEST_WABA_C', 'test-token-c', 'tenant-c-test')
ON CONFLICT (phone_number_id) DO NOTHING;
INSERT INTO services (id, tenant_id, name, duration_min, price, sort_order) VALUES
  ('00000000-0000-0000-0000-00000000c501', '00000000-0000-0000-0000-0000000000c3', 'Consulta inicial', 30, 15000, 1),
  ('00000000-0000-0000-0000-00000000c502', '00000000-0000-0000-0000-0000000000c3', 'Sesión completa', 60, 25000, 2)
ON CONFLICT (id) DO NOTHING;
INSERT INTO availability_rules (tenant_id, weekday, start_time, end_time, slot_min)
SELECT '00000000-0000-0000-0000-0000000000c3', d, '09:00', '18:00', 30 FROM generate_series(0, 6) d;
INSERT INTO subscription_plans (tenant_id, code, name, price, description, sort_order) VALUES
  ('00000000-0000-0000-0000-0000000000c3', 'basico', 'Básico', 9900, '4 sesiones por mes', 1),
  ('00000000-0000-0000-0000-0000000000c3', 'full', 'Full', 19900, 'Sesiones ilimitadas y seguimiento', 2)
ON CONFLICT (tenant_id, code) DO NOTHING;
INSERT INTO payment_integrations (tenant_id, provider) VALUES ('00000000-0000-0000-0000-0000000000c3', 'mock')
ON CONFLICT (tenant_id) DO NOTHING;

CREATE TEMP TABLE r AS SELECT 0 AS n, NULL::jsonb AS res;
CREATE OR REPLACE FUNCTION pg_temp.m(n INT, txt TEXT, rid TEXT DEFAULT NULL, who TEXT DEFAULT 'Laura Test') RETURNS TEXT LANGUAGE plpgsql AS $f$
DECLARE x JSONB;
BEGIN
  x := bot_handle_message(jsonb_build_object('phone_number_id', 'TEST_PNID_C', 'from', '5491177777777', 'text', txt,
         'reply_id', rid, 'message_id', 'f2-' || n, 'contact_name', who));
  INSERT INTO r VALUES (n, x);
  RETURN n || ') «' || txt || coalesce(' / ' || rid, '') || '» → ' || bot_preview(x);
END $f$;

\echo ==== RF-03 reserva completa
SELECT pg_temp.m(1, 'Hola, quiero sacar un turno');
SELECT pg_temp.m(2, 'Sesión completa', 's:00000000-0000-0000-0000-00000000c502');
SELECT pg_temp.m(3, '1');
SELECT pg_temp.m(4, '2');
SELECT pg_temp.m(5, 'Confirmar', 'bk:confirm');
SELECT s.name, b.customer_name, b.ends_at - b.starts_at AS duracion, b.status FROM bookings b JOIN services s ON s.id = b.service_id
 WHERE b.tenant_id = '00000000-0000-0000-0000-0000000000c3';
\echo ==== RF-03 el mismo horario no se puede tomar dos veces
SELECT bot_rf03_book('00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-00000000c502', '5491100000009', 'Otro',
       (SELECT starts_at FROM bookings WHERE tenant_id = '00000000-0000-0000-0000-0000000000c3' LIMIT 1), 'America/Argentina/Buenos_Aires') IS NULL AS rechazado;
\echo ==== RF-03 texto libre que no es opción, y cancelar
SELECT pg_temp.m(6, 'reservar');
SELECT pg_temp.m(7, 'cualquier cosa');
SELECT pg_temp.m(8, 'cancelar');

\echo ==== RF-04 alta de suscripción
SELECT pg_temp.m(10, 'Quiero ver los planes');
SELECT pg_temp.m(11, '2');
SELECT pg_temp.m(12, 'Laura Test SRL');
SELECT pg_temp.m(13, 'laura@');
SELECT pg_temp.m(14, 'laura@test.com');
SELECT pg_temp.m(15, '30-12345678-9');
SELECT pg_temp.m(16, 'Sí, generar link', 'sub:confirm');
SELECT (bot_rf04_checkout_context(id)) #>> '{plan,name}' AS plan, (bot_rf04_checkout_context(id))->>'provider' AS proveedor, status
  FROM subscriptions WHERE tenant_id = '00000000-0000-0000-0000-0000000000c3';
\echo ==== RF-04 pago confirmado (dos veces el mismo evento)
SELECT r - 'access_token' - 'provider_token' AS activacion FROM (
  SELECT bot_rf04_activate('00000000-0000-0000-0000-0000000000c3', 'mock', 'evt-1', id, 'mock-ref', NULL, '{}') AS r
    FROM subscriptions WHERE tenant_id = '00000000-0000-0000-0000-0000000000c3') x;
SELECT (bot_rf04_activate('00000000-0000-0000-0000-0000000000c3', 'mock', 'evt-1', id, 'mock-ref', NULL, '{}'))->>'duplicate' AS duplicado
  FROM subscriptions WHERE tenant_id = '00000000-0000-0000-0000-0000000000c3';
SELECT status, current_period_end > NOW() + INTERVAL '27 days' AS periodo_ok FROM subscriptions WHERE tenant_id = '00000000-0000-0000-0000-0000000000c3';
\echo ==== Sin la feature activada, "turno" no arranca RF-03
UPDATE tenants SET settings = '{}' WHERE id = '00000000-0000-0000-0000-0000000000c3';
SELECT pg_temp.m(20, 'quiero un turno');

-- Limpieza
DELETE FROM payment_events WHERE tenant_id = '00000000-0000-0000-0000-0000000000c3';
DELETE FROM subscriptions WHERE tenant_id = '00000000-0000-0000-0000-0000000000c3';
DELETE FROM bookings WHERE tenant_id = '00000000-0000-0000-0000-0000000000c3';
DELETE FROM tenants WHERE id = '00000000-0000-0000-0000-0000000000c3';
\echo ==== FASE2_CLEAN_OK
