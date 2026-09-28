-- 通过环境变量 DB_CONFIG_ID 取 MySQL 连接。

local M = {}

--- 打开业务库。
function M.conn()
  local id = ctx.env.DB_CONFIG_ID
  if not id or id == "" then
    error("未配置环境变量 DB_CONFIG_ID")
  end
  local db, err = ctx.db.use(id)
  if err then
    error(err)
  end
  return db
end

--- 查询多行。
function M.query(sql, args)
  local rows, err = M.conn().query(sql, args or {})
  if err then
    error(err)
  end
  return rows or {}
end

--- 查询一行。
function M.one(sql, args)
  local row, err = M.conn().query_one(sql, args or {})
  if err then
    error(err)
  end
  return row
end

--- 执行写操作。
function M.exec(sql, args)
  local result, err = M.conn().execute(sql, args or {})
  if err then
    error(err)
  end
  return result
end

--- 事务。fn(tx) 里用 tx.query / tx.execute。
function M.tx(fn)
  local result, err = M.conn().transaction(fn)
  if err then
    error(err)
  end
  return result
end

return M
