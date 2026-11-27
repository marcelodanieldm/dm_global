#!/bin/sh
# Prueba de punta a punta del webhook con payloads simulados de Meta (tenant de prueba TEST_PNID_A).
# Variables: VERIFY_TOKEN, CHATBOT_DB_PASSWORD, N8N_URL (por defecto http://dmglobal-n8n:5678)
N8N_URL=${N8N_URL:-http://dmglobal-n8n:5678}
echo "== GET verificación (token correcto / incorrecto)"
wget -qO- "$N8N_URL/webhook/whatsapp?hub.mode=subscribe&hub.verify_token=$VERIFY_TOKEN&hub.challenge=CHALLENGE_OK"; echo
wget -S -qO- "$N8N_URL/webhook/whatsapp?hub.mode=subscribe&hub.verify_token=malo&hub.challenge=X" 2>&1 | grep -m1 'HTTP/' || true
echo "== GET público por HTTPS"
wget -qO- "https://n8n.dmglobal.tech/webhook/whatsapp?hub.mode=subscribe&hub.verify_token=$VERIFY_TOKEN&hub.challenge=PUBLIC_OK"; echo
send() {
  wget -qO- --header='Content-Type: application/json' --post-data="{\"object\":\"whatsapp_business_account\",\"entry\":[{\"id\":\"TEST_WABA_A\",\"changes\":[{\"field\":\"messages\",\"value\":{\"messaging_product\":\"whatsapp\",\"metadata\":{\"display_phone_number\":\"5491100000000\",\"phone_number_id\":\"TEST_PNID_A\"},\"contacts\":[{\"profile\":{\"name\":\"Prueba\"},\"wa_id\":\"5491199999999\"}],\"messages\":[{\"from\":\"5491199999999\",\"id\":\"wamid.E2E$1\",\"timestamp\":\"1\",\"type\":\"text\",\"text\":{\"body\":\"$2\"}}]}}]}]}" "$N8N_URL/webhook/whatsapp"; echo
  sleep 3
}
echo "== POST mensajes"
send 1 "Hola"
send 2 "tienen local en Rosario?"
send 3 "si"
send 4 "Prueba E2E"
send 5 "Chatbot para mi negocio"
send 6 "si"
sleep 5
export PGHOST=dmglobal-postgres PGUSER=chatbot PGPASSWORD="$CHATBOT_DB_PASSWORD"
psql -d chatbot -c "SELECT created_at::time(0), incoming_message, status, left(reply_text, 60) AS reply FROM interaction_logs WHERE wa_message_id LIKE 'wamid.E2E%' ORDER BY created_at;"
psql -d chatbot -c "SELECT name, product_interest, tag FROM leads WHERE phone = '5491199999999';"
if [ "${CLEAN:-1}" = "1" ]; then
  psql -d chatbot -q -c "DELETE FROM interaction_logs WHERE sender_phone = '5491199999999'; DELETE FROM leads WHERE phone = '5491199999999'; DELETE FROM human_handovers WHERE phone = '5491199999999'; DELETE FROM conversations WHERE phone = '5491199999999';" && echo CLEAN_OK
fi
