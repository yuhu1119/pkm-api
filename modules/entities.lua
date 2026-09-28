-- 知识实例序列化、引用、版本

local catalog = ctx.require("catalog")
local db = ctx.require("db")
local governance = ctx.require("governance")
local util = ctx.require("util")

local M = {}

--- 写出引用边。
local function snapshot_refs(entity_id, inbound)
  local refs = {}
  local outs = db.query(
    [[SELECT r.to_id, r.relation, e.name AS to_name, e.type_id AS to_type_id
      FROM entity_references r
      LEFT JOIN knowledge_entities e ON e.id = r.to_id
      WHERE r.from_id = ?]],
    { entity_id }
  )
  for _, ref in ipairs(outs) do
    table.insert(refs, {
      to_id = ref.to_id,
      relation = ref.relation,
      to_name = ref.to_name or "",
      to_type_id = ref.to_type_id or "",
    })
  end
  if inbound then
    local ins = db.query(
      [[SELECT r.from_id, r.relation, e.name AS from_name, e.type_id AS from_type_id
        FROM entity_references r
        LEFT JOIN knowledge_entities e ON e.id = r.from_id
        WHERE r.to_id = ?]],
      { entity_id }
    )
    for _, ref in ipairs(ins) do
      table.insert(refs, {
        from_id = ref.from_id,
        relation = "被引用/" .. (ref.relation or "引用"),
        from_name = ref.from_name or "",
        from_type_id = ref.from_type_id or "",
        direction = "in",
      })
    end
  end
  return util.arr(refs)
end

--- 序列化实例。
function M.serialize(entity, inbound, flags)
  local meta = catalog.TYPE_MAP[entity.type_id] or {}
  local inspection = governance.inspect_entity(entity, flags or {})
  local out = {
    id = entity.id,
    type_id = entity.type_id,
    model_code = meta.model_code or 0,
    model_name = meta.model_name or "",
    type_name = meta.name or "",
    name = entity.name,
    summary = entity.summary or "",
    payload = util.strip_steward(util.decode(entity.payload, {})),
    tags = util.tags_from_str(entity.tags),
    status = entity.status,
    version = entity.version,
    steward_name = entity.steward_name or "",
    steward_role = entity.steward_role or "",
    steward_team = entity.steward_team or "",
    created_by = entity.created_by or "",
    updated_by = entity.updated_by or "",
    created_at = entity.created_at,
    updated_at = entity.updated_at,
    refs = snapshot_refs(entity.id, inbound),
    knowledge_kind = meta.knowledge_kind or "",
    origin = inspection.origin,
    locked = util.is_true(entity.locked),
    completeness = inspection.completeness,
    missing_fields = inspection.missing_fields,
    name_ok = inspection.name_ok,
    valid_complete = inspection.valid_complete,
    filled_any = inspection.filled_any,
    required_total = inspection.required_total,
    filled_required = inspection.filled_required,
    has_source = inspection.has_source,
    extract_ok = inspection.extract_ok,
    stage = inspection.stage,
  }
  return out
end

--- 覆盖引用。
function M.replace_refs(entity_id, refs)
  db.exec("DELETE FROM entity_references WHERE from_id = ?", { entity_id })
  for _, item in ipairs(refs or {}) do
    local to_id = tonumber(item.to_id)
    if to_id and to_id ~= entity_id then
      db.exec(
        "INSERT INTO entity_references (from_id, to_id, relation) VALUES (?, ?, ?)",
        { entity_id, to_id, item.relation or "引用" }
      )
    end
  end
end

--- 写入历史版本。
function M.write_version(entity, changed_by, change_note)
  db.exec(
    [[INSERT INTO entity_versions (entity_id, version, name, summary, payload, tags, status, refs_json, changed_by, change_note, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
    {
      entity.id,
      entity.version,
      entity.name,
      entity.summary or "",
      entity.payload or "{}",
      entity.tags or "",
      entity.status or "draft",
      util.encode(snapshot_refs(entity.id, false)),
      changed_by or "",
      change_note or "",
      util.now(),
    }
  )
end

--- 应用治理责任字段。
function M.apply_steward(entity, data)
  if type(data) ~= "table" then
    return entity
  end
  if data.steward_name ~= nil then
    entity.steward_name = tostring(data.steward_name or "")
  end
  if data.steward_role ~= nil then
    entity.steward_role = tostring(data.steward_role or "")
  end
  if data.steward_team ~= nil then
    entity.steward_team = tostring(data.steward_team or "")
  end
  return entity
end

--- 锁定类型集合。
function M.locked_type_ids(product_id)
  local rows = db.query("SELECT type_id FROM knowledge_type_locks WHERE product_id = ?", { product_id })
  local set = {}
  for _, row in ipairs(rows) do
    set[row.type_id] = true
  end
  return set
end

--- 锁状态。
function M.lock_state(product_id)
  local rows = db.query("SELECT type_id FROM knowledge_type_locks WHERE product_id = ?", { product_id })
  local locked = {}
  local by_model = {}
  for _, row in ipairs(rows) do
    table.insert(locked, row.type_id)
    local meta = catalog.TYPE_MAP[row.type_id]
    if meta then
      by_model[meta.model_code] = (by_model[meta.model_code] or 0) + 1
    end
  end
  local fully = {}
  for _, model in ipairs(catalog.MODELS) do
    local total = 0
    for _, t in ipairs(catalog.TYPES) do
      if t.model_code == model.code then
        total = total + 1
      end
    end
    if total > 0 and (by_model[model.code] or 0) >= total then
      table.insert(fully, model.code)
    end
  end
  return {
    locked_types = util.arr(locked),
    fully_locked_model_codes = util.arr(fully),
  }
end

return M
