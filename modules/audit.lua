-- 操作与访问审计

local db = ctx.require("db")
local util = ctx.require("util")

local M = {}

--- 写一条日志。
function M.write(user, fields)
  fields = fields or {}
  db.exec(
    [[INSERT INTO audit_logs
      (created_at, username, display_name, role, action, category, resource, summary, method, path, status_code, ip, product_id, detail)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
    {
      util.now(),
      user and user.username or fields.username or "",
      user and user.display_name or "",
      user and user.role or "",
      fields.action or "other",
      fields.category or "",
      util.clip(fields.resource or "", 256),
      util.clip(fields.summary or "", 512),
      fields.method or ctx.req.method(),
      util.clip(fields.path or ctx.req.path() or "", 256),
      fields.status_code or 200,
      ctx.req.header("X-Forwarded-For") or ctx.req.header("x-real-ip") or "",
      fields.product_id,
      fields.detail or "",
    }
  )
end

--- 短时间重复访问去重。
function M.recently(username, action, path, seconds)
  local row = db.one(
    [[SELECT id FROM audit_logs
      WHERE username = ? AND action = ? AND path = ?
      AND created_at >= datetime('now', ?)
      ORDER BY id DESC LIMIT 1]],
    { username, action, path, string.format("-%d seconds", seconds or 30) }
  )
  return not not row
end

return M
