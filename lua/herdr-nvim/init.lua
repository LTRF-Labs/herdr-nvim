local M = {}

M.config = { set_default_keymaps = true, input = {} }

local function check_environment()
  assert(vim.env.HERDR_ENV == "1", "herdr-nvim requires Neovim to run inside Herdr")
  assert(vim.fn.executable("herdr") == 1, "herdr-nvim requires the herdr CLI in PATH")
end

-- Argument lists keep prompts and paths out of the shell. All CLI work is async.
local function cli(args, cb)
  local command = { "herdr" }
  vim.list_extend(command, args)
  local ok, err = pcall(vim.system, command, { text = true, timeout = 40000 }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        cb((result.stderr ~= "" and result.stderr) or "Herdr command failed")
        return
      end
      local decoded, response = pcall(vim.json.decode, result.stdout)
      if not decoded or type(response) ~= "table" or type(response.result) ~= "table" then
        cb("Invalid response from Herdr")
        return
      end
      cb(nil, response.result)
    end)
  end)
  if not ok then vim.schedule(function() cb(tostring(err)) end) end
end

local function workspace_agent(agents, pane)
  local fallback
  for _, agent in ipairs(agents) do
    if agent.workspace_id == pane.workspace_id and agent.pane_id and agent.pane_id ~= pane.pane_id then
      fallback = fallback or agent.pane_id
      if agent.agent_status == "idle" or agent.agent_status == "done" then return agent.pane_id end
    end
  end
  return fallback
end

-- Resolve the live caller, not the focused pane or an inherited workspace ID.
local function resolve_agent(cwd, cb)
  cli({ "pane", "current", "--current" }, function(err, result)
    if err then cb(err); return end
    local pane = result.pane
    if not pane or not pane.workspace_id or not pane.pane_id then cb("Herdr did not return the current pane"); return end
    cli({ "agent", "list" }, function(list_err, listed)
      if list_err then cb(list_err); return end
      if type(listed.agents) ~= "table" then cb("Herdr did not return an agent list"); return end
      local target = workspace_agent(listed.agents, pane)
      if target then cb(nil, target); return end
      -- Start a new agent without moving focus away from the editor.
      cli({ "tab", "create", "--workspace", pane.workspace_id, "--cwd", cwd, "--no-focus" }, function(create_err, created)
        if create_err then cb(create_err); return end
        local new_pane = created.root_pane and created.root_pane.pane_id
        if not new_pane then cb("Herdr did not return the new pane"); return end
        local name = "nvim-" .. new_pane:gsub("[^a-zA-Z0-9_-]", "-"):lower()
        cli({ "agent", "start", name, "--kind", "pi", "--pane", new_pane, "--timeout", "30000" }, function(start_err)
          -- Herdr waits for the agent to be ready before this callback runs.
          cb(start_err, not start_err and new_pane or nil)
        end)
      end)
    end)
  end)
end

local queue, sending = {}, false
local function drain()
  if sending or #queue == 0 then return end
  sending = true
  local item = table.remove(queue, 1)
  local function finish(err)
    vim.notify(err or "Sent to Herdr agent", err and vim.log.levels.ERROR or vim.log.levels.INFO)
    sending = false
    drain()
  end
  resolve_agent(item.cwd, function(err, target)
    if err then finish(err); return end
    cli({ "agent", "prompt", target, item.message }, finish)
  end)
end

function M.input(opts, cb)
  vim.ui.input(vim.tbl_deep_extend("force", opts, M.config.input or {}), cb)
end

function M.prompt(message)
  check_environment()
  if message == nil then
    M.input({ prompt = "Ask agent: " }, function(input)
      if input and input ~= "" then M.prompt(input) end
    end)
    return
  end
  assert(type(message) == "string", "Prompt must be a string")
  if message == "" then return end
  table.insert(queue, { message = message, cwd = vim.fn.getcwd() })
  drain()
end

function M.send_file()
  local file = vim.fn.expand("%:p")
  if file == "" then vim.notify("No file open", vim.log.levels.WARN); return end
  M.input({ prompt = "Ask agent about " .. vim.fn.expand("%:.") .. ": " }, function(input)
    if input == nil then return end
    M.prompt(input == "" and ("Look at this file: " .. file) or string.format("File: %s\n\n%s", file, input))
  end)
end

function M.send_selection(range)
  local ui = require("herdr-nvim.ui")
  local selection = ui.capture_selection(range)
  if not selection then vim.notify("Empty or invalid selection", vim.log.levels.WARN); return end
  ui.open({ selection = selection })
end

function M.send_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local file, ft = vim.fn.expand("%:p"), vim.bo.filetype
  M.input({ prompt = "Ask agent about buffer: " }, function(input)
    if input == nil then return end
    if not vim.api.nvim_buf_is_valid(buf) then
      vim.notify("Source buffer is no longer available", vim.log.levels.WARN)
      return
    end
    local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    local prefix = input == "" and ("Look at this file " .. file .. ":") or (input .. "\n\nFile: " .. file)
    M.prompt(string.format("%s\n\n```%s\n%s\n```", prefix, ft, content))
  end)
end

function M.setup(opts)
  check_environment()
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  local autoread = vim.api.nvim_get_option_info2("autoread", { scope = "global" })
  if not autoread.was_set then vim.o.autoread = true end
  if M._reload_timer and not M._reload_timer:is_closing() then
    M._reload_timer:stop()
    M._reload_timer:close()
  end
  M._reload_timer = vim.uv.new_timer()
  M._reload_timer:start(0, 1000, vim.schedule_wrap(function() pcall(vim.cmd, "silent! checktime") end))
  local group = vim.api.nvim_create_augroup("HerdrNvimReload", { clear = true })
  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
    group = group, callback = function() pcall(vim.cmd, "silent! checktime") end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if M._reload_timer and not M._reload_timer:is_closing() then
        M._reload_timer:stop()
        M._reload_timer:close()
      end
      M._reload_timer = nil
    end,
  })
  vim.api.nvim_create_user_command("Herdr", function(args)
    local ui = require("herdr-nvim.ui")
    local selection = args.range > 0 and ui.capture_selection({ first_line = args.line1, last_line = args.line2 }) or nil
    ui.open({ selection = selection })
  end, { range = true, desc = "Send editor context to a Herdr agent" })
  vim.api.nvim_create_user_command("HerdrSend", function() M.prompt() end, {})
  vim.api.nvim_create_user_command("HerdrSendFile", M.send_file, {})
  vim.api.nvim_create_user_command("HerdrSendBuffer", M.send_buffer, {})
  vim.api.nvim_create_user_command("HerdrSendSelection", function(args)
    M.send_selection(args.range > 0 and { first_line = args.line1, last_line = args.line2 } or nil)
  end, { range = true })
  if M.config.set_default_keymaps then
    vim.keymap.set("n", "<leader>p", "<Cmd>Herdr<CR>", { silent = true, desc = "Send to Herdr agent" })
    vim.keymap.set("x", "<leader>p", function()
      local ui = require("herdr-nvim.ui")
      ui.open({ selection = ui.capture_selection() })
    end, { silent = true, desc = "Send selection to Herdr agent" })
  end
end

return M
