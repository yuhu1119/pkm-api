-- 产品知识模型：在 SpeedLoop「Databases」里选 SQLite，于 SQL 控制台执行。
-- 平台 Worker 一次只能跑一条 SQL；若控制台也禁止多语句，请按分号逐条执行。
-- 知识包 / 文档正文用 TEXT（SQLite 无 64KB 限制）。库体积请控制在约 1GB 配额内。

CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL DEFAULT '',
  password_hash TEXT NOT NULL DEFAULT '',
  role TEXT NOT NULL DEFAULT 'editor',
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS user_model_permissions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  model_code INTEGER NOT NULL,
  can_read INTEGER NOT NULL DEFAULT 1,
  can_write INTEGER NOT NULL DEFAULT 1,
  UNIQUE (user_id, model_code)
);

CREATE INDEX IF NOT EXISTS idx_ump_user ON user_model_permissions (user_id);

CREATE TABLE IF NOT EXISTS products (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  code TEXT NOT NULL DEFAULT '',
  description TEXT,
  owner TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'active',
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_products_name ON products (name);

CREATE TABLE IF NOT EXISTS product_relations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  from_product_id INTEGER NOT NULL,
  to_product_id INTEGER NOT NULL,
  kind TEXT NOT NULL DEFAULT 'depends',
  label TEXT NOT NULL DEFAULT '依赖',
  note TEXT
);

CREATE INDEX IF NOT EXISTS idx_pr_from ON product_relations (from_product_id);
CREATE INDEX IF NOT EXISTS idx_pr_to ON product_relations (to_product_id);

CREATE TABLE IF NOT EXISTS product_features (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  product_id INTEGER NOT NULL,
  name TEXT NOT NULL,
  summary TEXT,
  kind TEXT NOT NULL DEFAULT '功能',
  sort_order INTEGER NOT NULL DEFAULT 0,
  entity_id INTEGER
);

CREATE INDEX IF NOT EXISTS idx_pf_product ON product_features (product_id);

CREATE TABLE IF NOT EXISTS feature_relations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  from_feature_id INTEGER NOT NULL,
  to_feature_id INTEGER NOT NULL,
  kind TEXT NOT NULL DEFAULT 'depends',
  label TEXT NOT NULL DEFAULT '依赖',
  note TEXT
);

CREATE INDEX IF NOT EXISTS idx_fr_from ON feature_relations (from_feature_id);
CREATE INDEX IF NOT EXISTS idx_fr_to ON feature_relations (to_feature_id);

CREATE TABLE IF NOT EXISTS knowledge_entities (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  product_id INTEGER NOT NULL,
  type_id TEXT NOT NULL,
  name TEXT NOT NULL,
  summary TEXT,
  payload TEXT,
  tags TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'draft',
  origin TEXT NOT NULL DEFAULT 'manual',
  version INTEGER NOT NULL DEFAULT 1,
  steward_name TEXT NOT NULL DEFAULT '',
  steward_role TEXT NOT NULL DEFAULT '',
  steward_team TEXT NOT NULL DEFAULT '',
  locked INTEGER NOT NULL DEFAULT 0,
  created_by TEXT NOT NULL DEFAULT '',
  updated_by TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_ke_product ON knowledge_entities (product_id);
CREATE INDEX IF NOT EXISTS idx_ke_type ON knowledge_entities (type_id);
CREATE INDEX IF NOT EXISTS idx_ke_name ON knowledge_entities (name);

CREATE TABLE IF NOT EXISTS knowledge_type_locks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  product_id INTEGER NOT NULL,
  type_id TEXT NOT NULL,
  note TEXT,
  locked_by TEXT NOT NULL DEFAULT '',
  locked_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (product_id, type_id)
);

CREATE TABLE IF NOT EXISTS entity_references (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  from_id INTEGER NOT NULL,
  to_id INTEGER NOT NULL,
  relation TEXT NOT NULL DEFAULT '引用'
);

