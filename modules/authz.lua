-- SSO 用户落库与模型权限

local db = ctx.require("db")
local util = ctx.require("util")
local respond = ctx.require("respond")

local M = {}

local function admin_set()
  local raw = ctx.env.ADMIN_USERNAMES or ""
  local set = {}
  for item in string.gmatch(raw, "[^,]+") do
    local s = item:gsub("^%s+", ""):gsub("%s+$", "")
    if s ~= "" then
      set[s] = true
    end
  end
  return set
end

local function ensure_perms(user_id, role)
  local write = role == "viewer" and 0 or 1
  local n = db.one("SELECT COUNT(*) AS n FROM user_model_permissions WHERE user_id = ?", { user_id })
  if n and tonumber(n.n) and tonumber(n.n) > 0 then
    return
  end
  for code = 1, 10 do
    db.exec(
      "INSERT INTO user_model_permissions (user_id, model_code, can_read, can_write) VALUES (?, ?, 1, ?)",
      { user_id, code, write }
    )
  end
end

--- 把权限行收成前端要的 map。
local function perm_map(user_id)
  local rows = db.query(
    "SELECT model_code, can_read, can_write FROM user_model_permissions WHERE user_id = ?",
    { user_id }
  )
  local out = {}
  for _, row in ipairs(rows) do
    out[tostring(row.model_code)] = {
      can_read = util.is_true(row.can_read),
      can_write = util.is_true(row.can_write),
    }
  end
  return out
end

--- 用户出参。
function M.to_out(row)
  return {
    id = row.id,
    username = row.username,
    display_name = row.display_name,
    role = row.role,
    model_permissions = perm_map(row.id),
  }
end

--- 用 SSO ctx.user 确保本地用户存在。首个用户或白名单为 admin。
function M.ensure_sso_user()
  if not ctx.user or not ctx.user.username then
    respond.fail(401, "需要平台 SSO 登录")
    return nil
  end
  local username = ctx.user.username
  local display = ctx.user.fullname or username
  local row = db.one("SELECT * FROM users WHERE username = ?", { username })
  if row then
    if display ~= "" and display ~= row.display_name then
      db.exec("UPDATE users SET display_name = ? WHERE id = ?", { display, row.id })
      row.display_name = display
    end
    ensure_perms(row.id, row.role)
    return row
  end
  local count = db.one("SELECT COUNT(*) AS n FROM users")
  local n = tonumber(count and count.n) or 0
  local role = "editor"
  if n == 0 or admin_set()[username] then
    role = "admin"
  end
  local ins = db.exec(
    "INSERT INTO users (username, display_name, password_hash, role, created_at) VALUES (?, ?, '', ?, ?)",
    { username, display, role, util.now() }
  )
  local user = db.one("SELECT * FROM users WHERE id = ?", { ins.insert_id })
  ensure_perms(user.id, role)
  return user
end

--- 要求已登录用户。
function M.require_user()
  return M.ensure_sso_user()
end

--- 要求角色。
function M.require_roles(user, ...)
  local allowed = { ... }
  for _, role in ipairs(allowed) do
    if user.role == role then
      return true
    end
  end
  respond.fail(403, "权限不足")
  return false
end

--- 只读用户不能写。
function M.require_editor(user)
  if user.role == "viewer" then
    respond.fail(403, "只读用户不能修改")
    return false
  end
  return true
end

--- 检查一级模型读写。
function M.assert_model_access(user, model_code, write)
  if user.role == "admin" then
    return true
  end
  local row = db.one(
    "SELECT can_read, can_write FROM user_model_permissions WHERE user_id = ? AND model_code = ?",
    { user.id, model_code }
  )
  if not row or not util.is_true(row.can_read) then
    respond.fail(403, "没有该模型的读取权限")
    return false
  end
  if write and not util.is_true(row.can_write) then
    respond.fail(403, "没有该模型的写入权限")
    return false
  end
  return true
end

--- 取当前工作台产品。
function M.require_product()
  local pid = util.header_product_id()
  if not pid or pid <= 0 then
    respond.fail(400, "请选择产品")
    return nil
  end
  local product = db.one("SELECT * FROM products WHERE id = ?", { pid })
  if not product then
    respond.fail(404, "产品不存在")
    return nil
  end
  return product
end

return M
