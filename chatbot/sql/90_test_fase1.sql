-- Tenants de prueba (A = DM Global, B = otra empresa para TC-04 aislamiento)
INSERT INTO tenants (id, name, plan_tier, settings) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'DM Global', 'pro', '{"notify": {"channel": "whatsapp", "to": null}}'),
  ('00000000-0000-0000-0000-0000000000b2', 'Tenant B (prueba)', 'starter', '{}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO whatsapp_integrations (tenant_id, phone_number_id, waba_id, access_token, webhook_verify_token) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'TEST_PNID_A', 'TEST_WABA_A', 'test-token-a', :'verify'),
  ('00000000-0000-0000-0000-0000000000b2', 'TEST_PNID_B', 'TEST_WABA_B', 'test-token-b', 'tenant-b-test')
ON CONFLICT (phone_number_id) DO NOTHING;

INSERT INTO data_sources (id, tenant_id, source_type, config) VALUES
  ('00000000-0000-0000-0000-00000000a5a1', '00000000-0000-0000-0000-0000000000a1', 'google_sheets', '{"spreadsheet_id": null, "sheet": "FAQ"}'),
  ('00000000-0000-0000-0000-00000000b5b2', '00000000-0000-0000-0000-0000000000b2', 'google_sheets', '{"spreadsheet_id": null, "sheet": "FAQ"}')
ON CONFLICT (id) DO NOTHING;

-- Carga de prueba por la misma función que usa la sincronización
SELECT bot_sync_knowledge('00000000-0000-0000-0000-00000000a5a1', '[
 {"external_key":"precio-diagnostico","category":"precios","keywords":["precio","costo","cuanto sale","cuánto cuesta","diagnóstico"],"question":"¿Cuánto cuesta el diagnóstico?","answer_text":"El diagnóstico inicial de 30 minutos es gratuito."},
 {"external_key":"brochure","category":"servicios","keywords":["brochure","catalogo","catálogo","servicios pdf"],"question":"¿Tienen un catálogo de servicios?","answer_text":"Te comparto nuestro catálogo de servicios.","media_url":"https://dmglobal.tech/catalogo.pdf","media_type":"pdf"},
 {"external_key":"horarios","category":"horarios","keywords":["horario","horarios","atienden"],"question":"¿En qué horario atienden?","answer_text":"Atendemos de lunes a viernes de 9 a 18 h (Argentina)."}
]'::jsonb) AS sync_a;
SELECT bot_sync_knowledge('00000000-0000-0000-0000-00000000b5b2', '[
 {"external_key":"precio-b","category":"precios","keywords":["precio","costo"],"question":"¿Precio?","answer_text":"RESPUESTA DEL TENANT B"}
]'::jsonb) AS sync_b;

\echo ==== TC-01 keyword
SELECT r->>'status' st, r->'messages'->0->>'text' reply FROM (SELECT bot_handle_message('{"phone_number_id":"TEST_PNID_A","from":"5491100000001","text":"Hola, ¿cuánto cuesta el diagnóstico?","message_id":"t-1"}') r) x;
\echo ==== TC-02 multimedia
SELECT r->>'status' st, r->'messages' msgs FROM (SELECT bot_handle_message('{"phone_number_id":"TEST_PNID_A","from":"5491100000001","text":"me pasás el catálogo?","message_id":"t-2"}') r) x;
\echo ==== TC-03 fallback + RF-02 lead flow
SELECT r->>'status' st, r->'messages'->0->>'text' reply, r->'notify' notify FROM (SELECT bot_handle_message('{"phone_number_id":"TEST_PNID_A","from":"5491100000002","text":"tienen sucursal en Marte?","message_id":"t-3"}') r) x;
SELECT r->>'status' st, r->'messages'->0->>'text' reply FROM (SELECT bot_handle_message('{"phone_number_id":"TEST_PNID_A","from":"5491100000002","text":"Sí","message_id":"t-4"}') r) x;
SELECT r->>'status' st, r->'messages'->0->>'text' reply FROM (SELECT bot_handle_message('{"phone_number_id":"TEST_PNID_A","from":"5491100000002","text":"Ana Pérez","message_id":"t-5"}') r) x;
SELECT r->>'status' st, r->'messages'->0->>'text' reply FROM (SELECT bot_handle_message('{"phone_number_id":"TEST_PNID_A","from":"5491100000002","text":"Automatización con n8n","message_id":"t-6"}') r) x;
SELECT r->>'status' st, r->'messages'->0->>'text' reply, r->'notify'->0->>'type' notify FROM (SELECT bot_handle_message('{"phone_number_id":"TEST_PNID_A","from":"5491100000002","text":"si, confirmo","message_id":"t-7"}') r) x;
SELECT name, product_interest, tag, phone FROM leads WHERE tenant_id = '00000000-0000-0000-0000-0000000000a1';
\echo ==== asked for agent
SELECT r->>'status' st, r->'messages'->0->>'text' reply FROM (SELECT bot_handle_message('{"phone_number_id":"TEST_PNID_A","from":"5491100000003","text":"quiero hablar con un asesor","message_id":"t-8"}') r) x;
\echo ==== TC-04 aislamiento (misma pregunta al tenant B)
SELECT r->>'tenant_name' tenant, r->'messages'->0->>'text' reply FROM (SELECT bot_handle_message('{"phone_number_id":"TEST_PNID_B","from":"5491100000001","text":"cuál es el precio?","message_id":"t-9"}') r) x;
\echo ==== numero desconocido y duplicado
SELECT bot_handle_message('{"phone_number_id":"OTRO","from":"1","text":"hola","message_id":"t-10"}') r;
SELECT bot_handle_message('{"phone_number_id":"TEST_PNID_A","from":"5491100000001","text":"precio","message_id":"t-1"}') r;
\echo ==== TC-06 logs
SELECT status, count(*) FROM interaction_logs GROUP BY status ORDER BY status;
SELECT count(*) AS handovers FROM human_handovers;

-- Limpieza: dejar solo la config de DM Global, sin datos de prueba
DELETE FROM tenants WHERE id = '00000000-0000-0000-0000-0000000000b2';
DELETE FROM interaction_logs; DELETE FROM leads; DELETE FROM human_handovers; DELETE FROM conversations;
DELETE FROM knowledge_items;
\echo ==== CLEAN_OK
