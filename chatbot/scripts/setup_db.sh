#!/bin/sh
# Crea el rol/base "chatbot" en el Postgres compartido, aplica el esquema y (opcional) corre las pruebas de fase 1.
# Variables: PG_ADMIN_PASSWORD, CHATBOT_DB_PASSWORD, VERIFY_TOKEN, SQL_DIR, RUN_TESTS=1|0
set -e
export PGHOST=${PGHOST:-dmglobal-postgres}
until pg_isready -d postgres; do sleep 2; done
PGUSER=dbadmin PGPASSWORD="$PG_ADMIN_PASSWORD" psql -d postgres -v ON_ERROR_STOP=1 -v pw="$CHATBOT_DB_PASSWORD" <<'SQL'
SELECT 'CREATE ROLE chatbot LOGIN' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='chatbot') \gexec
ALTER ROLE chatbot WITH LOGIN PASSWORD :'pw';
SELECT 'CREATE DATABASE chatbot OWNER chatbot' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='chatbot') \gexec
SQL
export PGUSER=chatbot PGPASSWORD="$CHATBOT_DB_PASSWORD"
# Esquema y funciones: todos los archivos 0x-8x en orden (cada uno es idempotente)
for f in "$SQL_DIR"/[0-8]*.sql; do
  psql -d chatbot -v ON_ERROR_STOP=1 -q -f "$f" && echo "OK $(basename "$f")"
done
# Pruebas: archivos 9x (cada una crea sus datos de prueba y los borra al terminar)
if [ "${RUN_TESTS:-1}" = "1" ]; then
  for f in "$SQL_DIR"/9*.sql; do
    psql -d chatbot -v ON_ERROR_STOP=1 -v verify="$VERIFY_TOKEN" -f "$f"
  done
fi
echo ALL_DONE
