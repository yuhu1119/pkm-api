-- 10 个一级模型与 78 类对象模板

local data_mod = ctx.require("catalog_data")
local util = ctx.require("util")

local decoded = ctx.utils.json_decode(data_mod.JSON)
local TYPES = decoded.types or {}
local MODELS = decoded.models or {}
local PROFILES = decoded.profiles or {}
local SHEET = {}
for _, id in ipairs(decoded.sheet_type_ids or {}) do
  SHEET[id] = true
end
local GROUP_FIELD = decoded.inventory_group_field or {}
local COMMON = decoded.common_meta_fields or {}

local TYPE_MAP = {}
for _, item in ipairs(TYPES) do
  TYPE_MAP[item.entity_id] = item
end

local PROFILE_MAP = {}
for _, item in ipairs(PROFILES) do
  PROFILE_MAP[item.code] = item
end

local M = {}
M.TYPES = TYPES
M.MODELS = MODELS
M.PROFILES = PROFILES
M.TYPE_MAP = TYPE_MAP
M.PROFILE_MAP = PROFILE_MAP

--- 补齐通用元数据与模版形态。
function M.hydrate(item)
  if not item then
    return {}
  end
  local keys = {}
  for _, field in ipairs(item.fields or {}) do
    keys[field.key] = true
  end
  local fields = {}
  for _, field in ipairs(COMMON) do
    if not keys[field.key] then
      table.insert(fields, field)
    end
  end
  for _, field in ipairs(item.fields or {}) do
    table.insert(fields, field)
  end
  local out = {}
  for k, v in pairs(item) do
    out[k] = v
  end
  out.fields = fields
  local kind = item.template_kind
  if not kind or kind == "" then
    kind = SHEET[item.entity_id] and "xlsx" or "docx"
  end
  out.template_kind = kind
  out.inventory_group_field = GROUP_FIELD[item.entity_id] or ""
  out.fill_mode = kind == "xlsx" and "sheet" or "document"
  return out
end

--- 一级模型列表（含工作台用途）。
function M.list_models()
  local rows = {}
  for _, model in ipairs(MODELS) do
    local row = { code = model.code, name = model.name }
    local profile = PROFILE_MAP[model.code]
    if profile then
      row.purpose = profile.purpose
      row.ai_role = profile.ai_role
      row.view = profile.view
    end
    table.insert(rows, row)
  end
  return util.arr(rows)
end

--- 按编号取类型。
function M.get_type(type_id)
  return TYPE_MAP[type_id]
end

return M
