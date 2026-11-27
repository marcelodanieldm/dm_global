#!/bin/sh
# Prueba de punta a punta de las fases 3 y 4 por n8n, con un tenant temporal (TEST_PNID_E).
# MODE=seed   crea el tenant, usa los webhooks (carrito, pedido, baja) y conversa por WhatsApp (RF-10, RF-11)
# MODE=verify revisa lo que dejaron las tareas programadas (correr antes import_n8n.sh con EXECUTE=...) y limpia
# Variables: CHATBOT_DB_PASSWORD, N8N_URL (por defecto http://dmglobal-n8n:5678), CLEAN (1 por defecto)
N8N_URL=${N8N_URL:-http://dmglobal-n8n:5678}
export PGHOST=dmglobal-postgres PGUSER=chatbot PGPASSWORD="$CHATBOT_DB_PASSWORD"
Q() { psql -d chatbot -Atq -c "$1"; }
T=00000000-0000-0000-0000-0000000000e3
KEY=e2e-fase34-hook-000000000000
E=5491177700000
post() { wget -qO- --header='Content-Type: application/json' --post-data="$2" "$N8N_URL/webhook/$1"; echo; }
send() {
  wget -qO /dev/null --header='Content-Type: application/json' --post-data="{\"object\":\"whatsapp_business_account\",\"entry\":[{\"id\":\"W\",\"changes\":[{\"field\":\"messages\",\"value\":{\"messaging_product\":\"whatsapp\",\"metadata\":{\"display_phone_number\":\"5491100000000\",\"phone_number_id\":\"TEST_PNID_E\"},\"contacts\":[{\"profile\":{\"name\":\"Prueba E2E\"},\"wa_id\":\"$E\"}],\"messages\":[{\"from\":\"$E\",\"id\":\"wamid.E2E34-$1-$(date +%s)\",\"timestamp\":\"1\",$2}]}}]}]}" "$N8N_URL/webhook/whatsapp"
  sleep 3
}
txt() { send "$1" "\"type\":\"text\",\"text\":{\"body\":\"$2\"}"; }
btn() { send "$1" "\"type\":\"interactive\",\"interactive\":{\"type\":\"button_reply\",\"button_reply\":{\"id\":\"$2\",\"title\":\"$3\"}}"; }
tpl() { send "$1" "\"type\":\"button\",\"button\":{\"payload\":\"$2\",\"text\":\"$3\"}"; }
LOG="SELECT to_char(created_at,'HH24:MI:SS'), incoming_message, status, left(replace(reply_text, chr(10), ' '), 100) FROM interaction_logs WHERE sender_phone = '$E' ORDER BY created_at"

if [ "${MODE:-seed}" = "seed" ]; then
  Q "DELETE FROM tenants WHERE id = '$T'"
  Q "INSERT INTO tenants (id, name, plan_tier, hook_secret, settings) VALUES ('$T', 'E2E Fase 3-4', 'pro', '$KEY',
       '{\"features\": {\"rf03\": true, \"rf05\": true, \"rf06\": true, \"rf07\": true, \"rf08\": true, \"rf09\": true, \"rf10\": true, \"rf11\": true}}');
     INSERT INTO whatsapp_integrations (tenant_id, phone_number_id, waba_id, access_token, webhook_verify_token) VALUES ('$T', 'TEST_PNID_E', 'W', 'test-token-e', 'e2e-e');
     INSERT INTO email_integrations (tenant_id, provider, from_email) VALUES ('$T', 'mock', 'hola@e2e.test');
     INSERT INTO payment_integrations (tenant_id, provider) VALUES ('$T', 'mock');
     INSERT INTO services (id, tenant_id, name, duration_min) VALUES ('00000000-0000-0000-0000-00000000e301', '$T', 'Consulta', 30);
     INSERT INTO availability_rules (tenant_id, weekday, start_time, end_time) SELECT '$T', d, '00:00', '23:59' FROM generate_series(0, 6) d;
     INSERT INTO subscription_plans (id, tenant_id, code, name, price) VALUES ('00000000-0000-0000-0000-00000000e302', '$T', 'mensual', 'Mensual', 9900);
     INSERT INTO customers (id, tenant_id, phone, name, email) VALUES ('00000000-0000-0000-0000-00000000e303', '$T', '$E', 'Cliente E2E', 'e2e@example.com');
     INSERT INTO subscriptions (tenant_id, customer_id, plan_id, status, provider, provider_ref, current_period_end, activated_at, manage_token) VALUES
       ('$T', '00000000-0000-0000-0000-00000000e303', '00000000-0000-0000-0000-00000000e302', 'active', 'mock', 'mock-1', NOW() + INTERVAL '2 days', NOW(), 'e2e-renueva-000000000000'),
       ('$T', '00000000-0000-0000-0000-00000000e303', '00000000-0000-0000-0000-00000000e302', 'active', 'mock', 'mock-2', NOW() + INTERVAL '20 days', NOW(), 'e2e-baja-0000000000000000');
     INSERT INTO bookings (id, tenant_id, service_id, phone, customer_name, starts_at, ends_at, created_at) VALUES
       ('00000000-0000-0000-0000-00000000e304', '$T', '00000000-0000-0000-0000-00000000e301', '$E', 'Cliente E2E',
        date_trunc('hour', NOW()) + INTERVAL '20 hours', date_trunc('hour', NOW()) + INTERVAL '20 hours 30 minutes', NOW() - INTERVAL '1 day'),
       ('00000000-0000-0000-0000-00000000e305', '$T', '00000000-0000-0000-0000-00000000e301', '$E', 'Cliente E2E',
        date_trunc('hour', NOW()) + INTERVAL '50 hours', date_trunc('hour', NOW()) + INTERVAL '50 hours 30 minutes', NOW() - INTERVAL '1 day');" && echo SEED_OK

  echo "== RF-05 webhook de carrito (clave mala / buena)"
  post "rf05-carrito?key=mala" '{"external_id":"x"}'
  post "rf05-carrito?key=$KEY" "{\"carts\":[{\"external_id\":\"e2e-1\",\"name\":\"Cliente E2E\",\"email\":\"e2e@example.com\",\"total\":30000,\"checkout_url\":\"https://tienda.test/c/e2e-1\",\"items\":[{\"name\":\"Remera\",\"quantity\":2,\"price\":15000}],\"updated_at\":\"$(Q "SELECT (NOW() - INTERVAL '5 hours')::text")\"}]}"

  echo "== RF-11 webhook de pedido"
  wget -qO /dev/null --header='Content-Type: application/json' --post-data="{\"orders\":[{\"external_id\":\"e2e-o1\",\"number\":\"5001\",\"phone\":\"$E\",\"email\":\"e2e@example.com\",\"total\":30000,\"payment_status\":\"paid\",\"shipping_status\":\"shipped\",\"tracking_number\":\"AR999\",\"tracking_url\":\"https://correo.test/AR999\"}]}" "$N8N_URL/webhook/rf11-pedido?key=$KEY"
  sleep 3
  Q "SELECT 'pedido guardado: #' || number || ' ' || shipping_status FROM orders WHERE tenant_id = '$T'"

  echo "== RF-08 página de baja y confirmación"
  wget -qO- "$N8N_URL/webhook/suscripcion?t=e2e-baja-0000000000000000" | grep -o 'Cancelar mi suscripción\|Mensual' | sort -u | tr '\n' ' '; echo
  wget -qO- "$N8N_URL/webhook/suscripcion?t=inexistente" | grep -o 'Link inválido'
  wget -qO- --post-data="t=e2e-baja-0000000000000000" "$N8N_URL/webhook/suscripcion-baja" | grep -o 'cancelamos tu suscripción'
  sleep 3
  Q "SELECT 'baja: ' || status || ' · ' || coalesce(cancel_reason, '') FROM subscriptions WHERE manage_token = 'e2e-baja-0000000000000000'"

  echo "== RF-08, RF-10 y RF-11 por WhatsApp"
  txt 1 "quiero dar de baja mi suscripción"
  tpl 2 "rm:confirm:00000000-0000-0000-0000-00000000e304" "Confirmar"
  btn 3 "rm:cancel:00000000-0000-0000-0000-00000000e305" "Anular"
  btn 4 "rbk:yes" "Sí, anular"
  txt 5 "dónde está mi pedido"
  btn 6 "ord:help" "Necesito ayuda"
  txt 7 "El paquete llegó abierto"
  sleep 3
  psql -d chatbot -c "$LOG"
  Q "SELECT 'reserva ' || right(id::text, 3) || ': ' || status || coalesce(' · ' || cancel_reason, '') || CASE WHEN customer_confirmed_at IS NOT NULL THEN ' · confirmó' ELSE '' END FROM bookings WHERE tenant_id = '$T' ORDER BY starts_at"
  Q "SELECT 'ticket #' || number || ': ' || description FROM support_tickets WHERE tenant_id = '$T'"
  echo SEED_DONE
else
  echo "== Resultado de las tareas programadas"
  Q "SELECT 'email ' || kind || ' → ' || to_email || ' · ' || status || coalesce(' · ' || provider_ref, '') FROM email_outbox WHERE tenant_id = '$T' ORDER BY created_at"
  Q "SELECT 'carrito ' || external_id || ': ' || coalesce(reminder_status, 'sin aviso') FROM carts WHERE tenant_id = '$T'"
  Q "SELECT 'recordatorio RF-09 de ' || right(id::text, 3) || ': ' || CASE WHEN reminder_sent_at IS NULL THEN 'no' ELSE 'enviado' END FROM bookings WHERE tenant_id = '$T' ORDER BY starts_at"
  if [ "${CLEAN:-1}" = "1" ]; then
    Q "DELETE FROM interaction_logs WHERE tenant_id = '$T'; DELETE FROM human_handovers WHERE tenant_id = '$T'; DELETE FROM tenants WHERE id = '$T';" && echo CLEAN_OK
  fi
fi
