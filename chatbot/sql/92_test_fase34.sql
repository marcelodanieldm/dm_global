-- Pruebas de fases 3 y 4 (RF-05 a RF-11) sobre un tenant de prueba que se borra al final.
\set ON_ERROR_STOP 1
\set T '\'00000000-0000-0000-0000-0000000000d4\''
INSERT INTO tenants (id, name, plan_tier, settings, hook_secret) VALUES
  (:T, 'Tienda Prueba', 'pro',
   '{"features": {"rf03": true, "rf04": true, "rf05": true, "rf06": true, "rf07": true, "rf08": true, "rf09": true, "rf10": true, "rf11": true}}',
   'hook-prueba-fase34-000000000000')
ON CONFLICT (id) DO UPDATE SET settings = EXCLUDED.settings, hook_secret = EXCLUDED.hook_secret;
INSERT INTO whatsapp_integrations (tenant_id, phone_number_id, waba_id, access_token, webhook_verify_token)
VALUES (:T, 'TEST_PNID_D', 'TEST_WABA_D', 'test-token-d', 'tenant-d-test') ON CONFLICT (phone_number_id) DO NOTHING;
INSERT INTO email_integrations (tenant_id, provider, from_email) VALUES (:T, 'mock', 'hola@tienda.test') ON CONFLICT DO NOTHING;
INSERT INTO payment_integrations (tenant_id, provider) VALUES (:T, 'mock') ON CONFLICT DO NOTHING;
INSERT INTO services (id, tenant_id, name, duration_min) VALUES ('00000000-0000-0000-0000-00000000d501', :T, 'Consulta', 30) ON CONFLICT DO NOTHING;
INSERT INTO availability_rules (tenant_id, weekday, start_time, end_time, slot_min)
SELECT :T, d, '00:00', '23:59', 30 FROM generate_series(0, 6) d;

CREATE TEMP TABLE r AS SELECT 0 AS n, NULL::jsonb AS res;
CREATE OR REPLACE FUNCTION pg_temp.m(n INT, txt TEXT, rid TEXT DEFAULT NULL, who TEXT DEFAULT 'Ana Test') RETURNS TEXT LANGUAGE plpgsql AS $f$
DECLARE x JSONB;
BEGIN
  x := bot_handle_message(jsonb_build_object('phone_number_id', 'TEST_PNID_D', 'from', '5491166666666', 'text', txt,
         'reply_id', rid, 'message_id', 'f34-' || n || '-' || extract(epoch FROM clock_timestamp()), 'contact_name', who));
  INSERT INTO r VALUES (n, x);
  RETURN n || ') «' || txt || coalesce(' / ' || rid, '') || '» → ' || left(bot_preview(x), 300);
END $f$;

\echo ==== RF-05 carrito: webhook con clave, aviso a las 4 h, sin duplicar, carrito recuperado no se avisa
SELECT bot_rf05_ingest('clave-mala', '{}') ->> 'error' AS clave_mala;
SELECT bot_rf05_ingest('hook-prueba-fase34-000000000000', jsonb_build_object('carts', jsonb_build_array(
  jsonb_build_object('external_id', 'c1', 'name', 'Ana', 'email', 'ana@test.com', 'total', 45000, 'checkout_url', 'https://tienda.test/c1',
                     'items', '[{"name":"Remera","quantity":2,"price":15000},{"name":"Gorra","quantity":1,"price":15000}]'::jsonb,
                     'updated_at', (NOW() - INTERVAL '5 hours')::text),
  jsonb_build_object('external_id', 'c2', 'email', 'beto@test.com', 'checkout_url', 'https://tienda.test/c2', 'updated_at', (NOW() - INTERVAL '1 hour')::text),
  jsonb_build_object('external_id', 'c3', 'email', 'caro@test.com', 'checkout_url', 'https://tienda.test/c3', 'completed', true,
                     'updated_at', (NOW() - INTERVAL '6 hours')::text)))) AS ingesta;
SELECT bot_rf05_due() AS avisos_1, bot_rf05_due() AS avisos_2;
SELECT kind, to_email, subject, status FROM email_outbox WHERE tenant_id = :T ORDER BY created_at;

