-- 知识完整度与治理阶段

local catalog = ctx.require("catalog")
local db = ctx.require("db")
local skills = ctx.require("skills")
local util = ctx.require("util")

local M = {}

local PLACEHOLDERS = {
  [""] = true,
  ["-"] = true,
  ["—"] = true,
  ["n/a"] = true,
  ["na"] = true,
  ["待填写"] = true,
  ["（填写）"] = true,
  ["(填写)"] = true,
  ["示例"] = true,
  ["请填写"] = true,
  ["tbd"] = true,
  ["null"] = true,
}

--- 字段是否算有效填写。
function M.is_effective_text(value, required, min_len)
  local text = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local lower = string.lower(text)
  if text == "" or PLACEHOLDERS[text] or PLACEHOLDERS[lower] then
    return not required
  end
  if required and #text < (min_len or 2) then
    return false
  end
  return true
end

local function field_min_len(field)
  if field and field.type == "textarea" then
    return 4
  end
  return 2
end

--- 批量来源标记。
function M.source_flags(entity_ids)
  local result = {}
  for _, eid in ipairs(entity_ids or {}) do
    result[eid] = { has_source = false, extract_ok = false }
  end
  if not entity_ids or #entity_ids == 0 then
    return result
  end
  local placeholders = {}
  for i = 1, #entity_ids do
    placeholders[i] = "?"
  end
  local binds = db.query(
    "SELECT entity_id, source_id FROM source_bindings WHERE entity_id IN (" .. table.concat(placeholders, ",") .. ")",
    entity_ids
  )
  if #binds == 0 then
    return result
  end
  local source_ids = {}
  local seen = {}
  for _, b in ipairs(binds) do
    if not seen[b.source_id] then
      table.insert(source_ids, b.source_id)
      seen[b.source_id] = true
    end
  end
  local sph = {}
  for i = 1, #source_ids do
    sph[i] = "?"
  end
  local sources = {}
  if #source_ids > 0 then
    local rows = db.query(
      "SELECT id, extract_status FROM source_documents WHERE id IN (" .. table.concat(sph, ",") .. ")",
      source_ids
    )
    for _, row in ipairs(rows) do
      sources[row.id] = row
    end
  end
  for _, b in ipairs(binds) do
    local flags = result[b.entity_id] or { has_source = false, extract_ok = false }
    flags.has_source = true
    local src = sources[b.source_id]
    if src and (src.extract_status or "") == "success" then
      flags.extract_ok = true
    end
    result[b.entity_id] = flags
  end
  return result
end

--- 检查单条实例。
function M.inspect_entity(entity, flags)
  flags = flags or {}
  local fields = skills.effective_fields(entity.type_id)
  local payload = util.strip_steward(util.decode(entity.payload, {}))
  local missing = {}
  for _, field in ipairs(fields) do
    if field.required and not M.is_effective_text(payload[field.key], true, field_min_len(field)) then
      table.insert(missing, { key = field.key, label = field.label })
    end
  end
  local name_ok = M.is_effective_text(entity.name, true, 2) and (entity.name or "") ~= entity.type_id
  local filled_any = name_ok or M.is_effective_text(entity.summary, true, 4)
  for _, field in ipairs(fields) do
    if M.is_effective_text(payload[field.key], true, field_min_len(field)) then
      filled_any = true
      break
    end
  end
  local total = #missing > 0 and (#missing + (name_ok and 0 or 1) + (function()
    local req = 0
    for _, field in ipairs(fields) do
      if field.required then
        req = req + 1
      end
    end
    return req
  end)()) or 0
  -- 与 Python 一致：total = len(required)+1
  local req_n = 0
  for _, field in ipairs(fields) do
    if field.required then
      req_n = req_n + 1
    end
  end
  total = req_n + 1
  local filled = total - #missing - (name_ok and 0 or 1)
  local completeness = total > 0 and math.floor((100 * filled / total) + 0.5) or 100
  local valid_complete = name_ok and #missing == 0
  local origin = entity.origin or "manual"
  local version = tonumber(entity.version) or 1
  local has_source = not not flags.has_source
  local extract_ok = not not flags.extract_ok
  local stage
  if valid_complete and entity.status == "published" then
    stage = "governed"
  elseif origin == "extract" and version <= 1 and not valid_complete then
    stage = "extracted"
  elseif valid_complete or filled_any then
    stage = "incomplete"
  elseif extract_ok or origin == "extract" then
    stage = "extracted"
  elseif has_source then
    stage = "sourced"
  else
    stage = "ungoverned"
  end
  return {
    origin = origin,
    completeness = completeness,
    missing_fields = util.arr(missing),
    name_ok = name_ok,
    valid_complete = valid_complete,
    filled_any = filled_any,
    required_total = total,
    filled_required = filled,
    has_source = has_source,
    extract_ok = extract_ok,
    stage = stage,
  }
end

--- 某类型在产品下的阶段。
function M.inspect_type(product_id, type_id)
  local rows = db.query(
    "SELECT * FROM knowledge_entities WHERE product_id = ? AND type_id = ? ORDER BY id",
    { product_id, type_id }
  )
  if #rows == 0 then
    return { stage = "ungoverned", count = 0, governed = 0 }
  end
  local ids = {}
  for _, row in ipairs(rows) do
    table.insert(ids, row.id)
  end
  local flags = M.source_flags(ids)
  local best = "ungoverned"
  local rank = { ungoverned = 0, sourced = 1, extracted = 2, incomplete = 3, governed = 4 }
  local governed = 0
  for _, row in ipairs(rows) do
    local ins = M.inspect_entity(row, flags[row.id])
    if ins.stage == "governed" then
      governed = governed + 1
    end
    if (rank[ins.stage] or 0) > (rank[best] or 0) then
      best = ins.stage
    end
  end
  return { stage = best, count = #rows, governed = governed }
end

return M
