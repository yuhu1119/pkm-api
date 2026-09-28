-- 文档解析技能：目录默认 + 库内覆盖

local catalog = ctx.require("catalog")
local db = ctx.require("db")
local util = ctx.require("util")

local M = {}

M.DEFAULT_GLOBAL = [[只抽取文档明确写到的内容，不要编造模块、接口、规则、角色或指标。
type_id 必须来自对象目录；payload 只用该类型列出的字段 key。
找不到依据的字段留空，不要用「暂无」「见文档」等占位词。
同一对象类型可以有多条实例（多个页面、多个角色、多条规则）。
跨类型抽取时，不要把 A 类型的字段填进 B 类型。
涉及权限、价格、资金时，必须能在原文中定位到依据。]]

M.DOCUMENT_KINDS = {
  {
    key = "prd",
    title = "PRD / 需求说明",
    aliases = { "PRD", "需求说明", "需求文档" },
    focus_model_codes = { 1, 2, 3, 4, 5, 6 },
    instruction = "优先抽取产品定位、模块、功能、页面、流程、状态规则和权限。接口与系统关系仅在文档写到时抽取，不要补全未写的对接细节。",
  },
  {
    key = "manual",
    title = "操作手册",
    aliases = { "操作手册", "用户手册", "使用说明" },
    focus_model_codes = { 2, 6, 9 },
    instruction = "优先抽取角色、页面、关键操作路径和操作权限。把「谁在哪一页做什么」写成实例，不要把培训口吻扩写成新功能。",
  },
  {
    key = "api",
    title = "接口说明",
    aliases = { "接口说明", "API", "接口文档" },
    focus_model_codes = { 3, 7 },
    instruction = "优先抽取对象字段、系统、接口、数据流。请求/响应字段写入对象或接口实例，不要把示例 JSON 误当成页面或角色。",
  },
  {
    key = "training",
    title = "培训材料",
    aliases = { "培训", "课件" },
    focus_model_codes = { 2, 6, 9 },
    instruction = "优先抽取角色日常任务、页面路径和常见场景。口号和激励话术不要写成业务规则。",
  },
  {
    key = "other",
    title = "其他",
    aliases = { "其他" },
    focus_model_codes = {},
    instruction = "按文档实际出现的对象抽取，不要为了覆盖十大模型而补全。",
  },
}

local FIELD_TYPES = { text = true, textarea = true, select = true }

local function skill_row(kind, ref_key)
  return db.one(
    "SELECT * FROM extract_skills WHERE kind = ? AND ref_key = ?",
    { kind, ref_key or "" }
  )
end

--- 目录默认字段。
function M.catalog_fields(type_id)
  local raw = catalog.get_type(type_id)
  if not raw then
    return {}
  end
  return catalog.hydrate(raw).fields or {}
end

