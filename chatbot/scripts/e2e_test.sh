#!/bin/sh
# Prueba de punta a punta del webhook con payloads simulados de Meta.
# Fase 1 con el tenant de prueba TEST_PNID_A; fase 2 con un tenant temporal TEST_PNID_C (reservas + suscripción con pago simulado).
# Variables: VERIFY_TOKEN, CHATBOT_DB_PASSWORD, N8N_URL (por defecto http://dmglobal-n8n:5678)
N8N_URL=${N8N_URL:-http://dmglobal-n8n:5678}
export PGHOST=dmglobal-postgres PGUSER=chatbot PGPASSWORD="$CHATBOT_DB_PASSWORD"
Q() { psql -d chatbot -Atq -c "$1"; }

echo "== GET verificación (token correcto / incorrecto)"
wget -qO- "$N8N_URL/webhook/whatsapp?hub.mode=subscribe&hub.verify_token=$VERIFY_TOKEN&hub.challenge=CHALLENGE_OK"; echo
wget -S -qO- "$N8N_URL/webhook/whatsapp?hub.mode=subscribe&hub.verify_token=malo&hub.challenge=X" 2>&1 | grep -m1 'HTTP/' || true
echo "== GET público por HTTPS"
wget -qO- "https://n8n.dmglobal.tech/webhook/whatsapp?hub.mode=subscribe&hub.verify_token=$VERIFY_TOKEN&hub.challenge=PUBLIC_OK"; echo

# send <pnid> <from> <n> <message-json>
send() {
  wget -qO /dev/null --header='Content-Type: application/json' --post-data="{\"object\":\"whatsapp_business_account\",\"entry\":[{\"id\":\"W\",\"changes\":[{\"field\":\"messages\",\"value\":{\"messaging_product\":\"whatsapp\",\"metadata\":{\"display_phone_number\":\"5491100000000\",\"phone_number_id\":\"$1\"},\"contacts\":[{\"profile\":{\"name\":\"Prueba E2E\"},\"wa_id\":\"$2\"}],\"messages\":[{\"from\":\"$2\",\"id\":\"wamid.E2E$3\",\"timestamp\":\"1\",$4}]}}]}]}" "$N8N_URL/webhook/whatsapp"
  sleep 3
}
txt() { send "$1" "$2" "$3" "\"type\":\"text\",\"text\":{\"body\":\"$4\"}"; }
lst() { send "$1" "$2" "$3" "\"type\":\"interactive\",\"interactive\":{\"type\":\"list_reply\",\"list_reply\":{\"id\":\"$4\",\"title\":\"$5\"}}"; }
btn() { send "$1" "$2" "$3" "\"type\":\"interactive\",\"interactive\":{\"type\":\"button_reply\",\"button_reply\":{\"id\":\"$4\",\"title\":\"$5\"}}"; }
LOG="SELECT to_char(created_at,'HH24:MI:SS'), incoming_message, status, left(replace(reply_text, chr(10), ' '), 90) FROM interaction_logs WHERE sender_phone = '%s' ORDER BY created_at"

echo "== FASE 1 (TEST_PNID_A)"
A=5491199999999
txt TEST_PNID_A $A 1 "Hola"
txt TEST_PNID_A $A 2 "tienen local en Rosario?"
btn TEST_PNID_A $A 3 "lead:yes" "Sí, que me contacten"
txt TEST_PNID_A $A 4 "Prueba E2E"
txt TEST_PNID_A $A 5 "Chatbot para mi negocio"
btn TEST_PNID_A $A 6 "lead:confirm" "Sí, confirmar"
sleep 3
psql -d chatbot -c "$(printf "$LOG" $A)"
Q "SELECT 'lead: ' || name || ' / ' || product_interest || ' / ' || tag FROM leads WHERE phone = '$A'"

echo "== FASE 2 (tenant temporal TEST_PNID_C)"
C=5491188888888
T=00000000-0000-0000-0000-0000000000e2
Q "INSERT INTO tenants (id, name, plan_tier, settings) VALUES ('$T', 'E2E Fase 2', 'pro', '{\"features\": {\"rf03\": true, \"rf04\": true}}') ON CONFLICT (id) DO NOTHING;
   INSERT INTO whatsapp_integrations (tenant_id, phone_number_id, waba_id, access_token, webhook_verify_token) VALUES ('$T', 'TEST_PNID_C', 'W', 'test-token-c', 'e2e-c') ON CONFLICT DO NOTHING;
   INSERT INTO services (id, tenant_id, name, duration_min) VALUES ('00000000-0000-0000-0000-00000000e501', '$T', 'Consulta', 30) ON CONFLICT DO NOTHING;
   INSERT INTO availability_rules (tenant_id, weekday, start_time, end_time) SELECT '$T', d, '09:00', '18:00' FROM generate_series(0, 6) d;
   INSERT INTO subscription_plans (tenant_id, code, name, price) VALUES ('$T', 'mensual', 'Mensual', 9900) ON CONFLICT DO NOTHING;
   INSERT INTO payment_integrations (tenant_id, provider) VALUES ('$T', 'mock') ON CONFLICT DO NOTHING;"
DAY=$(Q "SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date + 2")
txt TEST_PNID_C $C 11 "quiero un turno"
lst TEST_PNID_C $C 12 "d:$DAY" "dia"
txt TEST_PNID_C $C 13 "1"
btn TEST_PNID_C $C 14 "bk:confirm" "Confirmar"
txt TEST_PNID_C $C 15 "planes"
lst TEST_PNID_C $C 16 "p:mensual" "Mensual"
txt TEST_PNID_C $C 17 "Cliente E2E"
txt TEST_PNID_C $C 18 "e2e@example.com"
txt TEST_PNID_C $C 19 "20123456"
btn TEST_PNID_C $C 20 "sub:confirm" "Sí, generar link"
sleep 6
psql -d chatbot -c "$(printf "$LOG" $C)"
Q "SELECT 'reserva: ' || customer_name || ' ' || to_char(starts_at AT TIME ZONE 'America/Argentina/Buenos_Aires', 'DD/MM HH24:MI') || ' ' || status FROM bookings WHERE tenant_id = '$T'"
URL=$(Q "SELECT checkout_url FROM subscriptions WHERE tenant_id = '$T'")
echo "link de pago: $URL"
Q "SELECT 'suscripción antes del pago: ' || status FROM subscriptions WHERE tenant_id = '$T'"
[ -n "$URL" ] && wget -qO- "$(echo "$URL" | sed "s#https://n8n.dmglobal.tech#$N8N_URL#")"; echo
sleep 4
Q "SELECT 'suscripción después del pago: ' || status || ', vence ' || to_char(current_period_end, 'DD/MM/YYYY') FROM subscriptions WHERE tenant_id = '$T'"

if [ "${CLEAN:-1}" = "1" ]; then
  Q "DELETE FROM interaction_logs WHERE sender_phone IN ('$A', '$C'); DELETE FROM leads WHERE phone = '$A';
     DELETE FROM human_handovers WHERE phone IN ('$A', '$C'); DELETE FROM conversations WHERE phone IN ('$A', '$C');
     DELETE FROM payment_events WHERE tenant_id = '$T'; DELETE FROM subscriptions WHERE tenant_id = '$T';
     DELETE FROM bookings WHERE tenant_id = '$T'; DELETE FROM tenants WHERE id = '$T';" && echo CLEAN_OK
fi
