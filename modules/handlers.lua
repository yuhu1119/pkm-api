-- /api 业务路由：保持与原前端 JSON 契约一致

local apps = ctx.require("apps")
local audit = ctx.require("audit")
local authz = ctx.require("authz")
local catalog = ctx.require("catalog")
local db = ctx.require("db")
local entities = ctx.require("entities")
local extract = ctx.require("extract")
local governance = ctx.require("governance")
local pack_mod = ctx.require("pack")
local products = ctx.require("products")
local releases = ctx.require("releases")
local respond = ctx.require("respond")
local settings = ctx.require("settings")
local skills = ctx.require("skills")
local sources = ctx.require("sources")
local util = ctx.require("util")

local M = {}

local function user()
  return authz.require_user()
end

local function editor(u)
  return u and authz.require_editor(u)
end

local function product()
  return authz.require_product()
end

local function load_entity(id, product_id)
  local row = db.one("SELECT * FROM knowledge_entities WHERE id = ?", { id })
  if not row or (product_id and row.product_id ~= product_id) then
    return nil
  end
  return row
end

local function serialize_many(rows)
  local ids = {}
  for _, row in ipairs(rows) do
    table.insert(ids, row.id)
  end
  local flags = governance.source_flags(ids)
  local out = {}
  for _, row in ipairs(rows) do
    table.insert(out, entities.serialize(row, false, flags[row.id]))
  end
  return util.arr(out)
end

local function persist_instance(product_row, u, source, item)
  local type_id = item.type_id or item.entity_id
  local meta = catalog.get_type(type_id)
  if not meta then
    return nil
  end
  local ins = db.exec(
    [[INSERT INTO knowledge_entities
      (product_id, type_id, name, summary, payload, tags, status, origin, version, created_by, updated_by, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, 'draft', 'extract', 1, ?, ?, ?, ?)]],
    {
      product_row.id,
      type_id,
      item.name or meta.name,
      item.summary or "",
      util.encode(util.strip_steward(item.payload or {})),
      util.tags_to_str(item.tags or {}),
      u.username,
      u.username,
      util.now(),
      util.now(),
    }
  )
  if source then
    db.exec(
      "INSERT INTO source_bindings (source_id, entity_id, excerpt, created_at) VALUES (?, ?, ?, ?)",
      { source.id, ins.insert_id, util.clip(item.summary or "", 500), util.now() }
    )
  end
  products.sync_features(product_row.id)
  return ins.insert_id
end

local ROUTES = {}

local function add(method, pattern, fn)
  table.insert(ROUTES, { method = method, pattern = pattern, fn = fn })
end

add("GET", "/api/auth/me", function()
  local u = user()
  if not u then
    return
  end
  respond.json(authz.to_out(u))
end)

add("GET", "/api/users", function()
  local u = user()
  if not u or not authz.require_roles(u, "admin") then
    return
  end
  local rows = db.query("SELECT * FROM users ORDER BY id")
  local out = {}
  for _, row in ipairs(rows) do
    table.insert(out, authz.to_out(row))
  end
  respond.json(util.arr(out))
end)

add("PUT", "/api/users/:id", function(p)
  local u = user()
  if not u or not authz.require_roles(u, "admin") then
    return
  end
  local row = db.one("SELECT * FROM users WHERE id = ?", { tonumber(p.id) })
  if not row then
    return respond.fail(404, "用户不存在")
  end
  local body = util.body()
  if body.display_name then
    row.display_name = body.display_name
  end
  if body.role then
    row.role = body.role
  end
  db.exec("UPDATE users SET display_name = ?, role = ? WHERE id = ?", { row.display_name, row.role, row.id })
  if body.model_permissions then
    db.exec("DELETE FROM user_model_permissions WHERE user_id = ?", { row.id })
    for code, flags in pairs(body.model_permissions) do
      db.exec(
        "INSERT INTO user_model_permissions (user_id, model_code, can_read, can_write) VALUES (?, ?, ?, ?)",
        {
          row.id,
          tonumber(code),
          (flags.can_read == false) and 0 or 1,
          flags.can_write and 1 or 0,
        }
      )
    end
  end
  respond.json(authz.to_out(db.one("SELECT * FROM users WHERE id = ?", { row.id })))
end)

add("GET", "/api/meta/models", function()
  if not user() then
    return
  end
  respond.json(catalog.list_models())
end)

add("GET", "/api/meta/types", function()
  if not user() then
    return
  end
  local code = tonumber(ctx.req.query("model_code"))
  local items = {}
  for _, t in ipairs(catalog.TYPES) do
    if not code or t.model_code == code then
      table.insert(items, skills.resolve_type(t.entity_id))
    end
  end
  respond.json(util.arr(items))
end)

add("GET", "/api/products", function()
  if not user() then
    return
  end
  local rows = db.query("SELECT * FROM products ORDER BY id")
  local out = {}
  for _, row in ipairs(rows) do
    table.insert(out, products.serialize_product(row))
  end
  respond.json(util.arr(out))
end)

