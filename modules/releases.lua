-- 知识包冻结版本

local db = ctx.require("db")
local pack = ctx.require("pack")
local products = ctx.require("products")
local util = ctx.require("util")

local M = {}

local function parse_ids(raw)
  if type(raw) == "table" then
    local out = {}
    for _, v in ipairs(raw) do
      table.insert(out, tonumber(v))
    end
    return out
  end
  local data = util.decode(raw or "[]", {})
  local out = {}
  if type(data) == "table" then
    for _, v in ipairs(data) do
      table.insert(out, tonumber(v))
    end
  end
  return out
end

--- 列表项。
function M.serialize(row, include_pack)
  local data = {
    id = row.id,
    version_no = row.version_no,
    name = row.name,
    scope = row.scope,
    product_ids = util.arr(parse_ids(row.product_ids)),
    trigger = row["trigger"] or row.trigger,
    note = row.note or "",
    product_count = row.product_count,
    entity_count = row.entity_count,
    type_ready = row.type_ready,
    corpus_docs = row.corpus_docs,
    created_by = row.created_by or "",
    created_at = row.created_at,
  }
  if include_pack then
    data.pack = util.decode(row.pack_json, {})
  end
  return data
end

--- 冻结当前知识。
function M.create(body, username)
  local scope = body.scope or "product"
  local pids = parse_ids(body.product_ids or {})
  if scope == "product" and #pids == 0 then
    error("请选择产品")
  end
  local packs = {}
  local product_count = 0
  local entity_count = 0
  local type_ready = 0
  local corpus_docs = 0
  local targets = {}
  if scope == "combined" or #pids == 0 then
    targets = db.query("SELECT * FROM products ORDER BY id")
  else
    for _, pid in ipairs(pids) do
      local p = db.one("SELECT * FROM products WHERE id = ?", { pid })
      if p then
        table.insert(targets, p)
      end
    end
  end
  for _, product in ipairs(targets) do
    local built = pack.build(product, {})
    table.insert(packs, built)
    product_count = product_count + 1
    entity_count = entity_count + (built.summary.entity_total or 0)
    type_ready = type_ready + (built.summary.type_ready or 0)
    corpus_docs = corpus_docs + (built.summary.corpus_docs or 0)
  end
  local maxn = db.one("SELECT COALESCE(MAX(version_no), 0) AS n FROM knowledge_releases")
  local version_no = (tonumber(maxn and maxn.n) or 0) + 1
  local ins = db.exec(
    [[INSERT INTO knowledge_releases
      (version_no, name, scope, product_ids, `trigger`, note, product_count, entity_count, type_ready, corpus_docs, pack_json, created_by, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
    {
      version_no,
      body.name or ("v" .. tostring(version_no)),
      scope,
      util.encode(pids),
      body.trigger or "manual",
      body.note or "",
      product_count,
      entity_count,
      type_ready,
      corpus_docs,
      util.encode({ products = packs }),
      username or "",
      util.now(),
    }
  )
  local row = db.one("SELECT * FROM knowledge_releases WHERE id = ?", { ins.insert_id })
  return M.serialize(row, false)
end

return M
