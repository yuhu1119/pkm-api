-- 产品知识模型：在 SpeedLoop MySQL 控制台执行一次。
-- 知识包 / 文档正文使用 LONGTEXT，避免超过 64KB。

CREATE TABLE IF NOT EXISTS users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(64) NOT NULL UNIQUE,
  display_name VARCHAR(64) NOT NULL DEFAULT '',
  password_hash VARCHAR(256) NOT NULL DEFAULT '',
  role VARCHAR(16) NOT NULL DEFAULT 'editor',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS user_model_permissions (
  id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT NOT NULL,
  model_code INT NOT NULL,
  can_read INT NOT NULL DEFAULT 1,
  can_write INT NOT NULL DEFAULT 1,
  UNIQUE KEY uq_user_model (user_id, model_code),
  CONSTRAINT fk_ump_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS products (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(128) NOT NULL,
  code VARCHAR(64) NOT NULL DEFAULT '',
  description TEXT,
  owner VARCHAR(64) NOT NULL DEFAULT '',
  status VARCHAR(16) NOT NULL DEFAULT 'active',
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  KEY idx_products_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS product_relations (
  id INT AUTO_INCREMENT PRIMARY KEY,
  from_product_id INT NOT NULL,
  to_product_id INT NOT NULL,
  kind VARCHAR(32) NOT NULL DEFAULT 'depends',
  label VARCHAR(64) NOT NULL DEFAULT '依赖',
  note TEXT,
  KEY idx_pr_from (from_product_id),
  KEY idx_pr_to (to_product_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS product_features (
  id INT AUTO_INCREMENT PRIMARY KEY,
  product_id INT NOT NULL,
  name VARCHAR(128) NOT NULL,
  summary TEXT,
  kind VARCHAR(16) NOT NULL DEFAULT '功能',
  sort_order INT NOT NULL DEFAULT 0,
  entity_id INT NULL,
  KEY idx_pf_product (product_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS feature_relations (
  id INT AUTO_INCREMENT PRIMARY KEY,
  from_feature_id INT NOT NULL,
  to_feature_id INT NOT NULL,
  kind VARCHAR(32) NOT NULL DEFAULT 'depends',
  label VARCHAR(64) NOT NULL DEFAULT '依赖',
  note TEXT,
  KEY idx_fr_from (from_feature_id),
  KEY idx_fr_to (to_feature_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS knowledge_entities (
  id INT AUTO_INCREMENT PRIMARY KEY,
  product_id INT NOT NULL,
  type_id VARCHAR(16) NOT NULL,
  name VARCHAR(256) NOT NULL,
  summary TEXT,
  payload LONGTEXT,
  tags VARCHAR(512) NOT NULL DEFAULT '',
  status VARCHAR(16) NOT NULL DEFAULT 'draft',
  origin VARCHAR(16) NOT NULL DEFAULT 'manual',
  version INT NOT NULL DEFAULT 1,
  steward_name VARCHAR(64) NOT NULL DEFAULT '',
  steward_role VARCHAR(32) NOT NULL DEFAULT '',
  steward_team VARCHAR(128) NOT NULL DEFAULT '',
  locked INT NOT NULL DEFAULT 0,
  created_by VARCHAR(64) NOT NULL DEFAULT '',
  updated_by VARCHAR(64) NOT NULL DEFAULT '',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  KEY idx_ke_product (product_id),
  KEY idx_ke_type (type_id),
  KEY idx_ke_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS knowledge_type_locks (
  id INT AUTO_INCREMENT PRIMARY KEY,
  product_id INT NOT NULL,
  type_id VARCHAR(16) NOT NULL,
  note TEXT,
  locked_by VARCHAR(64) NOT NULL DEFAULT '',
  locked_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_type_lock (product_id, type_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS entity_references (
  id INT AUTO_INCREMENT PRIMARY KEY,
  from_id INT NOT NULL,
  to_id INT NOT NULL,
  relation VARCHAR(64) NOT NULL DEFAULT '引用',
  KEY idx_er_from (from_id),
  KEY idx_er_to (to_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS entity_versions (
  id INT AUTO_INCREMENT PRIMARY KEY,
  entity_id INT NOT NULL,
  version INT NOT NULL,
  name VARCHAR(256) NOT NULL,
  summary TEXT,
  payload LONGTEXT,
  tags VARCHAR(512) NOT NULL DEFAULT '',
  status VARCHAR(16) NOT NULL DEFAULT 'draft',
  refs_json LONGTEXT,
  changed_by VARCHAR(64) NOT NULL DEFAULT '',
  change_note TEXT,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_ev_entity (entity_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS source_documents (
  id INT AUTO_INCREMENT PRIMARY KEY,
  product_id INT NOT NULL,
  title VARCHAR(256) NOT NULL,
  source_type VARCHAR(32) NOT NULL,
  url TEXT,
  file_path TEXT,
  content LONGTEXT,
  status VARCHAR(16) NOT NULL DEFAULT 'ready',
  extract_status VARCHAR(16) NOT NULL DEFAULT 'none',
  extract_meta LONGTEXT,
  target_type_id VARCHAR(16) NOT NULL DEFAULT '',
  error_message TEXT,
  created_by VARCHAR(64) NOT NULL DEFAULT '',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  KEY idx_sd_product (product_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS source_bindings (
  id INT AUTO_INCREMENT PRIMARY KEY,
  source_id INT NOT NULL,
  entity_id INT NOT NULL,
  excerpt TEXT,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_sb_source (source_id),
  KEY idx_sb_entity (entity_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS app_settings (
  `key` VARCHAR(64) PRIMARY KEY,
  value LONGTEXT,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS knowledge_apps (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(128) NOT NULL,
  note TEXT,
  token_prefix VARCHAR(24) NOT NULL DEFAULT '',
  token_hash VARCHAR(64) NOT NULL UNIQUE,
  product_ids TEXT,
  revoked INT NOT NULL DEFAULT 0,
  created_by VARCHAR(64) NOT NULL DEFAULT '',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_used_at DATETIME NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS knowledge_releases (
  id INT AUTO_INCREMENT PRIMARY KEY,
  version_no INT NOT NULL DEFAULT 1,
  name VARCHAR(128) NOT NULL DEFAULT '',
  scope VARCHAR(16) NOT NULL DEFAULT 'product',
  product_ids TEXT,
  `trigger` VARCHAR(16) NOT NULL DEFAULT 'manual',
  note TEXT,
  product_count INT NOT NULL DEFAULT 0,
  entity_count INT NOT NULL DEFAULT 0,
  type_ready INT NOT NULL DEFAULT 0,
  corpus_docs INT NOT NULL DEFAULT 0,
  pack_json LONGTEXT,
  created_by VARCHAR(64) NOT NULL DEFAULT '',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_kr_scope (scope),
  KEY idx_kr_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS extract_skills (
  id INT AUTO_INCREMENT PRIMARY KEY,
  kind VARCHAR(32) NOT NULL,
  ref_key VARCHAR(32) NOT NULL DEFAULT '',
  instruction LONGTEXT,
  examples LONGTEXT,
  focus_models TEXT,
  fields_json LONGTEXT,
  updated_by VARCHAR(64) NOT NULL DEFAULT '',
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uq_extract_skill (kind, ref_key),
  KEY idx_es_kind (kind)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS audit_logs (
  id INT AUTO_INCREMENT PRIMARY KEY,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  username VARCHAR(64) NOT NULL DEFAULT '',
  display_name VARCHAR(64) NOT NULL DEFAULT '',
  role VARCHAR(16) NOT NULL DEFAULT '',
  action VARCHAR(32) NOT NULL DEFAULT 'other',
  category VARCHAR(32) NOT NULL DEFAULT '',
  resource VARCHAR(256) NOT NULL DEFAULT '',
  summary VARCHAR(512) NOT NULL DEFAULT '',
  method VARCHAR(8) NOT NULL DEFAULT '',
  path VARCHAR(256) NOT NULL DEFAULT '',
  status_code INT NOT NULL DEFAULT 0,
  ip VARCHAR(64) NOT NULL DEFAULT '',
  product_id INT NULL,
  detail LONGTEXT,
  KEY idx_al_created (created_at),
  KEY idx_al_user (username),
  KEY idx_al_action (action)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
