-- 知识应用 Token 与开放目录

local db = ctx.require("db")
local pack_mod = ctx.require("pack")
local products = ctx.require("products")
local util = ctx.require("util")

local M = {}

M.V1_ENDPOINTS = {
  { method = "GET", path = "/v1/knowledge/products", desc = "列出产品与已治理覆盖" },
  { method = "GET", path = "/v1/knowledge/products/{id}/prompt", desc = "取该产品 System Prompt" },
  { method = "GET", path = "/v1/knowledge/products/{id}/pack?fmt=json|system|rag|sft|pretrain|corpus", desc = "导出知识包" },
  { method = "POST", path = "/v1/knowledge/search", desc = "RAG 检索已治理切片" },
  { method = "POST", path = "/v1/knowledge/ask", desc = "跨产品知识问答" },
  { method = "GET", path = "/v1/knowledge/entities?product_id=&type_id=", desc = "只读对象实例" },
  { method = "GET", path = "/v1/knowledge/releases", desc = "知识包版本列表" },
  { method = "GET", path = "/v1/knowledge/releases/latest?scope=&product_id=", desc = "最新知识包版本" },
  { method = "GET", path = "/v1/knowledge/releases/{id}", desc = "某版本详情 / System Prompt" },
  { method = "GET", path = "/v1/knowledge/releases/{id}/download?fmt=json|system|rag|sft|pretrain|corpus", desc = "下载冻结版本" },
}

local function parse_ids(raw)
  local data = type(raw) == "table" and raw or util.decode(raw or "[]", {})
  local out = {}
  if type(data) == "table" then
    for _, v in ipairs(data) do
      local n = tonumber(v)
      if n then
        table.insert(out, n)
      end
    end
  end
  return out
end

function M.hash_token(raw)
  return ctx.utils.sha256(raw or "")
end

function M.serialize_app(item, token)
  local data = {
    id = item.id,
    name = item.name,
    note = item.note or "",
    token_prefix = item.token_prefix,
    product_ids = util.arr(parse_ids(item.product_ids)),
    revoked = util.is_true(item.revoked),
    created_by = item.created_by or "",
    created_at = item.created_at,
    last_used_at = item.last_used_at,
  }
  if token then
    data.token = token
  end
  return data
end

function M.create_app(name, note, product_ids, username)
  local raw = "pkm_" .. string.gsub(ctx.utils.uuid(), "-", "") .. ctx.utils.uuid():gsub("-", ""):sub(1, 16)
  local ins = db.exec(
    [[INSERT INTO knowledge_apps (name, note, token_prefix, token_hash, product_ids, revoked, created_by, created_at)
      VALUES (?, ?, ?, ?, ?, 0, ?, ?)]],
    {
      (name or "") ~= "" and name or "未命名应用",
      note or "",
      string.sub(raw, 1, 12),
      M.hash_token(raw),
      util.encode(parse_ids(product_ids)),
      username or "",
      util.now(),
    }
  )
  local row = db.one("SELECT * FROM knowledge_apps WHERE id = ?", { ins.insert_id })
  return M.serialize_app(row, raw)
end

function M.resolve_app(raw)
  local token = tostring(raw or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if token == "" then
    return nil
  end
  local item = db.one(
    "SELECT * FROM knowledge_apps WHERE token_hash = ? AND revoked = 0",
    { M.hash_token(token) }
  )
  if item then
    db.exec("UPDATE knowledge_apps SET last_used_at = ? WHERE id = ?", { util.now(), item.id })
  end
  return item
end

function M.assert_product(app, product_id)
  local ids = parse_ids(app.product_ids)
  if #ids > 0 then
    local ok = false
    for _, id in ipairs(ids) do
      if id == product_id then
        ok = true
        break
      end
    end
    if not ok then
      error("该应用无权访问此产品")
    end
  end
end

function M.product_card(product)
  local built = pack_mod.build(product, {})
  local summary = built.summary or {}
  local llm = built.llm_input or {}
  local card = products.serialize_product(product)
  card.type_ready = summary.type_ready or 0
  card.type_total = summary.type_total or 0
  card.corpus_docs = summary.corpus_docs or 0
  card.triples = summary.triples or 0
  card.complete = not not summary.complete
  card.system_prompt = llm.system_prompt or ""
  return card
end

function M.catalog()
  local rows = db.query("SELECT * FROM products ORDER BY id")
  local cards = {}
  local corpus = 0
  local ready = 0
  for _, p in ipairs(rows) do
    local card = M.product_card(p)
    table.insert(cards, card)
    corpus = corpus + (card.corpus_docs or 0)
    ready = ready + (card.type_ready or 0)
  end
  return {
    global_prompt = "你是产品知识助手，只依据已治理知识回答，不要编造。",
    api_base = "/v1/knowledge",
    auth = "Authorization: Bearer pkm_... 或请求头 X-Api-Key",
    endpoints = util.arr(M.V1_ENDPOINTS),
    products = util.arr(cards),
    summary = {
      product_total = #rows,
      corpus_docs = corpus,
      type_ready = ready,
    },
  }
end

return M