\echo ==== RF-06 / RF-07: suscripción que vence en 2 días → recordatorio de pago y aviso de renovación (una sola vez)
INSERT INTO subscription_plans (id, tenant_id, code, name, price) VALUES ('00000000-0000-0000-0000-00000000d601', :T, 'mensual', 'Mensual', 9900) ON CONFLICT DO NOTHING;
INSERT INTO customers (id, tenant_id, phone, name, email) VALUES ('00000000-0000-0000-0000-00000000d701', :T, '5491166666666', 'Ana Test', 'ana@test.com') ON CONFLICT DO NOTHING;
INSERT INTO subscriptions (id, tenant_id, customer_id, plan_id, status, provider, provider_ref, current_period_end, activated_at, manage_token)
VALUES ('00000000-0000-0000-0000-00000000d801', :T, '00000000-0000-0000-0000-00000000d701', '00000000-0000-0000-0000-00000000d601',
        'active', 'mock', 'mock-ref', NOW() + INTERVAL '2 days', NOW() - INTERVAL '28 days', 'token-prueba-fase34-000000000000') ON CONFLICT DO NOTHING;
SELECT bot_rf06_due() AS rf06_1, bot_rf07_due() AS rf07_1, bot_rf06_due() AS rf06_2, bot_rf07_due() AS rf07_2;
SELECT position('suscripcion?t=token-prueba' IN html) > 0 AS rf07_tiene_link_baja FROM email_outbox WHERE tenant_id = :T AND kind = 'rf07_renewal';
\echo ==== RF-04 renovación: la pasarela avisa un nuevo período y RF-06 vuelve a avisar en el próximo
SELECT (bot_rf04_activate(:T, 'mock', 'renov-1', '00000000-0000-0000-0000-00000000d801', 'mock-ref', NOW() + INTERVAL '32 days', '{}'))->>'renewed' AS renovada;
SELECT current_period_end > NOW() + INTERVAL '31 days' AS periodo_nuevo FROM subscriptions WHERE id = '00000000-0000-0000-0000-00000000d801';
\echo ==== CORE-04 toma los emails pendientes y registra el resultado
SELECT count(*) AS tomados, min(provider) AS proveedor FROM bot_email_claim(50);
SELECT bot_email_result(id, true, 'mock', NULL) FROM email_outbox WHERE tenant_id = :T AND status = 'sending';
SELECT status, count(*) FROM email_outbox WHERE tenant_id = :T GROUP BY 1;

