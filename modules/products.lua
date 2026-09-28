-- 产品、功能、关系

local db = ctx.require("db")
local governance = ctx.require("governance")
local util = ctx.require("util")

local M = {}

M.PRODUCT_REL_LABELS = {
  upstream = "上游",
  downstream = "下游",
  depends = "依赖",
  provides = "能力输出",
  integrates = "集成协同",
}

M.FEATURE_REL_LABELS = {
  upstream = "上游",
  downstream = "下游",
  depends = "依赖",
  calls = "调用",
  provides = "能力输出",
  integrates = "集成协同",
}

--- 产品卡片。
function M.serialize_product(product)
  local entity_count = db.one("SELECT COUNT(*) AS n FROM knowledge_entities WHERE product_id = ?", { product.id })
  local feature_count = db.one("SELECT COUNT(*) AS n FROM product_features WHERE product_id = ?", { product.id })
  local types = db.query("SELECT DISTINCT type_id FROM knowledge_entities WHERE product_id = ?", { product.id })
  local governed = 0
  for _, row in ipairs(types) do
    if governance.inspect_type(product.id, row.type_id).stage == "governed" then
      governed = governed + 1
    end
  end
  return {
    id = product.id,
    name = product.name,
    code = product.code or "",
    description = product.description or "",
    owner = product.owner or "",
    status = product.status or "active",
    updated_at = product.updated_at,
    entity_count = tonumber(entity_count and entity_count.n) or 0,
    feature_count = tonumber(feature_count and feature_count.n) or 0,
    governed_types = governed,
  }
end

--- 功能出参。
function M.serialize_feature(item)
  return {
    id = item.id,
    product_id = item.product_id,
    name = item.name,
    summary = item.summary or "",
    kind = item.kind or "功能",
    sort_order = item.sort_order or 0,
    entity_id = item.entity_id,
  }
end

--- 产品关系出参。
function M.serialize_product_relation(item)
  return {
    id = item.id,
    from_product_id = item.from_product_id,
    to_product_id = item.to_product_id,
    kind = item.kind,
    label = item.label,
    note = item.note or "",
  }
end

--- 功能关系出参。
function M.serialize_feature_relation(item)
  return {
    id = item.id,
    from_feature_id = item.from_feature_id,
    to_feature_id = item.to_feature_id,
    kind = item.kind,
    label = item.label,
    note = item.note or "",
  }
end

--- 从知识同步 E02 功能投影。
function M.sync_features(product_id)
  local rows = db.query(
    [[SELECT id, name, summary, type_id FROM knowledge_entities
      WHERE product_id = ? AND type_id IN ('E02-001', 'E02-002') ORDER BY id]],
    { product_id }
  )
  for _, row in ipairs(rows) do
    local kind = row.type_id == "E02-001" and "模块" or "功能"
    local exist = db.one("SELECT id FROM product_features WHERE entity_id = ?", { row.id })
    if exist then
      db.exec(
        "UPDATE product_features SET name = ?, summary = ?, kind = ? WHERE id = ?",
        { row.name, row.summary or "", kind, exist.id }
      )
    else
      db.exec(
        "INSERT INTO product_features (product_id, name, summary, kind, sort_order, entity_id) VALUES (?, ?, ?, ?, 0, ?)",
        { product_id, row.name, row.summary or "", kind, row.id }
      )
    end
  end
end

--- 复制产品知识。
function M.clone_knowledge(from_id, to_id, username)
  local src = db.query("SELECT * FROM knowledge_entities WHERE product_id = ? ORDER BY id", { from_id })
  local id_map = {}
  for _, row in ipairs(src) do
    local ins = db.exec(
      [[INSERT INTO knowledge_entities
        (product_id, type_id, name, summary, payload, tags, status, origin, version, steward_name, steward_role, steward_team, locked, created_by, updated_by, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, 0, ?, ?, ?, ?)]],
      {
        to_id,
        row.type_id,
        row.name,
        row.summary or "",
        row.payload or "{}",
        row.tags or "",
        row.status or "draft",
        "clone",
        row.steward_name or "",
        row.steward_role or "",
        row.steward_team or "",
        username or "",
        username or "",
        util.now(),
        util.now(),
      }
    )
    id_map[row.id] = ins.insert_id
  end
  local refs = db.query(
    [[SELECT r.* FROM entity_references r
      JOIN knowledge_entities e ON e.id = r.from_id WHERE e.product_id = ?]],
    { from_id }
  )
  for _, ref in ipairs(refs) do
    local a = id_map[ref.from_id]
    local b = id_map[ref.to_id]
    if a and b then
      db.exec("INSERT INTO entity_references (from_id, to_id, relation) VALUES (?, ?, ?)", { a, b, ref.relation })
    end
  end
  M.sync_features(to_id)
  return { entities = #src }
end

--- 清空产品知识。
function M.clear_knowledge(product_id)
  local ids = db.query("SELECT id FROM knowledge_entities WHERE product_id = ?", { product_id })
  for _, row in ipairs(ids) do
    db.exec("DELETE FROM entity_references WHERE from_id = ? OR to_id = ?", { row.id, row.id })
    db.exec("DELETE FROM entity_versions WHERE entity_id = ?", { row.id })
    db.exec("DELETE FROM source_bindings WHERE entity_id = ?", { row.id })
  end
  db.exec("DELETE FROM knowledge_entities WHERE product_id = ?", { product_id })
  db.exec("DELETE FROM knowledge_type_locks WHERE product_id = ?", { product_id })
  db.exec("DELETE FROM product_features WHERE product_id = ?", { product_id })
  db.exec("DELETE FROM source_documents WHERE product_id = ?", { product_id })
end

--- 产品全景。
function M.landscape()
  local products = db.query("SELECT * FROM products ORDER BY id")
  local rels = db.query("SELECT * FROM product_relations")
  local nodes = {}
  for _, p in ipairs(products) do
    table.insert(nodes, M.serialize_product(p))
  end
  local edges = {}
  for _, r in ipairs(rels) do
    table.insert(edges, M.serialize_product_relation(r))
  end
  return { products = util.arr(nodes), relations = util.arr(edges) }
end

return M
