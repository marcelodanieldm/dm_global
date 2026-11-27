-- Chatbot AI Low-cost · Fase 1 (RF-01 FAQs + RF-02 Leads) · esquema multi-tenant
-- Idempotente: se puede volver a correr sin perder datos.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;

CREATE TABLE IF NOT EXISTS plans (
  tier VARCHAR(50) PRIMARY KEY,
  monthly_message_limit INTEGER            -- NULL = sin límite
);
INSERT INTO plans VALUES ('starter', 1000), ('pro', 5000), ('enterprise', NULL)
ON CONFLICT (tier) DO NOTHING;

CREATE TABLE IF NOT EXISTS tenants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(150) NOT NULL,
  plan_tier VARCHAR(50) NOT NULL DEFAULT 'starter' REFERENCES plans(tier),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  settings JSONB NOT NULL DEFAULT '{}'::jsonb,   -- textos del bot y canal de aviso a ventas
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS whatsapp_integrations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  phone_number_id VARCHAR(100) UNIQUE NOT NULL,
  waba_id VARCHAR(100) NOT NULL,
  access_token TEXT NOT NULL,
  webhook_verify_token VARCHAR(255) NOT NULL,
  graph_version VARCHAR(10) NOT NULL DEFAULT 'v21.0',
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS data_sources (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  source_type VARCHAR(30) NOT NULL CHECK (source_type IN ('google_sheets', 'odoo')),
  config JSONB NOT NULL DEFAULT '{}'::jsonb,     -- sheets: {spreadsheet_id, sheet}; odoo: {url, db, user, model}
  sync_interval_min INTEGER NOT NULL DEFAULT 30,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  last_synced_at TIMESTAMPTZ,
  last_status TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS knowledge_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  source_id UUID REFERENCES data_sources(id) ON DELETE SET NULL,
  external_key TEXT NOT NULL,
  category VARCHAR(100),
  keywords TEXT[] NOT NULL DEFAULT '{}',
  question TEXT NOT NULL,
  answer_text TEXT NOT NULL,
  media_url TEXT,
  media_type VARCHAR(20) CHECK (media_type IN ('image', 'document') OR media_type IS NULL),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, external_key)
);
CREATE INDEX IF NOT EXISTS knowledge_items_tenant_idx ON knowledge_items (tenant_id) WHERE is_active;

CREATE TABLE IF NOT EXISTS interaction_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES tenants(id) ON DELETE CASCADE,
  channel VARCHAR(20) NOT NULL DEFAULT 'whatsapp',
  wa_message_id TEXT UNIQUE,
  sender_phone VARCHAR(50) NOT NULL,
  incoming_message TEXT NOT NULL,
  matched_knowledge_id UUID REFERENCES knowledge_items(id) ON DELETE SET NULL,
  match_score REAL,
  reply_text TEXT,
  status VARCHAR(50) NOT NULL,   -- resolved, escalated_rf02, unrecognized, lead_flow, lead_created, greeting, quota_exceeded
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS interaction_logs_tenant_month_idx ON interaction_logs (tenant_id, created_at);

CREATE TABLE IF NOT EXISTS conversations (
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  phone VARCHAR(50) NOT NULL,
  state VARCHAR(30) NOT NULL,     -- offer_lead, lead_name, lead_product, lead_confirm
  data JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (tenant_id, phone)
);

CREATE TABLE IF NOT EXISTS leads (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  phone VARCHAR(50) NOT NULL,
  name VARCHAR(150) NOT NULL,
  product_interest TEXT NOT NULL,
  tag VARCHAR(100) NOT NULL DEFAULT 'Lead Calificado - Chatbot',
  source VARCHAR(30) NOT NULL DEFAULT 'whatsapp',
  status VARCHAR(30) NOT NULL DEFAULT 'new',
  crm_sync_status VARCHAR(30) NOT NULL DEFAULT 'pending',   -- pending, synced, failed, not_configured
  crm_ref TEXT,
  notified_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS human_handovers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  phone VARCHAR(50) NOT NULL,
  message TEXT NOT NULL,
  reason VARCHAR(50) NOT NULL,     -- unrecognized, asked_for_agent
  status VARCHAR(30) NOT NULL DEFAULT 'open',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Las funciones del motor están en 10_motor.sql y en un archivo por flujo (20_rf03, 30_rf04...).
