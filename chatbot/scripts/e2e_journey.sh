#!/bin/sh
# Prueba de punta a punta del recorrido de servicio por n8n, con un tenant temporal (TEST_PNID_J).
# MODE=seed   crea el tenant, conversa (menú, consulta, contratar, datos, pagar), abre el link de pago simulado y elige turno
# MODE=verify después de correr JOURNEY-POSTVENTA (import_n8n.sh con EXECUTE=jrnyPostventa001): revisa la encuesta, la responde y limpia
# Variables: CHATBOT_DB_PASSWORD, N8N_URL (por defecto http://dmglobal-n8n:5678), CLEAN (1 por defecto)
N8N_URL=${N8N_URL:-http://dmglobal-n8n:5678}
export PGHOST=dmglobal-postgres PGUSER=chatbot PGPASSWORD="$CHATBOT_DB_PASSWORD"
Q() { psql -d chatbot -Atq -c "$1"; }
T=00000000-0000-0000-0000-0000000000e4
S=00000000-0000-0000-0000-00000000e401
E=5491177711111
send() {
  wget -qO /dev/null --header='Content-Type: application/json' --post-data="{\"object\":\"whatsapp_business_account\",\"entry\":[{\"id\":\"W\",\"changes\":[{\"field\":\"messages\",\"value\":{\"messaging_product\":\"whatsapp\",\"metadata\":{\"display_phone_number\":\"5491100000000\",\"phone_number_id\":\"TEST_PNID_J\"},\"contacts\":[{\"profile\":{\"name\":\"Prueba Recorrido\"},\"wa_id\":\"$E\"}],\"messages\":[{\"from\":\"$E\",\"id\":\"wamid.E2EJ-$1-$(date +%s)\",\"timestamp\":\"1\",$2}]}}]}]}" "$N8N_URL/webhook/whatsapp"
  sleep 3
}
txt() { send "$1" "\"type\":\"text\",\"text\":{\"body\":\"$2\"}"; }
btn() { send "$1" "\"type\":\"interactive\",\"interactive\":{\"type\":\"button_reply\",\"button_reply\":{\"id\":\"$2\",\"title\":\"$3\"}}"; }
lst() { send "$1" "\"type\":\"interactive\",\"interactive\":{\"type\":\"list_reply\",\"list_reply\":{\"id\":\"$2\",\"title\":\"$3\"}}"; }
ORD="SELECT id FROM service_orders WHERE tenant_id = '$T' ORDER BY created_at DESC LIMIT 1"
LOG="SELECT to_char(created_at,'HH24:MI:SS'), incoming_message, status, left(replace(reply_text, chr(10), ' '), 110) FROM interaction_logs WHERE sender_phone = '$E' ORDER BY created_at"
STATE="SELECT 'compra #' || number || ': ' || status || CASE WHEN checkout_url IS NOT NULL THEN ' · con link' ELSE '' END || CASE WHEN booking_id IS NOT NULL THEN ' · con turno' ELSE '' END || CASE WHEN survey_sent_at IS NOT NULL THEN ' · encuesta enviada' ELSE '' END || coalesce(' · nota ' || rating, '') FROM service_orders WHERE tenant_id = '$T'"

if [ "${MODE:-seed}" = "seed" ]; then
  Q "DELETE FROM interaction_logs WHERE tenant_id = '$T'; DELETE FROM tenants WHERE id = '$T'"
  Q "INSERT INTO tenants (id, name, plan_tier, settings) VALUES ('$T', 'E2E Recorrido', 'pro',
       '{\"features\": {\"journey\": true, \"rf03\": true, \"rf10\": true, \"rf11\": true}, \"journey\": {\"review_url\": \"https://g.page/r/e2e/review\"}}');
     INSERT INTO whatsapp_integrations (tenant_id, phone_number_id, waba_id, access_token, webhook_verify_token) VALUES ('$T', 'TEST_PNID_J', 'W', 'test-token-j', 'e2e-j');
     INSERT INTO email_integrations (tenant_id, provider, from_email) VALUES ('$T', 'mock', 'hola@e2e.test');
     INSERT INTO payment_integrations (tenant_id, provider) VALUES ('$T', 'mock');
     INSERT INTO services (id, tenant_id, name, description, duration_min, price, sort_order, bookable) VALUES ('$S', '$T', 'Sesión de diagnóstico', 'Relevamiento de 60 minutos', 60, 30000, 1, true);
     INSERT INTO availability_rules (tenant_id, weekday, start_time, end_time, slot_min) SELECT '$T', d, '00:00', '23:59', 60 FROM generate_series(0, 6) d;
     INSERT INTO knowledge_items (tenant_id, external_key, keywords, question, answer_text) VALUES ('$T', 'horario', '{horario,horarios}', '¿Cuál es el horario?', 'Atendemos de lunes a viernes de 9 a 18 h.');" && echo SEED_OK

  echo "== Menú, consulta y contratación por WhatsApp"
  txt 1 "Hola"
  btn 2 "j:faq" "Hacer una consulta"
  txt 3 "qué horarios tienen?"
  btn 4 "j:hire" "Contratar"
  lst 5 "sv:$S" "Sesión de diagnóstico"
  txt 6 "Juan Pérez"
  txt 7 "juan@e2e.test"
  btn 8 "j:pay" "Sí, pagar"
  sleep 3
  Q "$STATE"
  URL=$(Q "SELECT checkout_url FROM service_orders WHERE tenant_id = '$T'" | sed "s#^https\?://[^/]*#$N8N_URL#")
  echo "== Link de pago simulado: $(echo "$URL" | grep -o '/webhook/servicio-mock')"
  wget -qO- "$URL"; echo
  wget -qO- "$URL"; echo
  sleep 3
  Q "$STATE"
  Q "SELECT 'email ' || kind || ' → ' || to_email FROM email_outbox WHERE tenant_id = '$T'"

  echo "== Turno después del pago"
  O=$(Q "$ORD")
  btn 9 "j:book:$O" "Elegir turno"
  txt 10 "2"
  txt 11 "1"
  btn 12 "bk:confirm" "Confirmar"
  sleep 3
  psql -d chatbot -c "$LOG"
  Q "$STATE"
  # Para que la tarea programada mande la encuesta: el turno ya terminó hace 3 horas
  Q "UPDATE bookings SET starts_at = NOW() - INTERVAL '4 hours', ends_at = NOW() - INTERVAL '3 hours' WHERE tenant_id = '$T'"
  echo SEED_DONE
else
  echo "== Resultado de JOURNEY-POSTVENTA"
  Q "$STATE"
  O=$(Q "$ORD")
  btn 20 "jr:5:$O" "Muy bien"
  sleep 3
  Q "$STATE"
  Q "SELECT left(replace(reply_text, chr(10), ' '), 140) FROM interaction_logs WHERE sender_phone = '$E' ORDER BY created_at DESC LIMIT 1"
  Q "SELECT 'emails: ' || string_agg(kind || ' ' || status, ', ') FROM email_outbox WHERE tenant_id = '$T'"
  if [ "${CLEAN:-1}" = "1" ]; then
    Q "DELETE FROM interaction_logs WHERE tenant_id = '$T'; DELETE FROM human_handovers WHERE tenant_id = '$T'; DELETE FROM tenants WHERE id = '$T';" && echo CLEAN_OK
  fi
fi
