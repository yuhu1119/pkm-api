-- 路径匹配、JSON、数组标记与请求小工具

local M = {}

local STEWARD_KEYS = {
  steward_name = true,
  steward_role = true,
  steward_team = true,
  maintainer = true,
  owner = true,
  ["维护人"] = true,
}

--- 把 table 标成 JSON 数组；空表必须是 [] 而不是 {}。
function M.arr(t)
  if type(t) ~= "table" or t[1] == nil then
    return ctx.utils.empty_array()
  end
  return ctx.utils.array(t)
end

--- 解码 JSON 字符串。
function M.decode(raw, fallback)
  if raw == nil or raw == "" then
    return fallback or {}
  end
  local ok, data = pcall(function()
    return ctx.utils.json_decode(raw)
  end)
  if not ok or type(data) ~= "table" then
    return fallback or {}
  end
  return data
end

--- 编码 JSON。
function M.encode(value)
  return ctx.utils.json_encode(value == nil and {} or value)
end

--- 当前时间，格式与 SQLite datetime 文本一致。
function M.now()
  return ctx.utils.now_str()
end

--- 去掉项目前缀，得到 /api/... 或 /v1/...。
function M.logical_path(path)
  path = path or ctx.req.path() or ""
  local api_at = path:find("/api/", 1, true)
  if api_at then
    return path:sub(api_at)
  end
  local v1_at = path:find("/v1/", 1, true)
  if v1_at then
    return path:sub(v1_at)
  end
  return path
end

--- 按 / 切路径，去掉空段。
function M.split_path(path)
  local parts = {}
  for seg in string.gmatch(path or "", "[^/]+") do
    table.insert(parts, seg)
  end
  return parts
end

--- 匹配 /api/products/:id 这类模式，成功返回捕获表。
function M.match_route(pattern, path)
  local pp = M.split_path(pattern)
  local tp = M.split_path(path)
  if #pp ~= #tp then
    return nil
  end
  local cap = {}
  for i = 1, #pp do
    local p = pp[i]
    local t = tp[i]
    if string.sub(p, 1, 1) == ":" then
      cap[string.sub(p, 2)] = t
    elseif p ~= t then
      return nil
    end
  end
  return cap
end

--- 读 JSON 请求体。
function M.body()
  local ok, data = pcall(function()
    return ctx.req.json()
  end)
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

--- 当前工作台产品 ID（请求头优先）。
function M.header_product_id()
  local raw = ctx.req.header("X-Product-Id") or ctx.req.header("x-product-id") or ctx.req.query("product_id") or "0"
  return tonumber(raw) or 0
end

--- 查询参数转整数列表，逗号分隔。
function M.split_ints(raw)
  local out = {}
  for item in string.gmatch(raw or "", "[^,]+") do
    local n = tonumber((item:gsub("%s+", "")))
    if n then
      table.insert(out, n)
    end
  end
  return out
end

--- 查询参数转字符串列表。
function M.split_strs(raw)
  local out = {}
  for item in string.gmatch(raw or "", "[^,]+") do
    local s = item:gsub("^%s+", ""):gsub("%s+$", "")
    if s ~= "" then
      table.insert(out, s)
    end
  end
  return out
end

--- 标签存储串。
function M.tags_to_str(tags)
  if type(tags) ~= "table" then
    return ""
  end
  local parts = {}
  for _, item in ipairs(tags) do
    local s = tostring(item or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s ~= "" then
      table.insert(parts, s)
    end
  end
  return table.concat(parts, ",")
end

--- 标签解析。
function M.tags_from_str(value)
  local out = {}
  for item in string.gmatch(value or "", "[^,]+") do
    local s = item:gsub("^%s+", ""):gsub("%s+$", "")
    if s ~= "" then
      table.insert(out, s)
    end
  end
  return M.arr(out)
end

--- 去掉治理责任字段，避免污染知识正文。
function M.strip_steward(payload)
  local out = {}
  if type(payload) ~= "table" then
    return out
  end
  for k, v in pairs(payload) do
    if type(k) == "string" and not STEWARD_KEYS[k] then
      out[k] = v
    end
  end
  return out
end

--- CSV 单元格转义。
function M.csv_cell(value)
  local s = tostring(value or "")
  if string.find(s, '[,"\n]', 1) then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

--- 拼 CSV 文本。
function M.csv(rows)
  local lines = {}
  for _, row in ipairs(rows or {}) do
    local cells = {}
    for _, cell in ipairs(row) do
      table.insert(cells, M.csv_cell(cell))
    end
    table.insert(lines, table.concat(cells, ","))
  end
  return table.concat(lines, "\n")
end

--- 布尔：库内 0/1。
function M.is_true(v)
  return v == true or v == 1 or v == "1"
end

--- 截断字符串。
function M.clip(s, n)
  s = tostring(s or "")
  if #s <= n then
    return s
  end
  return string.sub(s, 1, n)
end

return M
