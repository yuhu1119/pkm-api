--- @route GET /api/health
--- @require_sso_auth false
--- @require_access_auth false
--- @require_data_auth false
-- 健康检查，供探活与部署校验

ctx.res.json({
  ok = true,
  name = "产品知识模型",
  engine = "speedloop-lua",
})
