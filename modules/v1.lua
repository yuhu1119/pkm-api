-- 开放 API：Bearer pkm_ Token，不走 SSO

local apps = ctx.require("apps")
local db = ctx.require("db")
local entities = ctx.require("entities")
local governance = ctx.require("governance")
local pack_mod = ctx.require("pack")
local releases = ctx.require("releases")
local respond = ctx.require("respond")
local settings = ctx.require("settings")
local util = ctx.require("util")

local M = {}

local function bearer()
  local h = ctx.req.header("Authorization") or ctx.req.header("authorization") or ""
  if string.lower(string.sub(h, 1, 7)) == "bearer " then
    return string.sub(h, 8)
  end
  return ctx.req.header("X-Api-Key") or ctx.req.header("x-api-key") or ""
end

local function require_app()
  local app = apps.resolve_app(bearer())
  if not app then
    respond.fail(401, "无效或已作废的应用 Token")
    return nil
  end
  return app
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

--- 处理 /v1/knowledge* 。
function M.handle()
  local method = ctx.req.method()
  local path = util.logical_path()
  if #path > 1 and string.sub(path, -1) == "/" then
    path = string.sub(path, 1, -2)
  end
  local app = require_app()
  if not app then
    return
  end

  if method == "GET" and path == "/v1/knowledge" then
    return respond.json({ ok = true, auth = "Bearer pkm_... 或 X-Api-Key", endpoints = util.arr(apps.V1_ENDPOINTS) })
  end

  if method == "GET" and path == "/v1/knowledge/products" then
    local ids = util.decode(app.product_ids, {})
    local sql = "SELECT * FROM products ORDER BY id"
    local rows
    if type(ids) == "table" and ids[1] then
      local ph = {}
      local args = {}
      for i, id in ipairs(ids) do
        ph[i] = "?"
        args[i] = tonumber(id)
      end
      rows = db.query("SELECT * FROM products WHERE id IN (" .. table.concat(ph, ",") .. ") ORDER BY id", args)
    else
      rows = db.query(sql)
    end
    local cards = {}
    for _, p in ipairs(rows) do
      table.insert(cards, apps.product_card(p))
    end
    return respond.json(util.arr(cards))
  end

  local cap = util.match_route("/v1/knowledge/products/:id/prompt", path)
  if method == "GET" and cap then
    local pr = db.one("SELECT * FROM products WHERE id = ?", { tonumber(cap.id) })
    if not pr then
      return respond.fail(404, "产品不存在")
    end
    local ok, err = pcall(apps.assert_product, app, pr.id)
    if not ok then
      return respond.fail(403, tostring(err))
    end
    local built = pack_mod.build(pr, {})
    return respond.json({ system_prompt = built.llm_input.system_prompt })
  end

  cap = util.match_route("/v1/knowledge/products/:id/pack", path)
  if method == "GET" and cap then
    local pr = db.one("SELECT * FROM products WHERE id = ?", { tonumber(cap.id) })
    if not pr then
      return respond.fail(404, "产品不存在")
    end
    local ok, err = pcall(apps.assert_product, app, pr.id)
    if not ok then
      return respond.fail(403, tostring(err))
    end
    local fmt = ctx.req.query("fmt")
    local built = pack_mod.build(pr, {})
    if fmt and fmt ~= "" then
      local raw, mime, filename = pack_mod.encode_file(pr, built, fmt)
      return respond.download(raw, filename, mime)
    end
    return respond.json(built)
  end

  if method == "POST" and path == "/v1/knowledge/search" then
    local body = util.body()
    local q = body.question or body.q or ""
    local prs = db.query("SELECT * FROM products ORDER BY id")
    local hits = {}
    for _, pr in ipairs(prs) do
      local trial = pack_mod.trial(pr, q, { top_k = body.top_k or 8 })
      for _, h in ipairs(trial.hits or {}) do
        table.insert(hits, h)
      end
    end
    return respond.json({ hits = util.arr(hits) })
  end

  if method == "POST" and path == "/v1/knowledge/ask" then
    local body = util.body()
    local prs = db.query("SELECT * FROM products ORDER BY id")
    local messages
    local hits = {}
    for _, pr in ipairs(prs) do
      local trial = pack_mod.trial(pr, body.question or "", { top_k = 5 })
      messages = trial.messages
      for _, h in ipairs(trial.hits or {}) do
        table.insert(hits, h)
      end
    end
    local ok, text = pcall(function()
      return settings.chat(settings.get_map(), messages or { { role = "user", content = body.question } })
    end)
    return respond.json({ answer = ok and text or tostring(text), hits = util.arr(hits) })
  end

  if method == "GET" and path == "/v1/knowledge/entities" then
    local pid = tonumber(ctx.req.query("product_id"))
    local type_id = ctx.req.query("type_id")
    local sql = "SELECT * FROM knowledge_entities WHERE 1=1"
    local args = {}
    if pid then
      sql = sql .. " AND product_id = ?"
      table.insert(args, pid)
    end
    if type_id and type_id ~= "" then
      sql = sql .. " AND type_id = ?"
      table.insert(args, type_id)
    end
    sql = sql .. " ORDER BY id LIMIT 200"
    return respond.json(serialize_many(db.query(sql, args)))
  end

  if method == "GET" and path == "/v1/knowledge/releases" then
    local rows = db.query("SELECT * FROM knowledge_releases ORDER BY id DESC")
    local out = {}
    for _, row in ipairs(rows) do
      table.insert(out, releases.serialize(row, false))
    end
    return respond.json(util.arr(out))
  end

  if method == "GET" and path == "/v1/knowledge/releases/latest" then
    local row = db.one("SELECT * FROM knowledge_releases ORDER BY id DESC LIMIT 1")
    if not row then
      return respond.fail(404, "还没有知识版本")
    end
    return respond.json(releases.serialize(row, true))
  end

  cap = util.match_route("/v1/knowledge/releases/:id/download", path)
  if method == "GET" and cap then
    local row = db.one("SELECT * FROM knowledge_releases WHERE id = ?", { tonumber(cap.id) })
    if not row then
      return respond.fail(404, "版本不存在")
    end
    local data = util.decode(row.pack_json, {})
    local first = (data.products or {})[1] or data
    local pr = first.product or { id = 0, name = row.name }
    local raw, mime, filename = pack_mod.encode_file(pr, first, ctx.req.query("fmt") or "json")
    return respond.download(raw, filename, mime)
  end

  cap = util.match_route("/v1/knowledge/releases/:id", path)
  if method == "GET" and cap then
    local row = db.one("SELECT * FROM knowledge_releases WHERE id = ?", { tonumber(cap.id) })
    if not row then
      return respond.fail(404, "版本不存在")
    end
    return respond.json(releases.serialize(row, true))
  end

  respond.fail(404, "Not Found")
end

return M