add("POST", "/api/products", function()
  local u = user()
  if not u or not editor(u) then
    return
  end
  local body = util.body()
  local name = tostring(body.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then
    return respond.fail(400, "请填写产品名称")
  end
  local ins = db.exec(
    "INSERT INTO products (name, code, description, owner, status, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
    { name, body.code or "", body.description or "", body.owner or "", body.status or "active", util.now() }
  )
  local product_row = db.one("SELECT * FROM products WHERE id = ?", { ins.insert_id })
  if body.init_mode == "clone" and body.clone_from_id then
    products.clone_knowledge(tonumber(body.clone_from_id), product_row.id, u.username)
  end
  audit.write(u, { action = "create", category = "产品", resource = name, summary = "新建产品" })
  respond.json(products.serialize_product(product_row))
end)

add("GET", "/api/products/:id", function(p)
  if not user() then
    return
  end
  local row = db.one("SELECT * FROM products WHERE id = ?", { tonumber(p.id) })
  if not row then
    return respond.fail(404, "产品不存在")
  end
  respond.json(products.serialize_product(row))
end)

add("PUT", "/api/products/:id", function(p)
  local u = user()
  if not u or not editor(u) then
    return
  end
  local row = db.one("SELECT * FROM products WHERE id = ?", { tonumber(p.id) })
  if not row then
    return respond.fail(404, "产品不存在")
  end
  local body = util.body()
  db.exec(
    "UPDATE products SET name = ?, code = ?, description = ?, owner = ?, status = ?, updated_at = ? WHERE id = ?",
    {
      body.name or row.name,
      body.code ~= nil and body.code or row.code,
      body.description ~= nil and body.description or row.description,
      body.owner ~= nil and body.owner or row.owner,
      body.status or row.status,
      util.now(),
      row.id,
    }
  )
  respond.json(products.serialize_product(db.one("SELECT * FROM products WHERE id = ?", { row.id })))
end)

add("DELETE", "/api/products/:id", function(p)
  local u = user()
  if not u or not editor(u) then
    return
  end
  local pid = tonumber(p.id)
  products.clear_knowledge(pid)
  db.exec("DELETE FROM product_relations WHERE from_product_id = ? OR to_product_id = ?", { pid, pid })
  db.exec("DELETE FROM products WHERE id = ?", { pid })
  respond.json({ ok = true })
end)

add("POST", "/api/products/:id/knowledge/init", function(p)
  local u = user()
  if not u or not editor(u) then
    return
  end
  local body = util.body()
  if body.clone_from_id then
    local result = products.clone_knowledge(tonumber(body.clone_from_id), tonumber(p.id), u.username)
    return respond.json(result)
  end
  respond.json({ entities = 0, features = 0, detail = "云端不提供示例知识，请上传纯文本或从其他产品复制" })
end)

add("POST", "/api/products/:id/knowledge/clear", function(p)
  local u = user()
  if not u or not editor(u) then
    return
  end
  products.clear_knowledge(tonumber(p.id))
  respond.json({ ok = true })
end)

add("GET", "/api/products/:id/features", function(p)
  if not user() then
    return
  end
  local rows = db.query("SELECT * FROM product_features WHERE product_id = ? ORDER BY sort_order, id", { tonumber(p.id) })
  local out = {}
  for _, row in ipairs(rows) do
    table.insert(out, products.serialize_feature(row))
  end
  respond.json(util.arr(out))
end)

add("POST", "/api/products/:id/features", function(p)
  local u = user()
  if not u or not editor(u) then
    return
  end
  local body = util.body()
  local ins = db.exec(
    "INSERT INTO product_features (product_id, name, summary, kind, sort_order, entity_id) VALUES (?, ?, ?, ?, ?, ?)",
    { tonumber(p.id), body.name or "", body.summary or "", body.kind or "功能", body.sort_order or 0, body.entity_id }
  )
  respond.json(products.serialize_feature(db.one("SELECT * FROM product_features WHERE id = ?", { ins.insert_id })))
end)

add("PUT", "/api/features/:id", function(p)
  local u = user()
  if not u or not editor(u) then
    return
  end
  local row = db.one("SELECT * FROM product_features WHERE id = ?", { tonumber(p.id) })
  if not row then
    return respond.fail(404, "功能不存在")
  end
  local body = util.body()
  db.exec(
    "UPDATE product_features SET name = ?, summary = ?, kind = ?, sort_order = ? WHERE id = ?",
    { body.name or row.name, body.summary ~= nil and body.summary or row.summary, body.kind or row.kind, body.sort_order or row.sort_order, row.id }
  )
  respond.json(products.serialize_feature(db.one("SELECT * FROM product_features WHERE id = ?", { row.id })))
end)

add("DELETE", "/api/features/:id", function(p)
  local u = user()
  if not u or not editor(u) then
    return
  end
  db.exec("DELETE FROM feature_relations WHERE from_feature_id = ? OR to_feature_id = ?", { tonumber(p.id), tonumber(p.id) })
  db.exec("DELETE FROM product_features WHERE id = ?", { tonumber(p.id) })
  respond.json({ ok = true })
end)

add("GET", "/api/product-relations", function()
  if not user() then
    return
  end
  local rows = db.query("SELECT * FROM product_relations ORDER BY id")
  local out = {}
  for _, row in ipairs(rows) do
    table.insert(out, products.serialize_product_relation(row))
  end
  respond.json(util.arr(out))
end)

add("POST", "/api/product-relations", function()
  local u = user()
  if not u or not editor(u) then
    return
  end
  local body = util.body()
  local kind = body.kind or "depends"
  local ins = db.exec(
    "INSERT INTO product_relations (from_product_id, to_product_id, kind, label, note) VALUES (?, ?, ?, ?, ?)",
    { body.from_product_id, body.to_product_id, kind, body.label or products.PRODUCT_REL_LABELS[kind] or "依赖", body.note or "" }
  )
  respond.json(products.serialize_product_relation(db.one("SELECT * FROM product_relations WHERE id = ?", { ins.insert_id })))
end)

add("DELETE", "/api/product-relations/:id", function(p)
  local u = user()
  if not u or not editor(u) then
    return
  end
  db.exec("DELETE FROM product_relations WHERE id = ?", { tonumber(p.id) })
  respond.json({ ok = true })
end)

add("GET", "/api/feature-relations", function()
  if not user() then
    return
  end
  local rows = db.query("SELECT * FROM feature_relations ORDER BY id")
  local out = {}
  for _, row in ipairs(rows) do
    table.insert(out, products.serialize_feature_relation(row))
  end
  respond.json(util.arr(out))
end)

add("POST", "/api/feature-relations", function()
  local u = user()
  if not u or not editor(u) then
    return
  end
  local body = util.body()
  local kind = body.kind or "depends"
  local ins = db.exec(
    "INSERT INTO feature_relations (from_feature_id, to_feature_id, kind, label, note) VALUES (?, ?, ?, ?, ?)",
    { body.from_feature_id, body.to_feature_id, kind, body.label or products.FEATURE_REL_LABELS[kind] or "依赖", body.note or "" }
  )
  respond.json(products.serialize_feature_relation(db.one("SELECT * FROM feature_relations WHERE id = ?", { ins.insert_id })))
end)

add("DELETE", "/api/feature-relations/:id", function(p)
  local u = user()
  if not u or not editor(u) then
    return
  end
  db.exec("DELETE FROM feature_relations WHERE id = ?", { tonumber(p.id) })
  respond.json({ ok = true })
end)

add("GET", "/api/landscape", function()
  if not user() then
    return
  end
  respond.json(products.landscape())
end)

add("GET", "/api/product", function()
  if not user() then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  respond.json({
    id = pr.id,
    name = pr.name,
    description = pr.description,
    code = pr.code or "",
    owner = pr.owner or "",
    status = pr.status or "active",
  })
end)

add("PUT", "/api/product", function()
  local u = user()
  if not u or not editor(u) then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local body = util.body()
  db.exec(
    "UPDATE products SET name = ?, description = ?, code = ?, owner = ?, status = ?, updated_at = ? WHERE id = ?",
    {
      body.name or pr.name,
      body.description ~= nil and body.description or pr.description,
      body.code ~= nil and body.code or pr.code,
      body.owner ~= nil and body.owner or pr.owner,
      body.status or pr.status,
      util.now(),
      pr.id,
    }
  )
  local row = db.one("SELECT * FROM products WHERE id = ?", { pr.id })
  respond.json({ id = row.id, name = row.name, description = row.description })
end)

add("GET", "/api/dashboard", function()
  if not user() then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local stage_counts = { ungoverned = 0, sourced = 0, extracted = 0, incomplete = 0, governed = 0 }
  local coverage = {}
  for _, model in ipairs(catalog.MODELS) do
    local types = {}
    for _, t in ipairs(catalog.TYPES) do
      if t.model_code == model.code then
        table.insert(types, t)
      end
    end
    local filled, sourced, extracted, incomplete = 0, 0, 0, 0
    local type_ids = {}
    for _, t in ipairs(types) do
      table.insert(type_ids, t.entity_id)
      local stage = governance.inspect_type(pr.id, t.entity_id).stage
      stage_counts[stage] = (stage_counts[stage] or 0) + 1
      if stage == "governed" then
        filled = filled + 1
      elseif stage == "sourced" then
        sourced = sourced + 1
      elseif stage == "extracted" then
        extracted = extracted + 1
      elseif stage == "incomplete" then
        incomplete = incomplete + 1
      end
    end
    local n = 0
    if #type_ids > 0 then
      local ph = {}
      for i = 1, #type_ids do
        ph[i] = "?"
      end
      local args = { pr.id }
      for _, tid in ipairs(type_ids) do
        table.insert(args, tid)
      end
      local c = db.one(
        "SELECT COUNT(*) AS n FROM knowledge_entities WHERE product_id = ? AND type_id IN (" .. table.concat(ph, ",") .. ")",
        args
      )
      n = tonumber(c and c.n) or 0
    end
    table.insert(coverage, {
      model_code = model.code,
      model_name = model.name,
      type_total = #types,
      type_filled = filled,
      type_governed = filled,
      type_sourced = sourced,
      type_extracted = extracted,
      type_incomplete = incomplete,
      entity_count = n,
    })
  end
  local total = db.one("SELECT COUNT(*) AS n FROM knowledge_entities WHERE product_id = ?", { pr.id })
  respond.json({
    coverage = util.arr(coverage),
    stage_counts = stage_counts,
    entity_total = tonumber(total and total.n) or 0,
    dangling_refs = 0,
  })
end)

add("GET", "/api/governance", function()
  if not user() then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local rows = {}
  for _, t in ipairs(catalog.TYPES) do
    local ins = governance.inspect_type(pr.id, t.entity_id)
    table.insert(rows, {
      type_id = t.entity_id,
      name = t.name,
      model_code = t.model_code,
      model_name = t.model_name,
      stage = ins.stage,
      count = ins.count,
      governed = ins.governed,
    })
  end
  respond.json(util.arr(rows))
end)

add("GET", "/api/locks", function()
  if not user() then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  respond.json(entities.lock_state(pr.id))
end)

add("POST", "/api/types/:type_id/lock", function(p)
  local u = user()
  if not u or not editor(u) then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local body = util.body()
  if body.locked == false then
    db.exec("DELETE FROM knowledge_type_locks WHERE product_id = ? AND type_id = ?", { pr.id, p.type_id })
  else
    local exist = db.one("SELECT id FROM knowledge_type_locks WHERE product_id = ? AND type_id = ?", { pr.id, p.type_id })
    if not exist then
      db.exec(
        "INSERT INTO knowledge_type_locks (product_id, type_id, note, locked_by, locked_at) VALUES (?, ?, ?, ?, ?)",
        { pr.id, p.type_id, body.note or "", u.username, util.now() }
      )
    end
  end
  respond.json(entities.lock_state(pr.id))
end)

add("GET", "/api/entities", function()
  local u = user()
  if not u then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local type_id = ctx.req.query("type_id")
  local model_code = tonumber(ctx.req.query("model_code"))
  local q = ctx.req.query("q") or ""
  local sql = "SELECT * FROM knowledge_entities WHERE product_id = ?"
  local args = { pr.id }
  if type_id and type_id ~= "" then
    sql = sql .. " AND type_id = ?"
    table.insert(args, type_id)
  elseif model_code then
    local ids = {}
    for _, t in ipairs(catalog.TYPES) do
      if t.model_code == model_code then
        table.insert(ids, t.entity_id)
      end
    end
    if #ids > 0 then
      local ph = {}
      for i = 1, #ids do
        ph[i] = "?"
        table.insert(args, ids[i])
      end
      sql = sql .. " AND type_id IN (" .. table.concat(ph, ",") .. ")"
    end
  end
  if q ~= "" then
    sql = sql .. " AND (name LIKE ? OR summary LIKE ? OR payload LIKE ?)"
    local like = "%" .. q .. "%"
    table.insert(args, like)
    table.insert(args, like)
    table.insert(args, like)
  end
  sql = sql .. " ORDER BY type_id, id"
  respond.json(serialize_many(db.query(sql, args)))
end)

add("POST", "/api/entities", function()
  local u = user()
  if not u or not editor(u) then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local body = util.body()
  local type_id = body.type_id
  local meta = catalog.get_type(type_id)
  if not meta then
    return respond.fail(400, "对象类型不存在")
  end
  if not authz.assert_model_access(u, meta.model_code, true) then
    return
  end
  if entities.locked_type_ids(pr.id)[type_id] then
    return respond.fail(409, "该对象类型已锁定")
  end
  local ins = db.exec(
    [[INSERT INTO knowledge_entities
      (product_id, type_id, name, summary, payload, tags, status, origin, version, steward_name, steward_role, steward_team, created_by, updated_by, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, 'manual', 1, ?, ?, ?, ?, ?, ?, ?)]],
    {
      pr.id,
      type_id,
      body.name or meta.name,
      body.summary or "",
      util.encode(util.strip_steward(body.payload or {})),
      util.tags_to_str(body.tags or {}),
      body.status or "draft",
      body.steward_name or "",
      body.steward_role or "",
      body.steward_team or "",
      u.username,
      u.username,
      util.now(),
      util.now(),
    }
  )
  local row = db.one("SELECT * FROM knowledge_entities WHERE id = ?", { ins.insert_id })
  entities.replace_refs(row.id, body.refs or {})
  products.sync_features(pr.id)
  respond.json(entities.serialize(row, true, {}))
end)

add("GET", "/api/entities/:id", function(p)
  if not user() then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local row = load_entity(tonumber(p.id), pr.id)
  if not row then
    return respond.fail(404, "实例不存在")
  end
  local flags = governance.source_flags({ row.id })
  respond.json(entities.serialize(row, true, flags[row.id]))
end)

add("POST", "/api/entities/:id/lock", function(p)
  local u = user()
  if not u or not editor(u) then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local row = load_entity(tonumber(p.id), pr.id)
  if not row then
    return respond.fail(404, "实例不存在")
  end
  local body = util.body()
  db.exec("UPDATE knowledge_entities SET locked = ? WHERE id = ?", { body.locked == false and 0 or 1, row.id })
  row = load_entity(row.id, pr.id)
  respond.json(entities.serialize(row, true, {}))
end)

add("PUT", "/api/entities/:id", function(p)
  local u = user()
  if not u or not editor(u) then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local row = load_entity(tonumber(p.id), pr.id)
  if not row then
    return respond.fail(404, "实例不存在")
  end
  if util.is_true(row.locked) then
    return respond.fail(409, "实例已锁定")
  end
  local meta = catalog.get_type(row.type_id)
  if meta and not authz.assert_model_access(u, meta.model_code, true) then
    return
  end
  entities.write_version(row, u.username, "更新")
  local body = util.body()
  row = entities.apply_steward(row, body)
  db.exec(
    [[UPDATE knowledge_entities SET name = ?, summary = ?, payload = ?, tags = ?, status = ?,
      steward_name = ?, steward_role = ?, steward_team = ?, version = version + 1, updated_by = ?, updated_at = ?
      WHERE id = ?]],
    {
      body.name or row.name,
      body.summary ~= nil and body.summary or row.summary,
      util.encode(body.payload ~= nil and util.strip_steward(body.payload) or util.decode(row.payload, {})),
      body.tags and util.tags_to_str(body.tags) or row.tags,
      body.status or row.status,
      row.steward_name or "",
      row.steward_role or "",
      row.steward_team or "",
      u.username,
      util.now(),
      row.id,
    }
  )
  if body.refs then
    entities.replace_refs(row.id, body.refs)
  end
  products.sync_features(pr.id)
  row = load_entity(row.id, pr.id)
  respond.json(entities.serialize(row, true, {}))
end)

add("DELETE", "/api/entities/:id", function(p)
  local u = user()
  if not u or not editor(u) then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local eid = tonumber(p.id)
  db.exec("DELETE FROM entity_references WHERE from_id = ? OR to_id = ?", { eid, eid })
  db.exec("DELETE FROM entity_versions WHERE entity_id = ?", { eid })
  db.exec("DELETE FROM source_bindings WHERE entity_id = ?", { eid })
  db.exec("DELETE FROM knowledge_entities WHERE id = ? AND product_id = ?", { eid, pr.id })
  respond.json({ ok = true })
end)

add("GET", "/api/entities/:id/versions", function(p)
  if not user() then
    return
  end
  local rows = db.query("SELECT * FROM entity_versions WHERE entity_id = ? ORDER BY version DESC", { tonumber(p.id) })
  local out = {}
  for _, row in ipairs(rows) do
    table.insert(out, {
      id = row.id,
      entity_id = row.entity_id,
      version = row.version,
      name = row.name,
      summary = row.summary,
      payload = util.decode(row.payload, {}),
      tags = util.tags_from_str(row.tags),
      status = row.status,
      refs = util.decode(row.refs_json, {}),
      changed_by = row.changed_by,
      change_note = row.change_note,
      created_at = row.created_at,
    })
  end
  respond.json(util.arr(out))
end)

add("POST", "/api/entities/:id/rollback", function(p)
  local u = user()
  if not u or not editor(u) then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local body = util.body()
  local ver = db.one("SELECT * FROM entity_versions WHERE entity_id = ? AND version = ?", { tonumber(p.id), body.version })
  if not ver then
    return respond.fail(404, "版本不存在")
  end
  local row = load_entity(tonumber(p.id), pr.id)
  entities.write_version(row, u.username, "回滚到 v" .. tostring(ver.version))
  db.exec(
    "UPDATE knowledge_entities SET name = ?, summary = ?, payload = ?, tags = ?, status = ?, version = version + 1, updated_by = ?, updated_at = ? WHERE id = ?",
    { ver.name, ver.summary, ver.payload, ver.tags, ver.status, u.username, util.now(), row.id }
  )
  entities.replace_refs(row.id, util.decode(ver.refs_json, {}))
  row = load_entity(row.id, pr.id)
  respond.json(entities.serialize(row, true, {}))
end)

add("GET", "/api/search", function()
  if not user() then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local q = ctx.req.query("q") or ""
  if q == "" then
    return respond.json(util.arr({}))
  end
  local like = "%" .. q .. "%"
  local rows = db.query(
    "SELECT * FROM knowledge_entities WHERE product_id = ? AND (name LIKE ? OR summary LIKE ? OR payload LIKE ?) ORDER BY id LIMIT 50",
    { pr.id, like, like, like }
  )
  respond.json(serialize_many(rows))
end)

add("GET", "/api/graph", function()
  if not user() then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local rows = db.query("SELECT * FROM knowledge_entities WHERE product_id = ? ORDER BY id", { pr.id })
  local nodes = serialize_many(rows)
  local edges = {}
  for _, row in ipairs(rows) do
    local refs = db.query("SELECT * FROM entity_references WHERE from_id = ?", { row.id })
    for _, ref in ipairs(refs) do
      table.insert(edges, { from_id = ref.from_id, to_id = ref.to_id, relation = ref.relation })
    end
  end
  respond.json({ nodes = nodes, edges = util.arr(edges) })
end)

add("GET", "/api/panorama", function()
  if not user() then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  respond.json(pack_mod.build(pr, {}))
end)

add("GET", "/api/impact", function()
  if not user() then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local type_id = ctx.req.query("type_id") or ""
  respond.json({ type_id = type_id, related = util.arr({}), note = "变更影响请结合对象引用边查看" })
end)

add("GET", "/api/model-studio", function()
  if not user() then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local code = tonumber(ctx.req.query("model_code")) or 1
  local profile = catalog.PROFILE_MAP[code] or {}
  local types = {}
  for _, t in ipairs(catalog.TYPES) do
    if t.model_code == code then
      table.insert(types, {
        type_id = t.entity_id,
        name = t.name,
        stage = governance.inspect_type(pr.id, t.entity_id).stage,
      })
    end
  end
  respond.json({
    model_code = code,
    purpose = profile.purpose,
    ai_role = profile.ai_role,
    view = profile.view,
    panels = util.arr(profile.panels or {}),
    types = util.arr(types),
  })
end)

add("GET", "/api/settings", function()
  local u = user()
  if not u then
    return
  end
  respond.json(settings.mask(settings.get_map(), u.role == "admin"))
end)

add("PUT", "/api/settings", function()
  local u = user()
  if not u or not authz.require_roles(u, "admin") then
    return
  end
  local body = util.body()
  local existing = settings.get_map()
  if body.browser_fetch_enabled ~= nil then
    body.browser_fetch_enabled = body.browser_fetch_enabled and "true" or "false"
  end
  for key, _ in pairs(settings.SECRET_KEYS) do
    if body[key] == "******" and existing[key] then
      body[key] = existing[key]
    end
  end
  local saved = settings.put_map(body)
  local probe = settings.probe(saved)
  respond.json({ settings = saved, llm_probe = probe })
end)

add("GET", "/api/sources", function()
  if not user() then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local rows = db.query("SELECT * FROM source_documents WHERE product_id = ? ORDER BY updated_at DESC", { pr.id })
  local ids = {}
  for _, row in ipairs(rows) do
    table.insert(ids, row.id)
  end
  local cov = sources.coverage_for(ids)
  local out = {}
  for _, row in ipairs(rows) do
    table.insert(out, sources.serialize(row, cov[row.id]))
  end
  respond.json(util.arr(out))
end)

add("GET", "/api/sources/:id", function(p)
  if not user() then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local row = db.one("SELECT * FROM source_documents WHERE id = ? AND product_id = ?", { tonumber(p.id), pr.id })
  if not row then
    return respond.fail(404, "来源不存在")
  end
  local cov = sources.coverage_for({ row.id })
  respond.json(sources.serialize(row, cov[row.id]))
end)

add("POST", "/api/sources/upload", function()
  local u = user()
  if not u or not editor(u) then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local body = util.body()
  local title = body.title or "untitled.txt"
  local ok, err = pcall(sources.assert_plain_filename, title)
  if not ok then
    return respond.fail(400, tostring(err):gsub("^.*:%s*", ""))
  end
  local content = tostring(body.content or "")
  if content == "" then
    return respond.fail(400, "请粘贴或上传纯文本内容")
  end
  local ins = db.exec(
    [[INSERT INTO source_documents
      (product_id, title, source_type, url, file_path, content, status, extract_status, extract_meta, target_type_id, created_by, created_at, updated_at)
      VALUES (?, ?, 'local', '', '', ?, 'ready', 'none', '{}', ?, ?, ?, ?)]],
    { pr.id, title, content, body.target_type_id or "", u.username, util.now(), util.now() }
  )
  local row = db.one("SELECT * FROM source_documents WHERE id = ?", { ins.insert_id })
  respond.json(sources.serialize(row, { type_ids = util.arr({}), entity_count = 0 }))
end)

add("POST", "/api/sources/fetch", function()
  local u = user()
  if not u or not editor(u) then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local body = util.body()
  local url = tostring(body.url or "")
  if url == "" then
    return respond.fail(400, "请填写链接")
  end
  local ok, text = pcall(sources.fetch_url, url)
  local status = ok and "ready" or "error"
  local content = ok and text or ""
  local err_msg = ok and "" or tostring(text)
  local ins = db.exec(
    [[INSERT INTO source_documents
      (product_id, title, source_type, url, file_path, content, status, extract_status, extract_meta, target_type_id, error_message, created_by, created_at, updated_at)
      VALUES (?, ?, ?, ?, '', ?, ?, 'none', '{}', ?, ?, ?, ?, ?)]],
    { pr.id, url, body.connector or "web", url, content, status, body.target_type_id or "", err_msg, u.username, util.now(), util.now() }
  )
  local row = db.one("SELECT * FROM source_documents WHERE id = ?", { ins.insert_id })
  respond.json(sources.serialize(row, { type_ids = util.arr({}), entity_count = 0 }))
end)

add("POST", "/api/sources/:id/refresh", function(p)
  local u = user()
  if not u or not editor(u) then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local row = db.one("SELECT * FROM source_documents WHERE id = ? AND product_id = ?", { tonumber(p.id), pr.id })
  if not row then
    return respond.fail(404, "来源不存在")
  end
  if row.url and row.url ~= "" then
    local ok, text = pcall(sources.fetch_url, row.url)
    if ok then
      db.exec("UPDATE source_documents SET content = ?, status = 'ready', error_message = '', updated_at = ? WHERE id = ?", { text, util.now(), row.id })
    else
      db.exec("UPDATE source_documents SET status = 'error', error_message = ?, updated_at = ? WHERE id = ?", { tostring(text), util.now(), row.id })
    end
  end
  row = db.one("SELECT * FROM source_documents WHERE id = ?", { row.id })
  respond.json(sources.serialize(row, sources.coverage_for({ row.id })[row.id]))
end)

add("POST", "/api/sources/:id/bind", function(p)
  local u = user()
  if not u or not editor(u) then
    return
  end
  local body = util.body()
  db.exec(
    "INSERT INTO source_bindings (source_id, entity_id, excerpt, created_at) VALUES (?, ?, ?, ?)",
    { tonumber(p.id), body.entity_id, body.excerpt or "", util.now() }
  )
  respond.json({ ok = true })
end)

add("DELETE", "/api/sources/:id", function(p)
  local u = user()
  if not u or not editor(u) then
    return
  end
  db.exec("DELETE FROM source_bindings WHERE source_id = ?", { tonumber(p.id) })
  db.exec("DELETE FROM source_documents WHERE id = ?", { tonumber(p.id) })
  respond.json({ ok = true })
end)

local function load_source(id, product_id)
  local row = db.one("SELECT * FROM source_documents WHERE id = ?", { id })
  if not row or row.product_id ~= product_id then
    return nil
  end
  return row
end

add("POST", "/api/extract", function()
  local u = user()
  if not u or not editor(u) then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local body = util.body()
  local text = body.text or ""
  local source
  if body.source_id then
    source = load_source(tonumber(body.source_id), pr.id)
    if source then
      text = source.content
    end
  end
  if tostring(text):gsub("%s+", "") == "" then
    return respond.fail(400, "没有可抽取的文本")
  end
  local ok, result = pcall(extract.extract_entity, body.type_id, text, body.extra_instruction, body.document_kind)
  if not ok then
    return respond.fail(400, tostring(result))
  end
  if body.create_draft then
    result.draft_id = persist_instance(pr, u, source, result)
    result.created = result.draft_id and 1 or 0
    if source then
      db.exec("UPDATE source_documents SET extract_status = 'success' WHERE id = ?", { source.id })
    end
  end
  respond.json(result)
end)

add("POST", "/api/extract/scan", function()
  local u = user()
  if not u or not editor(u) then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local body = util.body()
  local source = load_source(tonumber(body.source_id), pr.id)
  if not source then
    return respond.fail(404, "来源不存在")
  end
  local ok, result = pcall(extract.scan, source.content)
  if not ok then
    return respond.fail(400, tostring(result))
  end
  db.exec("UPDATE source_documents SET extract_meta = ? WHERE id = ?", { util.encode(result), source.id })
  result.locks = entities.lock_state(pr.id)
  respond.json(result)
end)

add("POST", "/api/extract/model", function()
  local u = user()
  if not u or not editor(u) then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local body = util.body()
  local source = load_source(tonumber(body.source_id), pr.id)
  if not source then
    return respond.fail(404, "来源不存在")
  end
  local skip = entities.locked_type_ids(pr.id)
  local ok, instances = pcall(extract.extract_model, source.content, tonumber(body.model_code), body.extra_instruction, skip, body.document_kind)
  if not ok then
    return respond.fail(400, tostring(instances))
  end
  respond.json({
    model_code = body.model_code,
    instances = instances,
    used_skills = util.arr({}),
    document_kind = body.document_kind or "",
    document_kind_title = "",
  })
end)

add("POST", "/api/extract/preview", function()
  local u = user()
  if not u or not editor(u) then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local body = util.body()
  local source = load_source(tonumber(body.source_id), pr.id)
  if not source then
    return respond.fail(404, "来源不存在")
  end
  local ok, result = pcall(extract.extract_entity, body.focus_type_id, source.content, body.extra_instruction, body.document_kind)
  if not ok then
    return respond.fail(400, tostring(result))
  end
  respond.json({
    focus = result,
    others = util.arr({}),
    similar = util.arr({}),
  })
end)

add("POST", "/api/extract/commit", function()
  local u = user()
  if not u or not editor(u) then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local body = util.body()
  local source = body.source_id and load_source(tonumber(body.source_id), pr.id)
  local created = {}
  for _, item in ipairs(body.instances or {}) do
    local id = persist_instance(pr, u, source, item)
    if id then
      table.insert(created, { id = id, type_id = item.type_id, name = item.name })
    end
  end
  if source then
    db.exec("UPDATE source_documents SET extract_status = 'success' WHERE id = ?", { source.id })
  end
  respond.json({ created = util.arr(created), skipped = util.arr({}) })
end)

add("GET", "/api/extract-skills", function()
  if not user() then
    return
  end
  respond.json(skills.list_skills())
end)

add("GET", "/api/extract-skills/download/types", function()
  if not user() then
    return
  end
  respond.download(skills.all_type_skills_csv(), "type-skills.csv", "text/csv; charset=utf-8")
end)

add("GET", "/api/extract-skills/types/:type_id/download", function(p)
  if not user() then
    return
  end
  local ok, csv = pcall(skills.type_skill_csv, p.type_id)
  if not ok then
    return respond.fail(404, tostring(csv))
  end
  respond.download(csv, p.type_id .. "-skill.csv", "text/csv; charset=utf-8")
end)

add("GET", "/api/extract-skills/types/:type_id", function(p)
  if not user() then
    return
  end
  local data = skills.type_skill_detail(p.type_id)
  if not data.name then
    return respond.fail(404, "对象类型不存在")
  end
  respond.json(data)
end)

add("PUT", "/api/extract-skills", function()
  local u = user()
  if not u or not editor(u) then
    return
  end
  local ok, result = pcall(skills.upsert, util.body(), u.username)
  if not ok then
    return respond.fail(400, tostring(result))
  end
  respond.json(result)
end)

add("DELETE", "/api/extract-skills", function()
  local u = user()
  if not u or not editor(u) then
    return
  end
  respond.json(skills.reset(ctx.req.query("kind") or "", ctx.req.query("ref_key") or ""))
end)

add("GET", "/api/knowledge-pack", function()
  if not user() then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  respond.json(pack_mod.build(pr, {
    model_codes = util.split_ints(ctx.req.query("model_codes") or ""),
    type_ids = util.split_strs(ctx.req.query("type_ids") or ""),
    include_triples = ctx.req.query("include_triples") ~= "false",
    top_k = tonumber(ctx.req.query("top_k")) or 5,
  }))
end)

add("POST", "/api/knowledge-pack/trial", function()
  if not user() then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local body = util.body()
  respond.json(pack_mod.trial(pr, body.question, {
    top_k = body.top_k,
    model_codes = body.model_codes,
    type_ids = body.type_ids,
    include_triples = body.include_triples,
  }))
end)

add("GET", "/api/knowledge-pack/download", function()
  if not user() then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local fmt = ctx.req.query("fmt") or "json"
  if fmt == "xlsx" then
    fmt = "json"
  end
  local built = pack_mod.build(pr, {})
  local raw, mime, filename = pack_mod.encode_file(pr, built, fmt)
  respond.download(raw, filename, mime)
end)

add("POST", "/api/knowledge-ask", function()
  if not user() then
    return
  end
  local body = util.body()
  local pids = body.product_ids or {}
  local products_rows = db.query("SELECT * FROM products ORDER BY id")
  local hits = {}
  local messages
  for _, pr in ipairs(products_rows) do
    local allow = #pids == 0
    for _, id in ipairs(pids) do
      if tonumber(id) == pr.id then
        allow = true
      end
    end
    if allow then
      local trial = pack_mod.trial(pr, body.question or "", { top_k = 5 })
      for _, h in ipairs(trial.hits or {}) do
        table.insert(hits, h)
      end
      messages = trial.messages
    end
  end
  local answer = ""
  local ok, text = pcall(function()
    return settings.chat(settings.get_map(), messages or { { role = "user", content = body.question } })
  end)
  if ok then
    answer = text
  else
    answer = "大模型调用失败：" .. tostring(text)
  end
  respond.json({ answer = answer, hits = util.arr(hits) })
end)

add("GET", "/api/knowledge-releases/meta", function()
  if not user() then
    return
  end
  respond.json({ scopes = util.arr({ "product", "combined" }) })
end)

add("GET", "/api/knowledge-releases", function()
  if not user() then
    return
  end
  local rows = db.query("SELECT * FROM knowledge_releases ORDER BY id DESC")
  local out = {}
  for _, row in ipairs(rows) do
    table.insert(out, releases.serialize(row, false))
  end
  respond.json(util.arr(out))
end)

add("POST", "/api/knowledge-releases", function()
  local u = user()
  if not u or not editor(u) then
    return
  end
  local ok, row = pcall(releases.create, util.body(), u.username)
  if not ok then
    return respond.fail(400, tostring(row))
  end
  respond.json(row)
end)

add("GET", "/api/knowledge-releases/:id", function(p)
  if not user() then
    return
  end
  local row = db.one("SELECT * FROM knowledge_releases WHERE id = ?", { tonumber(p.id) })
  if not row then
    return respond.fail(404, "版本不存在")
  end
  respond.json(releases.serialize(row, true))
end)

add("GET", "/api/knowledge-releases/:id/download", function(p)
  if not user() then
    return
  end
  local row = db.one("SELECT * FROM knowledge_releases WHERE id = ?", { tonumber(p.id) })
  if not row then
    return respond.fail(404, "版本不存在")
  end
  local data = util.decode(row.pack_json, {})
  local first = (data.products or {})[1] or data
  local pr = { id = 0, name = row.name }
  if first.product then
    pr = first.product
  end
  local raw, mime, filename = pack_mod.encode_file(pr, first, ctx.req.query("fmt") or "json")
  respond.download(raw, filename, mime)
end)

add("DELETE", "/api/knowledge-releases/:id", function(p)
  local u = user()
  if not u or not editor(u) then
    return
  end
  db.exec("DELETE FROM knowledge_releases WHERE id = ?", { tonumber(p.id) })
  respond.json({ ok = true })
end)

add("GET", "/api/knowledge-apps", function()
  if not user() then
    return
  end
  respond.json(apps.catalog())
end)

add("GET", "/api/knowledge-apps/products/:id", function(p)
  if not user() then
    return
  end
  local pr = db.one("SELECT * FROM products WHERE id = ?", { tonumber(p.id) })
  if not pr then
    return respond.fail(404, "产品不存在")
  end
  respond.json(apps.product_card(pr))
end)

add("GET", "/api/knowledge-apps/products/:id/pack", function(p)
  if not user() then
    return
  end
  local pr = db.one("SELECT * FROM products WHERE id = ?", { tonumber(p.id) })
  if not pr then
    return respond.fail(404, "产品不存在")
  end
  respond.json(pack_mod.build(pr, {}))
end)

add("GET", "/api/knowledge-apps/products/:id/pack/download", function(p)
  if not user() then
    return
  end
  local pr = db.one("SELECT * FROM products WHERE id = ?", { tonumber(p.id) })
  if not pr then
    return respond.fail(404, "产品不存在")
  end
  local built = pack_mod.build(pr, {})
  local raw, mime, filename = pack_mod.encode_file(pr, built, ctx.req.query("fmt") or "json")
  respond.download(raw, filename, mime)
end)

add("GET", "/api/apps", function()
  if not user() then
    return
  end
  local rows = db.query("SELECT * FROM knowledge_apps ORDER BY id DESC")
  local out = {}
  for _, row in ipairs(rows) do
    table.insert(out, apps.serialize_app(row))
  end
  respond.json(util.arr(out))
end)

add("POST", "/api/apps", function()
  local u = user()
  if not u or not editor(u) then
    return
  end
  local body = util.body()
  respond.json(apps.create_app(body.name, body.note, body.product_ids, u.username))
end)

add("DELETE", "/api/apps/:id", function(p)
  local u = user()
  if not u or not editor(u) then
    return
  end
  db.exec("UPDATE knowledge_apps SET revoked = 1 WHERE id = ?", { tonumber(p.id) })
  respond.json({ ok = true })
end)

add("GET", "/api/export", function()
  if not user() then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local rows = db.query("SELECT * FROM knowledge_entities WHERE product_id = ? ORDER BY id", { pr.id })
  local data = serialize_many(rows)
  if (ctx.req.query("fmt") or "json") == "json" then
    return respond.download(util.encode(data), "knowledge.json", "application/json")
  end
  local csv_rows = { { "id", "type_id", "name", "summary", "status" } }
  for _, item in ipairs(data) do
    table.insert(csv_rows, { item.id, item.type_id, item.name, item.summary, item.status })
  end
  respond.download(util.csv(csv_rows), "knowledge.csv", "text/csv; charset=utf-8")
end)

add("POST", "/api/import/preview", function()
  if not user() then
    return
  end
  local body = util.body()
  local items = body.items or body.entities or body
  if type(items) ~= "table" then
    return respond.fail(400, "请提交 JSON：{ items: [...] }")
  end
  local list = items[1] and items or (items.items or {})
  respond.json({ items = util.arr(list), created = 0, updated = 0 })
end)

add("POST", "/api/import/apply", function()
  local u = user()
  if not u or not editor(u) then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local body = util.body()
  local created, updated = 0, 0
  for _, item in ipairs(body.items or {}) do
    if item.id and load_entity(item.id, pr.id) then
      updated = updated + 1
    else
      persist_instance(pr, u, nil, item)
      created = created + 1
    end
  end
  respond.json({ created = created, updated = updated })
end)

add("POST", "/api/import", function()
  local u = user()
  if not u or not editor(u) then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local body = util.body()
  local created = 0
  for _, item in ipairs(body.items or body.entities or {}) do
    persist_instance(pr, u, nil, item)
    created = created + 1
  end
  respond.json({ created = created, updated = 0 })
end)

add("GET", "/api/templates", function()
  if not user() then
    return
  end
  local rows = {}
  for _, t in ipairs(catalog.TYPES) do
    local h = catalog.hydrate(t)
    table.insert(rows, { type_id = t.entity_id, name = t.name, template_kind = h.template_kind, fill_mode = h.fill_mode })
  end
  respond.json(util.arr(rows))
end)

add("POST", "/api/templates/:type_id/import/preview", function(p)
  if not user() then
    return
  end
  local body = util.body()
  local items = body.items or body.rows or {}
  if body[1] then
    items = body
  end
  respond.json({ items = util.arr(items), type_id = p.type_id })
end)

add("POST", "/api/templates/:type_id/import", function()
  local u = user()
  if not u or not editor(u) then
    return
  end
  local pr = product()
  if not pr then
    return
  end
  local body = util.body()
  local created = 0
  for _, item in ipairs(body.items or {}) do
    persist_instance(pr, u, nil, item)
    created = created + 1
  end
  respond.json({ created = created, updated = 0 })
end)

add("GET", "/api/templates/:type_id", function(p)
  if not user() then
    return
  end
  local meta = skills.resolve_type(p.type_id)
  if not meta.name then
    return respond.fail(404, "对象类型不存在")
  end
  respond.json(meta)
end)

add("GET", "/api/templates/:type_id/download", function(p)
  if not user() then
    return
  end
  local meta = skills.resolve_type(p.type_id)
  if not meta.name then
    return respond.fail(404, "对象类型不存在")
  end
  local rows = { { "key", "label", "required", "fill_hint", "value" } }
  for _, field in ipairs(meta.fields or {}) do
    table.insert(rows, { field.key, field.label, field.required and "1" or "0", field.fill_hint or "", "" })
  end
  respond.download(util.csv(rows), p.type_id .. ".csv", "text/csv; charset=utf-8")
end)

add("GET", "/api/templates-bundle", function()
  if not user() then
    return
  end
  respond.fail(400, "本期请按对象类型分别下载 CSV 模版，打包下载后续提供")
end)

add("POST", "/api/audit/visit", function()
  local u = user()
  if not u then
    return
  end
  local body = util.body()
  local path = tostring(body.path or "")
  if path == "" then
    return respond.json({ ok = false })
  end
  local action = path == "/logout" and "logout" or "visit"
  if action == "visit" and audit.recently(u.username, "visit", path, 30) then
    return respond.json({ ok = true, deduped = true })
  end
  audit.write(u, {
    action = action,
    category = action == "logout" and "认证" or "访问",
    resource = body.title or path,
    summary = body.title or path,
    path = path,
  })
  respond.json({ ok = true })
end)

add("GET", "/api/audit-logs", function()
  local u = user()
  if not u or not authz.require_roles(u, "admin") then
    return
  end
  local page = tonumber(ctx.req.query("page")) or 1
  local page_size = tonumber(ctx.req.query("page_size")) or 20
  local offset = (page - 1) * page_size
  local total = db.one("SELECT COUNT(*) AS n FROM audit_logs")
  local rows = db.query("SELECT * FROM audit_logs ORDER BY id DESC LIMIT ? OFFSET ?", { page_size, offset })
  local items = {}
  for _, row in ipairs(rows) do
    table.insert(items, {
      id = row.id,
      created_at = row.created_at,
      username = row.username,
      display_name = row.display_name,
      role = row.role,
      action = row.action,
      category = row.category,
      resource = row.resource,
      summary = row.summary,
      method = row.method,
      path = row.path,
      status_code = row.status_code,
      ip = row.ip,
      product_id = row.product_id,
    })
  end
  respond.json({ total = tonumber(total and total.n) or 0, page = page, page_size = page_size, items = util.arr(items) })
end)

--- 分发当前请求。
function M.handle()
  local method = ctx.req.method()
  local path = util.logical_path()
  -- 去掉末尾斜杠（根路径除外）
  if #path > 1 and string.sub(path, -1) == "/" then
    path = string.sub(path, 1, -2)
  end
  for _, route in ipairs(ROUTES) do
    if route.method == method then
      local cap = util.match_route(route.pattern, path)
      if cap then
        local ok, err = pcall(route.fn, cap)
        if not ok then
          ctx.log.error("handler error", { err = tostring(err), path = path })
          respond.fail(500, tostring(err))
        end
        return
      end
    end
  end
  respond.fail(404, "Not Found")
end

return M