\echo ==== RF-08 baja: por WhatsApp da el link; la página muestra el plan; confirmar cancela una sola vez
SELECT pg_temp.m(1, 'quiero dar de baja mi suscripción');
SELECT (SELECT res #>> '{messages,0,interactive,action,parameters,url}' FROM r WHERE n = 1) LIKE '%/webhook/suscripcion?t=token-prueba%' AS link_ok;
SELECT position('Cancelar mi suscripción' IN bot_rf08_page('token-prueba-fase34-000000000000')) > 0 AS pagina_con_boton,
       position('inválido' IN bot_rf08_page('no-existe')) > 0 AS token_malo;
SELECT x - 'page' - 'provider_token' AS baja FROM (SELECT bot_rf08_cancel('token-prueba-fase34-000000000000') AS x) y;
SELECT (bot_rf08_cancel('token-prueba-fase34-000000000000'))->>'already' AS segunda_vez;
SELECT status, cancelled_at IS NOT NULL AS con_fecha FROM subscriptions WHERE id = '00000000-0000-0000-0000-00000000d801';
SELECT (bot_rf04_activate(:T, 'mock', 'renov-2', '00000000-0000-0000-0000-00000000d801', 'mock-ref', NOW() + INTERVAL '60 days', '{}'))->>'error' AS no_reactiva;
SELECT count(*) AS email_baja FROM email_outbox WHERE tenant_id = :T AND kind = 'rf08_cancelled';

\echo ==== RF-09 recordatorio: reserva de mañana → un mensaje con botones, una sola vez
INSERT INTO bookings (id, tenant_id, service_id, phone, customer_name, starts_at, ends_at, created_at) VALUES
  ('00000000-0000-0000-0000-00000000d901', :T, '00000000-0000-0000-0000-00000000d501', '5491166666666', 'Ana Test',
   date_trunc('hour', NOW()) + INTERVAL '20 hours', date_trunc('hour', NOW()) + INTERVAL '20 hours 30 minutes', NOW() - INTERVAL '2 days'),
  ('00000000-0000-0000-0000-00000000d902', :T, '00000000-0000-0000-0000-00000000d501', '5491166666666', 'Ana Test',
   date_trunc('hour', NOW()) + INTERVAL '22 hours', date_trunc('hour', NOW()) + INTERVAL '22 hours 30 minutes', NOW() - INTERVAL '2 days');
SELECT x->>'to' AS para, x #>> '{message,interactive,body,text}' AS texto,
       (SELECT string_agg(b #>> '{reply,id}', ' ') FROM jsonb_array_elements(x #> '{message,interactive,action,buttons}') b) AS botones
  FROM bot_rf09_due() x;
SELECT count(*) AS segunda_pasada FROM bot_rf09_due();
\echo ==== RF-09 con plantilla aprobada
UPDATE bookings SET reminder_sent_at = NULL WHERE id = '00000000-0000-0000-0000-00000000d902';
UPDATE tenants SET settings = jsonb_set(settings, '{rf09}', '{"template": "recordatorio_turno"}') WHERE id = :T;
SELECT x #>> '{message,template,name}' AS plantilla, x #>> '{message,template,components,1,parameters,0,payload}' AS payload_boton_1 FROM bot_rf09_due() x;

\echo ==== RF-10 botones del recordatorio: confirmar, anular (con confirmación), modificar
SELECT pg_temp.m(10, 'Confirmar', 'rm:confirm:00000000-0000-0000-0000-00000000d901');
SELECT pg_temp.m(11, 'Anular', 'rm:cancel:00000000-0000-0000-0000-00000000d901');
SELECT pg_temp.m(12, 'No, lo mantengo', 'rbk:no');
SELECT pg_temp.m(13, 'Anular', 'rm:cancel:00000000-0000-0000-0000-00000000d901');
SELECT pg_temp.m(14, 'Sí, anular', 'rbk:yes');
SELECT pg_temp.m(15, 'Anular', 'rm:cancel:00000000-0000-0000-0000-00000000d901');
SELECT pg_temp.m(16, 'quiero cambiar mi turno');
SELECT id, status, cancel_reason, customer_confirmed_at IS NOT NULL AS confirmo FROM bookings WHERE tenant_id = :T ORDER BY starts_at;
SELECT pg_temp.m(17, 'cancelar');
\echo ==== RF-10 un número ajeno no puede tocar la reserva
SELECT bot_preview(bot_handle_message(jsonb_build_object('phone_number_id', 'TEST_PNID_D', 'from', '5491100000001', 'text', 'Anular',
       'reply_id', 'rm:cancel:00000000-0000-0000-0000-00000000d902', 'message_id', 'f34-ajeno'))) AS ajeno;

\echo ==== RF-11 pedidos: webhook, pedido propio, pedido ajeno con verificación, ticket de soporte
SELECT bot_rf11_ingest('hook-prueba-fase34-000000000000', jsonb_build_object('orders', jsonb_build_array(
  jsonb_build_object('external_id', 'o1', 'number', '1001', 'phone', '+54 9 11 6666-6666', 'email', 'ana@test.com', 'total', 45000,
                     'payment_status', 'paid', 'shipping_status', 'shipped', 'tracking_number', 'AR123', 'tracking_url', 'https://correo.test/AR123'),
  jsonb_build_object('external_id', 'o2', 'number', '1002', 'phone', '5491155555555', 'email', 'otro@test.com', 'tax_id', '30111222',
                     'payment_status', 'paid', 'shipping_status', 'unpacked')))) AS ingesta;
SELECT pg_temp.m(20, '¿dónde está mi pedido?');
SELECT pg_temp.m(21, 'No, todo bien', 'ord:ok');
DELETE FROM orders WHERE tenant_id = :T AND number = '1001';
SELECT pg_temp.m(22, 'quiero saber el estado de mi pedido');
SELECT pg_temp.m(23, '#9999');
SELECT pg_temp.m(24, '1002');
SELECT pg_temp.m(25, 'ana@test.com');
SELECT pg_temp.m(26, '30.111.222');
SELECT pg_temp.m(27, 'Necesito ayuda', 'ord:help');
SELECT pg_temp.m(28, 'Llegó la caja rota, quiero cambiarlo');
SELECT number IS NOT NULL AS ticket, description, (SELECT number FROM orders WHERE id = order_id) AS pedido FROM support_tickets WHERE tenant_id = :T;
SELECT pg_temp.m(29, 'tengo un reclamo');

-- Limpieza
DELETE FROM tenants WHERE id = :T;
\echo ==== FASE34_CLEAN_OK
