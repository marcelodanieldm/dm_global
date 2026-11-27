#!/bin/sh
# Importa la credencial Postgres y los workflows de chatbot/n8n/workflows en n8n, y activa los que tienen trigger.
# Corre dentro de la imagen de n8n con las mismas variables DB_* y N8N_ENCRYPTION_KEY que la instancia principal.
# Variables extra: CHATBOT_DB_PASSWORD, SRC (carpeta del repo), ACTIVATE (ids separados por espacio),
# SKIP_IMPORT=1 para no reimportar, EXECUTE (ids a ejecutar una vez desde su disparador manual, para pruebas)
set -e
cat > /tmp/cred.json <<JSON
[{"id":"pgChatbotCred01","name":"Postgres chatbot","type":"postgres",
  "data":{"host":"dmglobal-postgres","database":"chatbot","user":"chatbot","password":"$CHATBOT_DB_PASSWORD","port":5432,"ssl":"disable"}}]
JSON
if [ "${SKIP_IMPORT:-0}" != "1" ]; then
n8n import:credentials --input=/tmp/cred.json && echo CRED_OK
n8n import:workflow --separate --input="$SRC/chatbot/n8n/workflows" && echo WF_OK
fi
rm -f /tmp/cred.json
for id in $ACTIVATE; do
  (n8n publish:workflow --id="$id" 2>&1 || n8n update:workflow --id="$id" --active=true 2>&1) | tail -2
done
n8n list:workflow 2>/dev/null || true
for id in $EXECUTE; do
  echo "== execute $id"
  n8n execute --id="$id" 2>&1 | tail -4 || true
done
echo IMPORT_DONE
