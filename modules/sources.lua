-- 来源文档：纯文本接入，原文件解析后续迭代

local db = ctx.require("db")
local util = ctx.require("util")

local M = {}

--- 来源出参。
function M.serialize(row, coverage)
  local meta = util.decode(row.extract_meta, {})
  return {
    id = row.id,
    product_id = row.product_id,
    title = row.title,
    source_type = row.source_type,
    url = row.url or "",
    file_path = row.file_path or "",
    content = row.content or "",
    status = row.status,
    extract_status = row.extract_status,
    extract_meta = meta,
    target_type_id = row.target_type_id or "",
    error_message = row.error_message or "",
    created_by = row.created_by or "",
    created_at = row.created_at,
    updated_at = row.updated_at,
    coverage = coverage,
    document_kind = meta.document_kind or "",
    scan_summary = meta.summary or "",
  }
end

--- 覆盖的对象类型。
function M.coverage_for(source_ids)
  local result = {}
  for _, sid in ipairs(source_ids or {}) do
    result[sid] = { type_ids = {}, entity_count = 0 }
  end
  if not source_ids or #source_ids == 0 then
    return result
  end
  for _, sid in ipairs(source_ids) do
    local rows = db.query(
      [[SELECT e.type_id, COUNT(*) AS n
        FROM source_bindings b
        JOIN knowledge_entities e ON e.id = b.entity_id
        WHERE b.source_id = ?
        GROUP BY e.type_id]],
      { sid }
    )
    local types = {}
    local n = 0
    for _, row in ipairs(rows) do
      table.insert(types, row.type_id)
      n = n + (tonumber(row.n) or 0)
    end
    result[sid] = { type_ids = util.arr(types), entity_count = n }
  end
  return result
end

--- 拒绝二进制文件名。
function M.assert_plain_filename(name)
  local lower = string.lower(name or "")
  if string.match(lower, "%.docx$") or string.match(lower, "%.pdf$") or string.match(lower, "%.xlsx$") or string.match(lower, "%.xlsm$") then
    error("本期仅支持纯文本（.txt / .md / .html），原文件解析将后续迭代")
  end
end

--- 抓取 URL 正文（尽力取 HTML/文本）。
function M.fetch_url(url)
  local res, err = ctx.http.get(url, { read_timeout = 15000 })
  if err then
    error(err)
  end
  if not res or not res.ok then
    error("抓取失败：" .. tostring(res and res.status))
  end
  local body = res.body or ""
  body = body:gsub("<script[%s%S]-</script>", " ")
  body = body:gsub("<style[%s%S]-</style>", " ")
  body = body:gsub("<[^>]+>", " ")
  body = body:gsub("&nbsp;", " ")
  body = body:gsub("%s+", " ")
  return body
end

return M