local function clean_field(item, custom)
  local key = tostring((item and item.key) or ""):gsub("%s+", "")
  if not string.match(key, "^[A-Za-z][A-Za-z0-9_]*$") then
    return nil
  end
  local ftype = tostring((item and item.type) or "textarea")
  if not FIELD_TYPES[ftype] then
    ftype = "textarea"
  end
  local options = {}
  if item and type(item.options) == "table" then
    for _, opt in ipairs(item.options) do
      local s = tostring(opt or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if s ~= "" then
        table.insert(options, s)
      end
    end
  end
  return {
    key = key,
    label = util.clip((item and item.label) or key, 64),
    type = ftype,
    required = not not (item and item.required),
    fill_hint = tostring((item and item.fill_hint) or ""),
    options = util.arr(options),
    custom = not not custom or not not (item and item.custom),
  }
end

local function fields_overlay(row)
  if not row or not row.fields_json or row.fields_json == "" then
    return {}
  end
  local data = util.decode(row.fields_json, {})
  if data[1] then
    return { fields = data, hidden_keys = {} }
  end
  return {
    fields = type(data.fields) == "table" and data.fields or {},
    hidden_keys = type(data.hidden_keys) == "table" and data.hidden_keys or {},
  }
end

--- 治理 / 抽取实际字段。
function M.effective_fields(type_id)
  local catalog_fields = M.catalog_fields(type_id)
  local overlay = fields_overlay(skill_row("type", type_id))
  local saved = overlay.fields or {}
  local hidden_list = overlay.hidden_keys or {}
  if #saved == 0 and #hidden_list == 0 then
    return catalog_fields
  end
  local catalog_map = {}
  for _, field in ipairs(catalog_fields) do
    catalog_map[field.key] = field
  end
  local hidden = {}
  for _, key in ipairs(hidden_list) do
    hidden[tostring(key)] = true
  end
  local result = {}
  local seen = {}
  if #saved > 0 then
    for _, item in ipairs(saved) do
      if type(item) == "table" then
        local key = tostring(item.key or ""):gsub("%s+", "")
        if key ~= "" and not hidden[key] and not seen[key] then
          local cleaned = clean_field(item, catalog_map[key] == nil)
          if cleaned then
            if catalog_map[key] then
              cleaned.custom = false
              if #(cleaned.options or {}) == 0 and catalog_map[key].options then
                cleaned.options = catalog_map[key].options
              end
            end
            table.insert(result, cleaned)
            seen[key] = true
          end
        end
      end
    end
    for _, field in ipairs(catalog_fields) do
      if not seen[field.key] and not hidden[field.key] then
        table.insert(result, field)
        seen[field.key] = true
      end
    end
    return result
  end
  for _, field in ipairs(catalog_fields) do
    if not hidden[field.key] then
      table.insert(result, field)
    end
  end
  return result
end

--- 对象类型元数据（字段含技能覆盖）。
function M.resolve_type(type_id)
  local raw = catalog.get_type(type_id)
  if not raw then
    return {}
  end
  local meta = catalog.hydrate(raw)
  meta.fields = M.effective_fields(type_id)
  return meta
end

--- 归一文档种类。
function M.normalize_kind(label)
  local text = tostring(label or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    return "other"
  end
  local lower = string.lower(text)
  for _, item in ipairs(M.DOCUMENT_KINDS) do
    if item.key == lower or item.title == text then
      return item.key
    end
    for _, alias in ipairs(item.aliases or {}) do
      if string.find(lower, string.lower(alias), 1, true) or string.find(text, alias, 1, true) then
        return item.key
      end
    end
  end
  return "other"
end

local function kind_item(key)
  for _, item in ipairs(M.DOCUMENT_KINDS) do
    if item.key == key then
      return item
    end
  end
  return M.DOCUMENT_KINDS[#M.DOCUMENT_KINDS]
end

local function types_for_codes(codes)
  local wanted = {}
  for _, c in ipairs(codes or {}) do
    wanted[tonumber(c)] = true
  end
  local rows = {}
  for _, item in ipairs(catalog.TYPES) do
    if wanted[item.model_code] then
      table.insert(rows, {
        type_id = item.entity_id,
        name = item.name,
        model_code = item.model_code,
        model_name = item.model_name,
      })
    end
  end
  return rows
end

local function default_type_instruction(meta)
  local note = (meta.change_note or meta.description or "")
  local lines = {
    "对象 " .. meta.entity_id .. " " .. meta.name .. "。核心问句：" .. (meta.core_question or ""),
  }
  if note ~= "" then
    table.insert(lines, "填写说明：" .. note)
  end
  table.insert(lines, "只填写与前端治理详情相同的字段 key；找不到原文依据的字段留空。")
  return table.concat(lines, "\n")
end

--- 某类型技能详情。
function M.type_skill_detail(type_id)
  local raw = catalog.get_type(type_id)
  if not raw then
    return {}
  end
  local meta = catalog.hydrate(raw)
  local row = skill_row("type", type_id)
  local fields = M.effective_fields(type_id)
  return {
    type_id = type_id,
    name = meta.name,
    model_code = meta.model_code,
    model_name = meta.model_name,
    instruction = (row and row.instruction ~= "" and row.instruction) or default_type_instruction(meta),
    examples = (row and row.examples) or "",
    fields = util.arr(fields),
    catalog_fields = util.arr(M.catalog_fields(type_id)),
    overridden = not not row,
  }
end

--- 列出全局 / 文档种类 / 对象类型技能。
function M.list_skills()
  local global_row = skill_row("global", "")
  local documents = {}
  for _, kind in ipairs(M.DOCUMENT_KINDS) do
    local row = skill_row("document", kind.key)
    table.insert(documents, {
      key = kind.key,
      title = kind.title,
      instruction = (row and row.instruction ~= "" and row.instruction) or kind.instruction,
      examples = (row and row.examples) or "",
      focus_model_codes = util.arr(kind.focus_model_codes),
      related_types = util.arr(types_for_codes(kind.focus_model_codes)),
      overridden = not not row,
    })
  end
  local types = {}
  for _, item in ipairs(catalog.TYPES) do
    table.insert(types, M.type_skill_detail(item.entity_id))
  end
  return {
    global = {
      instruction = (global_row and global_row.instruction ~= "" and global_row.instruction) or M.DEFAULT_GLOBAL,
      examples = (global_row and global_row.examples) or "",
      overridden = not not global_row,
    },
    documents = util.arr(documents),
    types = util.arr(types),
  }
end

--- 保存技能覆盖。
function M.upsert(body, username)
  local kind = tostring(body.kind or "")
  local ref_key = tostring(body.ref_key or "")
  if kind == "type" and not catalog.get_type(ref_key) then
    error("对象类型不存在")
  end
  local fields_json = ""
  if kind == "type" and (body.fields or body.hidden_keys) then
    local catalog_keys = {}
    for _, field in ipairs(M.catalog_fields(ref_key)) do
      catalog_keys[field.key] = true
    end
    local cleaned = {}
    local seen = {}
    for _, item in ipairs(body.fields or {}) do
      local row = clean_field(item, not catalog_keys[tostring((item or {}).key or "")])
      if row and not seen[row.key] then
        table.insert(cleaned, row)
        seen[row.key] = true
      end
    end
    local hidden = {}
    for _, key in ipairs(body.hidden_keys or {}) do
      local text = tostring(key or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if text ~= "" then
        table.insert(hidden, text)
      end
    end
    if #cleaned > 0 or #hidden > 0 then
      fields_json = util.encode({ fields = cleaned, hidden_keys = hidden })
    end
  end
  local focus = util.encode(body.focus_model_codes or {})
  local exist = skill_row(kind, ref_key)
  if exist then
    db.exec(
      "UPDATE extract_skills SET instruction = ?, examples = ?, focus_models = ?, fields_json = ?, updated_by = ?, updated_at = ? WHERE id = ?",
      {
        body.instruction or "",
        body.examples or "",
        focus,
        fields_json ~= "" and fields_json or (exist.fields_json or ""),
        username or "",
        util.now(),
        exist.id,
      }
    )
  else
    db.exec(
      "INSERT INTO extract_skills (kind, ref_key, instruction, examples, focus_models, fields_json, updated_by, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      {
        kind,
        ref_key,
        body.instruction or "",
        body.examples or "",
        focus,
        fields_json,
        username or "",
        util.now(),
      }
    )
  end
  if kind == "type" then
    return M.type_skill_detail(ref_key)
  end
  return M.list_skills()
end

--- 恢复默认。
function M.reset(kind, ref_key)
  db.exec("DELETE FROM extract_skills WHERE kind = ? AND ref_key = ?", { kind, ref_key or "" })
  return M.list_skills()
end

--- 类型技能转 CSV。
function M.type_skill_csv(type_id)
  local detail = M.type_skill_detail(type_id)
  if not detail.name then
    error("对象类型不存在")
  end
  local rows = { { "key", "label", "type", "required", "fill_hint", "options" } }
  for _, field in ipairs(detail.fields or {}) do
    local opts = field.options or {}
    table.insert(rows, {
      field.key,
      field.label,
      field.type,
      field.required and "1" or "0",
      field.fill_hint or "",
      table.concat(opts, "|"),
    })
  end
  return util.csv(rows)
end

--- 全部类型技能 CSV。
function M.all_type_skills_csv()
  local rows = { { "type_id", "type_name", "model_code", "key", "label", "type", "required", "fill_hint" } }
  for _, item in ipairs(catalog.TYPES) do
    local detail = M.type_skill_detail(item.entity_id)
    for _, field in ipairs(detail.fields or {}) do
      table.insert(rows, {
        item.entity_id,
        item.name,
        item.model_code,
        field.key,
        field.label,
        field.type,
        field.required and "1" or "0",
        field.fill_hint or "",
      })
    end
  end
  return util.csv(rows)
end

--- 拼抽取提示。
function M.compose_instruction(type_ids, document_kind, extra)
  local parts = { M.DEFAULT_GLOBAL }
  local global_row = skill_row("global", "")
  if global_row and global_row.instruction ~= "" then
    parts[1] = global_row.instruction
  end
  local kind = M.normalize_kind(document_kind or "other")
  local ki = kind_item(kind)
  local drow = skill_row("document", kind)
  table.insert(parts, "文档种类：" .. ki.title)
  table.insert(parts, (drow and drow.instruction ~= "" and drow.instruction) or ki.instruction)
  for _, tid in ipairs(type_ids or {}) do
    local meta = catalog.get_type(tid)
    if meta then
      local trow = skill_row("type", tid)
      table.insert(parts, default_type_instruction(catalog.hydrate(meta)))
      if trow and trow.instruction ~= "" then
        table.insert(parts, trow.instruction)
      end
      local fields = M.effective_fields(tid)
      table.insert(parts, "治理字段（与前端详情页相同，payload 只用这些 key）：")
      for _, field in ipairs(fields) do
        local req = field.required and "必填" or "选填"
        table.insert(parts, "- " .. field.key .. "（" .. field.label .. "，" .. req .. "，" .. (field.type or "textarea") .. "）")
      end
    end
  end
  if extra and extra ~= "" then
    table.insert(parts, extra)
  end
  return table.concat(parts, "\n")
end

return M
