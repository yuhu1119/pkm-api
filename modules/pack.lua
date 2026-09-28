-- 模型投喂知识包：已治理切片、system prompt、试问

local catalog = ctx.require("catalog")
local db = ctx.require("db")
local entities = ctx.require("entities")
local governance = ctx.require("governance")
local skills = ctx.require("skills")
local util = ctx.require("util")

local M = {}

local function resolve_scope(model_codes, type_ids)
  local codes = {}
  for _, item in ipairs(model_codes or {}) do
    local n = tonumber(item)
    if n and n >= 1 and n <= 10 then
      table.insert(codes, n)
    end
  end
  local ids = {}
  for _, item in ipairs(type_ids or {}) do
    local s = tostring(item)
    if catalog.TYPE_MAP[s] then
      table.insert(ids, s)
    end
  end
  if #ids > 0 then
    if #codes > 0 then
      local in_models = {}
      for _, t in ipairs(catalog.TYPES) do
        for _, c in ipairs(codes) do
          if t.model_code == c then
            in_models[t.entity_id] = true
          end
        end
      end
      local picked = {}
      for _, id in ipairs(ids) do
        if in_models[id] then
          table.insert(picked, id)
        end
      end
      local set = {}
      for _, id in ipairs(#picked > 0 and picked or ids) do
        set[id] = true
      end
      return set
    end
    local set = {}
    for _, id in ipairs(ids) do
      set[id] = true
    end
    return set
  end
  if #codes > 0 then
    local set = {}
    for _, t in ipairs(catalog.TYPES) do
      for _, c in ipairs(codes) do
        if t.model_code == c then
          set[t.entity_id] = true
        end
      end
    end
    return set
  end
  return nil
end

local function corpus_doc(item)
  local fields = skills.effective_fields(item.type_id)
  local parts = {}
  if item.summary and item.summary ~= "" then
    table.insert(parts, item.summary)
  end
  local payload = item.payload or {}
  for _, field in ipairs(fields) do
    local v = payload[field.key]
    if v and tostring(v) ~= "" then
      table.insert(parts, field.label .. "：" .. tostring(v))
    end
  end
  local meta = catalog.TYPE_MAP[item.type_id] or {}
  return {
    id = item.id,
    type_id = item.type_id,
    type_name = item.type_name,
    model_name = item.model_name,
    title = item.name,
    question = meta.core_question or item.name,
    answer = table.concat(parts, "\n"),
  }
end

--- 组装知识包。
function M.build(product, opts)
  opts = opts or {}
  local allowed = resolve_scope(opts.model_codes, opts.type_ids)
  local rows = db.query(
    "SELECT * FROM knowledge_entities WHERE product_id = ? ORDER BY type_id, id",
    { product.id }
  )
  local ids = {}
  for _, row in ipairs(rows) do
    table.insert(ids, row.id)
  end
  local flags = governance.source_flags(ids)
  local serialized = {}
  for _, row in ipairs(rows) do
    table.insert(serialized, entities.serialize(row, false, flags[row.id]))
  end
  local by_type = {}
  for _, item in ipairs(serialized) do
    by_type[item.type_id] = by_type[item.type_id] or {}
    table.insert(by_type[item.type_id], item)
  end
  local type_rows = {}
  local missing = {}
  local ready_count = 0
  local corpus_docs = {}
  local triples = {}
  for _, t in ipairs(catalog.TYPES) do
    local instances = by_type[t.entity_id] or {}
    local inspection = governance.inspect_type(product.id, t.entity_id)
    local in_scope = allowed == nil or allowed[t.entity_id]
    if inspection.stage == "governed" then
      ready_count = ready_count + 1
    elseif in_scope then
      table.insert(missing, t.entity_id)
    end
    table.insert(type_rows, {
      type_id = t.entity_id,
      name = t.name,
      model_code = t.model_code,
      model_name = t.model_name,
      core_question = t.core_question,
      ai_value = t.ai_value,
      stage = inspection.stage,
      instances = util.arr(instances),
    })
    if inspection.stage == "governed" and in_scope then
      for _, inst in ipairs(instances) do
        if inst.stage == "governed" then
          table.insert(corpus_docs, corpus_doc(inst))
          for _, ref in ipairs(inst.refs or {}) do
            if ref.to_id then
              table.insert(triples, {
                source = inst.name,
                source_type = inst.type_id,
                relation = ref.relation or "引用",
                target = ref.to_name or "",
                target_type = ref.to_type_id or "",
              })
            end
          end
        end
      end
    end
  end
  local models = {}
  for _, model in ipairs(catalog.MODELS) do
    local types = {}
    for _, tr in ipairs(type_rows) do
      if tr.model_code == model.code then
        table.insert(types, tr)
      end
    end
    table.insert(models, { code = model.code, name = model.name, types = util.arr(types) })
  end
  local scoped_ready = 0
  for _, t in ipairs(catalog.TYPES) do
    if allowed == nil or allowed[t.entity_id] then
      if governance.inspect_type(product.id, t.entity_id).stage == "governed" then
        scoped_ready = scoped_ready + 1
      end
    end
  end
  local product_card = {
    id = product.id,
    name = product.name,
    description = product.description,
    use = "给大模型建立对该产品的结构化认知：它是什么、服务谁、有哪些模块/页面/对象/流程/规则/权限，以及边界与决策。",
    governed_types = scoped_ready,
    governed_docs = #corpus_docs,
  }
  local system_prompt = M.system_prompt(product, product_card, corpus_docs, triples)
  local pack = {
    product = { id = product.id, name = product.name, description = product.description },
    generated_at = util.now(),
    purpose = "预览当前已治理知识给模型的输入。正式下载与对接请打成知识版本。",
    product_card = product_card,
    feed_filter = {
      model_codes = util.arr(opts.model_codes or {}),
      type_ids = util.arr(opts.type_ids or {}),
      top_k = opts.top_k or 5,
      include_triples = opts.include_triples ~= false,
    },
    summary = {
      type_total = #catalog.TYPES,
      type_ready = ready_count,
      type_ready_scoped = scoped_ready,
      type_missing = #missing,
      entity_total = #serialized,
      corpus_docs = #corpus_docs,
      triples = #triples,
      complete = ready_count == #catalog.TYPES,
      filtered = allowed ~= nil,
    },
    missing_type_ids = util.arr(missing),
    type_rows = util.arr(type_rows),
    qa_index = util.arr({}),
    corpus_docs = util.arr(corpus_docs),
    triples = util.arr(triples),
    models = util.arr(models),
    markdown = M.markdown(product, models, ready_count, missing),
    corpus_markdown = M.corpus_markdown(product, product_card, corpus_docs, triples),
    llm_input = {
      system_prompt = system_prompt,
      messages = util.arr({
        { role = "system", content = system_prompt },
      }),
    },
  }
  return pack
end

function M.system_prompt(product, card, docs, triples)
  local lines = {
    "你是「" .. product.name .. "」的产品知识助手，只依据下列已治理产品知识回答。",
    "不要编造未出现的模块、接口、规则或指标。不确定时明确说知识库未覆盖。",
    "",
    "产品简介：" .. (product.description or card.description or product.name),
    "知识覆盖：" .. tostring(card.governed_types) .. " 类对象、" .. tostring(card.governed_docs) .. " 篇已治理文档、" .. tostring(#(triples or {})) .. " 条关系。",
    "",
  }
  local primer = docs[1]
  for _, d in ipairs(docs or {}) do
    if d.type_id == "E01-001" then
      primer = d
      break
    end
  end
  if primer then
    table.insert(lines, "产品定位与核心事实：")
    table.insert(lines, primer.answer or primer.title or "")
    table.insert(lines, "")
  end
  table.insert(lines, "回答要求：优先引用对象编号（如 E01-001、E02-002）和实例名称；涉及权限、价格、资金时只陈述已治理规则。")
  return table.concat(lines, "\n")
end

function M.markdown(product, models, ready_count, missing)
  local lines = {
    "# " .. product.name .. " · 结构化知识总表",
    "",
    "> 生成用途：后续大模型识别与训练语料。当前完成 " .. tostring(ready_count) .. "/78 类对象。",
    "",
  }
  if missing and #missing > 0 then
    table.insert(lines, "## 覆盖缺口")
    table.insert(lines, "")
    for _, tid in ipairs(missing) do
      local meta = catalog.TYPE_MAP[tid]
      table.insert(lines, "- `" .. tid .. "` " .. (meta and meta.model_name or "") .. " / " .. (meta and meta.name or ""))
    end
    table.insert(lines, "")
  end
  return table.concat(lines, "\n")
end

function M.corpus_markdown(product, card, docs, triples)
  local lines = {
    "# " .. product.name .. " · 大模型产品知识语料",
    "",
    tostring(card.description or ""),
    "",
  }
  for _, doc in ipairs(docs or {}) do
    table.insert(lines, "### " .. doc.title)
    table.insert(lines, "**问：** " .. doc.question)
    table.insert(lines, "")
    table.insert(lines, "**答：** " .. doc.answer)
    table.insert(lines, "")
  end
  return table.concat(lines, "\n")
end

--- 编码下载内容。
function M.encode_file(product, pack, fmt)
  fmt = fmt or "json"
  local llm = pack.llm_input or {}
  if fmt == "system" then
    return llm.system_prompt or "", "text/plain; charset=utf-8", "system-prompt.txt"
  end
  if fmt == "corpus" then
    return pack.corpus_markdown or "", "text/markdown; charset=utf-8", "corpus.md"
  end
  if fmt == "rag" then
    local chunks = {}
    for _, doc in ipairs(pack.corpus_docs or {}) do
      table.insert(chunks, {
        id = tostring(product.id) .. "-" .. tostring(doc.id),
        text = doc.title .. "\n问：" .. doc.question .. "\n答：" .. doc.answer,
        metadata = { product = product.name, type_id = doc.type_id, entity_id = doc.id },
      })
    end
    return util.encode(chunks), "application/json", "rag.json"
  end
  if fmt == "sft" then
    local records = {}
    local sys = llm.system_prompt or ""
    for _, doc in ipairs(pack.corpus_docs or {}) do
      table.insert(records, {
        messages = {
          { role = "system", content = sys },
          { role = "user", content = doc.question },
          { role = "assistant", content = doc.answer },
        },
      })
    end
    return util.encode(records), "application/json", "sft.json"
  end
  if fmt == "pretrain" then
    local records = {}
    for _, doc in ipairs(pack.corpus_docs or {}) do
      table.insert(records, { text = "### " .. doc.title .. "\n问：" .. doc.question .. "\n答：" .. doc.answer .. "\n" })
    end
    return util.encode(records), "application/json", "pretrain.json"
  end
  return util.encode(pack), "application/json", "knowledge-pack.json"
end

local function score_doc(doc, q)
  local hay = string.lower((doc.title or "") .. " " .. (doc.question or "") .. " " .. (doc.answer or ""))
  local n = 0
  for word in string.gmatch(string.lower(q or ""), "%S+") do
    if #word > 1 and string.find(hay, word, 1, true) then
      n = n + 1
    end
  end
  return n
end

--- 试问：命中切片 + messages。
function M.trial(product, question, opts)
  local pack = M.build(product, opts)
  local ranked = {}
  for _, doc in ipairs(pack.corpus_docs or {}) do
    table.insert(ranked, { doc = doc, score = score_doc(doc, question) })
  end
  table.sort(ranked, function(a, b)
    return a.score > b.score
  end)
  local top_k = tonumber(opts and opts.top_k) or 5
  local hits = {}
  local ctx_lines = {}
  for i = 1, math.min(top_k, #ranked) do
    if ranked[i].score > 0 or i == 1 then
      table.insert(hits, ranked[i].doc)
      table.insert(ctx_lines, ranked[i].doc.title .. "\n" .. ranked[i].doc.answer)
    end
  end
  local sys = pack.llm_input.system_prompt
  local messages = {
    { role = "system", content = sys },
    { role = "user", content = "参考资料：\n" .. table.concat(ctx_lines, "\n\n") .. "\n\n问题：" .. (question or "") },
  }
  return {
    question = question,
    hits = util.arr(hits),
    messages = util.arr(messages),
    summary = pack.summary,
  }
end

return M