CREATE INDEX IF NOT EXISTS idx_er_from ON entity_references (from_id);
CREATE INDEX IF NOT EXISTS idx_er_to ON entity_references (to_id);

CREATE TABLE IF NOT EXISTS entity_versions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  entity_id INTEGER NOT NULL,
  version INTEGER NOT NULL,
  name TEXT NOT NULL,
  summary TEXT,
  payload TEXT,
  tags TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'draft',
  refs_json TEXT,
  changed_by TEXT NOT NULL DEFAULT '',
  change_note TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_ev_entity ON entity_versions (entity_id);

CREATE TABLE IF NOT EXISTS source_documents (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  product_id INTEGER NOT NULL,
  title TEXT NOT NULL,
  source_type TEXT NOT NULL,
  url TEXT,
  file_path TEXT,
  content TEXT,
  status TEXT NOT NULL DEFAULT 'ready',
  extract_status TEXT NOT NULL DEFAULT 'none',
  extract_meta TEXT,
  target_type_id TEXT NOT NULL DEFAULT '',
  error_message TEXT,
  created_by TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_sd_product ON source_documents (product_id);

CREATE TABLE IF NOT EXISTS source_bindings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source_id INTEGER NOT NULL,
  entity_id INTEGER NOT NULL,
  excerpt TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_sb_source ON source_bindings (source_id);
CREATE INDEX IF NOT EXISTS idx_sb_entity ON source_bindings (entity_id);

CREATE TABLE IF NOT EXISTS app_settings (
  setting_key TEXT PRIMARY KEY,
  value TEXT,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS knowledge_apps (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  note TEXT,
  token_prefix TEXT NOT NULL DEFAULT '',
  token_hash TEXT NOT NULL UNIQUE,
  product_ids TEXT,
  revoked INTEGER NOT NULL DEFAULT 0,
  created_by TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  last_used_at TEXT
);

CREATE TABLE IF NOT EXISTS knowledge_releases (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  version_no INTEGER NOT NULL DEFAULT 1,
  name TEXT NOT NULL DEFAULT '',
  scope TEXT NOT NULL DEFAULT 'product',
  product_ids TEXT,
  trigger_kind TEXT NOT NULL DEFAULT 'manual',
  note TEXT,
  product_count INTEGER NOT NULL DEFAULT 0,
  entity_count INTEGER NOT NULL DEFAULT 0,
  type_ready INTEGER NOT NULL DEFAULT 0,
  corpus_docs INTEGER NOT NULL DEFAULT 0,
  pack_json TEXT,
  created_by TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_kr_scope ON knowledge_releases (scope);
CREATE INDEX IF NOT EXISTS idx_kr_created ON knowledge_releases (created_at);

CREATE TABLE IF NOT EXISTS extract_skills (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,
  ref_key TEXT NOT NULL DEFAULT '',
  instruction TEXT,
  examples TEXT,
  focus_models TEXT,
  fields_json TEXT,
  updated_by TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  UNIQUE (kind, ref_key)
);

CREATE INDEX IF NOT EXISTS idx_es_kind ON extract_skills (kind);

CREATE TABLE IF NOT EXISTS audit_logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  username TEXT NOT NULL DEFAULT '',
  display_name TEXT NOT NULL DEFAULT '',
  role TEXT NOT NULL DEFAULT '',
  action TEXT NOT NULL DEFAULT 'other',
  category TEXT NOT NULL DEFAULT '',
  resource TEXT NOT NULL DEFAULT '',
  summary TEXT NOT NULL DEFAULT '',
  method TEXT NOT NULL DEFAULT '',
  path TEXT NOT NULL DEFAULT '',
  status_code INTEGER NOT NULL DEFAULT 0,
  ip TEXT NOT NULL DEFAULT '',
  product_id INTEGER,
  detail TEXT
);

CREATE INDEX IF NOT EXISTS idx_al_created ON audit_logs (created_at);
CREATE INDEX IF NOT EXISTS idx_al_user ON audit_logs (username);
CREATE INDEX IF NOT EXISTS idx_al_action ON audit_logs (action);
