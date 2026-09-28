-- 纯文本抽取：调用 OpenAI 兼容接口，不解析 Word/PDF

local catalog = ctx.require("catalog")
local db = ctx.require("db")
local settings = ctx.require("settings")
local skills = ctx.require("skills")
local util = ctx.require("util")

local M = {}

local function clip_text(text)
  text = tostring(text or "")
  if #text > 24000 then
    return string.sub(text, 1, 24000)
  end
  return text
end

--- 按单一类型抽一条。
function M.extract_entity(type_id, text, extra, document_kind)
  local meta = skills.resolve_type(type_id)
  if not meta.name then
    error("对象类型不存在")
  end
  local instruction = skills.compose_instruction({ type_id }, document_kind, extra)
  local prompt = instruction
    .. "\n\n请只返回一个 JSON 对象：{type_id,name,summary,payload,tags}。payload 只用列出的字段 key。\n正文：\n"
    .. clip_text(text)
  local conf = settings.get_map()
  local raw = settings.chat(conf, {
    { role = "system", content = "你是产品知识抽取器，只输出 JSON。" },
    { role = "user", content = prompt },
  })
  local data = settings.extract_json(raw) or {}
  local payload = type(data.payload) == "table" and util.strip_steward(data.payload) or {}
  return {
    type_id = type_id,
    entity_id = type_id,
    name = tostring(data.name or meta.name),
    summary = tostring(data.summary or ""),
    payload = payload,
    tags = type(data.tags) == "table" and data.tags or {},
    model_code = meta.model_code,
  }
end

--- 识别文档种类与命中类型。
function M.scan(text)
  local conf = settings.get_map()
  local names = {}
  for _, t in ipairs(catalog.TYPES) do
    table.insert(names, t.entity_id .. " " .. t.name)
  end
  local prompt = "根据正文判断文档种类（prd/manual/api/training/other），列出涉及的一级模型编号和对象类型。只返回 JSON："
    .. '{"document_kind":"","summary":"","model_codes":[],"type_hits":[{"type_id":"","mention":""}]}\n正文：\n'
    .. clip_text(text)
  local raw = settings.chat(conf, {
    { role = "system", content = "只输出 JSON。" },
    { role = "user", content = prompt },
  })
  local data = settings.extract_json(raw) or {}
  local kind = skills.normalize_kind(data.document_kind or "other")
  local hits = {}
  for _, hit in ipairs(data.type_hits or {}) do
    if type(hit) == "table" and catalog.get_type(hit.type_id) then
      table.insert(hits, { type_id = hit.type_id, mention = tostring(hit.mention or "") })
    end
  end
  return {
    document_kind = kind,
    summary = tostring(data.summary or ""),
    model_codes = util.arr(data.model_codes or {}),
    type_hits = util.arr(hits),
    document_kind_skill = { related_types = util.arr({}) },
  }
end

--- 抽某一个一级模型下的多条实例。
function M.extract_model(text, model_code, extra, skip, document_kind)
  local type_ids = {}
  for _, t in ipairs(catalog.TYPES) do
    if t.model_code == model_code and not (skip and skip[t.entity_id]) then
      table.insert(type_ids, t.entity_id)
    end
  end
  local instruction = skills.compose_instruction(type_ids, document_kind, extra)
  local prompt = instruction
    .. "\n只返回 JSON 数组，每项 {type_id,name,summary,payload,tags}。不要编造。\n正文：\n"
    .. clip_text(text)
  local conf = settings.get_map()
  local raw = settings.chat(conf, {
    { role = "system", content = "只输出 JSON 数组。" },
    { role = "user", content = prompt },
  })
  local data = settings.extract_json(raw)
  local instances = {}
  local list = {}
  if type(data) == "table" then
    if data[1] then
      list = data
    elseif data.instances then
      list = data.instances
    end
  end
  for _, item in ipairs(list) do
    if type(item) == "table" and catalog.get_type(item.type_id) then
      table.insert(instances, {
        type_id = item.type_id,
        entity_id = item.type_id,
        name = tostring(item.name or ""),
        summary = tostring(item.summary or ""),
        payload = type(item.payload) == "table" and util.strip_steward(item.payload) or {},
        tags = type(item.tags) == "table" and item.tags or {},
        model_code = catalog.TYPE_MAP[item.type_id].model_code,
      })
    end
  end
  return util.arr(instances)
end

return M
