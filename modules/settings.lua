-- 系统设置与 OpenAI 兼容 chat

local db = ctx.require("db")
local util = ctx.require("util")

local M = {}

local SECRET_KEYS = {
  llm_api_key = true,
  feishu_app_secret = true,
  feishu_user_access_token = true,
  joyspace_cookie = true,
}

--- 读取全部设置。
function M.get_map()
  local rows = db.query("SELECT setting_key, value FROM app_settings")
  local out = {}
  for _, row in ipairs(rows) do
    out[row.setting_key] = row.value or ""
  end
  return out
end

--- 批量写入。
function M.put_map(data)
  for key, value in pairs(data or {}) do
    if type(key) == "string" then
      local exist = db.one("SELECT setting_key FROM app_settings WHERE setting_key = ?", { key })
      if exist then
        db.exec("UPDATE app_settings SET value = ?, updated_at = ? WHERE setting_key = ?", { tostring(value or ""), util.now(), key })
      else
        db.exec("INSERT INTO app_settings (setting_key, value, updated_at) VALUES (?, ?, ?)", { key, tostring(value or ""), util.now() })
      end
    end
  end
  return M.get_map()
end

--- 非管理员脱敏。
function M.mask(map, is_admin)
  if is_admin then
    return map
  end
  local out = {}
  for k, v in pairs(map) do
    if SECRET_KEYS[k] and v ~= "" then
      out[k] = "******"
    else
      out[k] = v
    end
  end
  return out
end

--- 调用 chat/completions，返回文本。
function M.chat(settings, messages)
  local base = tostring(settings.llm_base_url or ""):gsub("/+$", "")
  local model = tostring(settings.llm_model or "")
  if base == "" or model == "" then
    error("请先在系统设置中配置大模型 Base URL 与模型名")
  end
  local headers = { ["Content-Type"] = "application/json" }
  if settings.llm_api_key and settings.llm_api_key ~= "" then
    headers.Authorization = "Bearer " .. settings.llm_api_key
  end
  local res, err = ctx.http.post(base .. "/chat/completions", {
    model = model,
    messages = messages,
    temperature = 0.2,
  }, { headers = headers, read_timeout = 28000 })
  if err then
    error(err)
  end
  if not res or not res.ok then
    local msg = "大模型接口失败"
    if res and res.json and res.json.error then
      local e = res.json.error
      if type(e) == "table" then
        msg = tostring(e.message or e)
      else
        msg = tostring(e)
      end
    elseif res then
      msg = "接口返回 " .. tostring(res.status)
    end
    error(msg)
  end
  local data = res.json or util.decode(res.body, {})
  local choices = data.choices or {}
  local first = choices[1] or {}
  local message = first.message or {}
  return tostring(message.content or "")
end

--- 保存后短对话探测。
function M.probe(settings)
  local base = tostring(settings.llm_base_url or ""):gsub("/+$", "")
  local model = tostring(settings.llm_model or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if base == "" or model == "" then
    return { ok = false, error = "请填写 Base URL 与模型名后再保存验证" }
  end
  local started = ctx.utils.now_ms()
  local ok, text = pcall(function()
    return M.chat(settings, { { role = "user", content = "请只回复：OK" } })
  end)
  local latency = ctx.utils.now_ms() - started
  if not ok then
    return { ok = false, error = tostring(text), latency_ms = latency }
  end
  return { ok = true, model = model, latency_ms = latency, reply = util.clip(text, 80) }
end

--- 从模型输出里抽出 JSON。
function M.extract_json(text)
  local raw = tostring(text or "")
  local start_obj = raw:find("{", 1, true)
  local start_arr = raw:find("[", 1, true)
  local start
  if start_obj and start_arr then
    start = math.min(start_obj, start_arr)
  else
    start = start_obj or start_arr
  end
  if not start then
    return nil
  end
  local sliced = raw:sub(start)
  local ok, data = pcall(function()
    return ctx.utils.json_decode(sliced)
  end)
  if ok and type(data) == "table" then
    return data
  end
  local last_brace = sliced:match(".*()[}%]]")
  if last_brace then
    ok, data = pcall(function()
      return ctx.utils.json_decode(sliced:sub(1, last_brace))
    end)
    if ok and type(data) == "table" then
      return data
    end
  end
  return nil
end

M.SECRET_KEYS = SECRET_KEYS
return M
