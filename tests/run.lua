vim.opt.runtimepath:prepend(vim.fn.getcwd())
local plugin = require("herdr-nvim")
local notices, calls, responses = {}, {}, {}
vim.notify = function(message, level) table.insert(notices, { message, level }) end
vim.system = function(args, _, cb)
  table.insert(calls, args)
  local response = table.remove(responses, 1)
  assert(response, "Unexpected CLI call: " .. vim.inspect(args))
  vim.schedule(function()
    cb({ code = response.code or 0, stdout = vim.json.encode({ result = response.result or {} }), stderr = response.stderr or "" })
  end)
end
local function run(reply, message)
  calls, notices, responses = {}, {}, reply
  plugin.prompt(message or "hello\n'$(echo unsafe)'")
  assert(vim.wait(2000, function() return #notices > 0 end, 5), "CLI chain did not finish")
  assert(#responses == 0, "Unused responses")
end
local function current(workspace)
  return { result = { pane = { workspace_id = workspace or "w1", pane_id = "w1:p1" } } }
end
local function agents(list) return { result = { agents = list } } end
local function agent(pane, workspace, status)
  return { pane_id = pane, workspace_id = workspace, agent_status = status }
end
vim.env.HERDR_ENV = "0"
assert(not pcall(plugin.setup), "Setup must fail outside Herdr")
assert(not pcall(plugin.prompt, "hello"), "Prompt must fail outside Herdr")
vim.env.HERDR_ENV = "1"
local executable = vim.fn.executable
vim.fn.executable = function(name) return name == "herdr" and 0 or executable(name) end
assert(not pcall(plugin.setup), "Setup must fail without the Herdr CLI")
vim.fn.executable = function(name) return name == "herdr" and 1 or executable(name) end
plugin.setup({ set_default_keymaps = false })
plugin.setup({ set_default_keymaps = false })
assert(vim.fn.exists(":Herdr") == 2)

run({ current(), agents({
  agent("w2:p1", "w2", "idle"), agent("w1:p1", "w1", "idle"),
  agent("w1:p2", "w1", "working"), agent("w1:p3", "w1", "blocked"),
  agent("w1:p4", "w1", "unknown"), agent("w1:p5", "w1", "done"), agent("w1:p6", "w1", "idle"),
}), { result = {} } })
assert(#calls == 3)
assert(calls[1][4] == "--current")
assert(calls[3][4] == "w1:p5", "Must use the first ready agent in the caller workspace")
assert(calls[3][5] == "hello\n'$(echo unsafe)'", "Prompt must remain a single argument")

-- Live pane context must override stale inherited context.
vim.env.HERDR_WORKSPACE_ID = "w99"
run({ current("w7"), agents({ agent("w99:p2", "w99", "idle"), agent("w7:p2", "w7", "idle") }), { result = {} } })
assert(calls[3][4] == "w7:p2")

run({ current(), agents({ agent("w1:p2", "w1", "working") }),
  { result = { root_pane = { pane_id = "w1:p8" } } }, { result = {} }, { result = {} } })
assert(#calls == 5)
assert(calls[3][3] == "create" and calls[3][5] == "w1")
assert(calls[3][7] == vim.fn.getcwd() and calls[3][8] == "--no-focus")
assert(calls[4][3] == "start" and calls[4][6] == "pi" and calls[4][8] == "w1:p8")
assert(calls[5][3] == "prompt" and calls[5][4] == "w1:p8")

run({ { code = 1, stderr = "server unavailable" } })
assert(#calls == 1 and notices[1][2] == vim.log.levels.ERROR)
run({ current(), agents({}), { result = {} } })
assert(#calls == 3 and notices[1][2] == vim.log.levels.ERROR)
run({ current(), agents({}), { result = { root_pane = { pane_id = "w1:p9" } } },
  { code = 1, stderr = "Pi startup failed" } })
assert(#calls == 4 and notices[1][2] == vim.log.levels.ERROR)

-- Concurrent submissions must not race through discovery and creation.
calls, notices, responses = {}, {}, {
  current(), agents({ agent("w1:p2", "w1", "idle") }), { result = {} },
  current(), agents({ agent("w1:p2", "w1", "idle") }), { result = {} },
}
plugin.prompt("one")
plugin.prompt("two")
assert(#calls == 1)
assert(vim.wait(2000, function() return #notices == 2 end, 5))
assert(calls[3][5] == "one" and calls[6][5] == "two")

local ui = require("herdr-nvim.ui")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "first", "second", "third" })
local selection = ui.capture_selection({ first_line = 1, last_line = 2 })
assert(selection.text == "first\nsecond" and selection.kind == "line")
local sent
plugin.prompt = function(message) sent = message end
vim.ui.input = function(_, cb) cb("explain") end
ui.open({ selection = selection })
assert(sent:find("explain", 1, true) and sent:find("first\nsecond", 1, true))
assert(sent:find(":L1-L2", 1, true))
sent = nil
vim.ui.input = function(_, cb) cb(nil) end
ui.open({ selection = selection })
assert(sent == nil, "Cancel must not submit")
print("All tests passed")
vim.cmd("qa!")
