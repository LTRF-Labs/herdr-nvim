local M = {}

local selection_ns = vim.api.nvim_create_namespace("HerdrNvimSelection")

local function visual_kind(mode)
  if mode == "v" then return "char" end
  if mode == "V" then return "line" end
  if mode == "\22" then return "block" end
end

--- Capture editor context before an input UI changes the mode and current window.
--- @param range { first_line: integer, last_line: integer }|nil Ex line range
--- @return table|nil
function M.capture_selection(range)
  local mode = vim.fn.mode()
  local kind = visual_kind(mode)
  local was_visual = kind ~= nil
  local selection_type
  local from
  local to

  if was_visual then
    selection_type = mode
    -- Leave Visual mode now to finalize the selection marks before input opens.
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "x", true)
    from = vim.fn.getpos("'<")
    to = vim.fn.getpos("'>")
  else
    from = vim.fn.getpos("'<")
    to = vim.fn.getpos("'>")
    selection_type = vim.fn.visualmode()
    kind = visual_kind(selection_type)
  end

  -- Explicit Ex ranges may have nothing to do with the previous visual marks.
  if range and (math.min(from[2], to[2]) ~= range.first_line or math.max(from[2], to[2]) ~= range.last_line) then
    from = { 0, range.first_line, 1, 0 }
    to = { 0, range.last_line, 1, 0 }
    selection_type, kind = "V", "line"
  end

  if not kind or from[2] == 0 or to[2] == 0 then return nil end

  local region_opts = { type = selection_type }
  local ok, lines = pcall(vim.fn.getregion, from, to, region_opts)
  local positions_ok, positions = pcall(vim.fn.getregionpos, from, to, { type = selection_type, eol = true })
  if not ok or not lines or #lines == 0 or not positions_ok or not positions or #positions == 0 then return nil end

  -- getregionpos reports the actual included endpoints, including 'selection'
  -- being exclusive and reversed/blockwise selections.
  local start_pos = positions[1][1]
  local end_pos = positions[#positions][2]
  local start_col, end_col = start_pos[3], end_pos[3]

  local text = table.concat(lines, "\n")
  if text == "" then return nil end

  return {
    text = text,
    file = vim.fn.expand("%:p"),
    start_line = start_pos[2],
    start_col = start_col,
    end_line = end_pos[2],
    end_col = end_col,
    kind = kind,
    was_visual = was_visual,
    ft = vim.bo.filetype,
  }
end

local function location(selection)
  local path = selection.file ~= "" and selection.file or "[No Name]"
  if selection.kind == "line" then
    return string.format("%s:L%d-L%d", path, selection.start_line, selection.end_line)
  end
  return string.format(
    "%s:L%d:C%d-L%d:C%d",
    path,
    selection.start_line,
    selection.start_col,
    selection.end_line,
    selection.end_col
  )
end

local function end_exclusive(line, one_based_col)
  local byte_col = one_based_col - 1
  if byte_col >= #line then return #line end
  local char_col = vim.fn.charidx(line, byte_col)
  local next_byte = vim.fn.byteidx(line, char_col + 1)
  return next_byte < 0 and #line or next_byte
end

local function highlight(buf, selection)
  if not selection or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, selection_ns, 0, -1)

  if selection.kind == "block" then
    for row = selection.start_line - 1, selection.end_line - 1 do
      local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
      local first = math.min(selection.start_col - 1, #line)
      local last = end_exclusive(line, selection.end_col)
      if last > first then
        vim.api.nvim_buf_set_extmark(buf, selection_ns, row, first, { end_col = last, hl_group = "Visual" })
      end
    end
    return
  end

  local end_row = selection.kind == "line" and selection.end_line or selection.end_line - 1
  local end_col = nil
  if selection.kind == "char" then
    local line = vim.api.nvim_buf_get_lines(buf, end_row, end_row + 1, false)[1] or ""
    end_col = end_exclusive(line, selection.end_col)
  end
  vim.api.nvim_buf_set_extmark(buf, selection_ns, selection.start_line - 1, selection.kind == "line" and 0 or selection.start_col - 1, {
    end_row = end_row,
    end_col = end_col,
    hl_group = "Visual",
  })
end

--- Build and send a prompt using vim.ui.input. This deliberately uses the
--- standard UI so providers such as snacks.input work exactly as configured.
--- @param opts { selection: table|nil }|nil
function M.open(opts)
  opts = opts or {}
  local herdr = require("herdr-nvim")
  local selection = opts.selection
  local source_win = vim.api.nvim_get_current_win()
  local source_buf = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(source_buf)

  highlight(source_buf, selection)

  local input_opts = {
    prompt = selection and ("Ask agent about " .. location(selection) .. ": ") or "Ask agent: ",
  }

  herdr.input(input_opts, function(input)
    if vim.api.nvim_buf_is_valid(source_buf) then
      vim.api.nvim_buf_clear_namespace(source_buf, selection_ns, 0, -1)
    end
    if input == nil then
      -- Restore the selection on cancellation; submission leaves Normal mode active.
      if selection and selection.was_visual and vim.api.nvim_win_is_valid(source_win) then
        vim.api.nvim_set_current_win(source_win)
        vim.cmd("normal! gv")
      end
      return
    end

    local message
    if selection then
      local context = location(selection)
      if input == "" then
        message = string.format("Look at %s:\n\n```%s\n%s\n```", context, selection.ft, selection.text)
      else
        message = string.format("%s\n\nFrom %s:\n```%s\n%s\n```", input, context, selection.ft, selection.text)
      end
    elseif file ~= "" then
      local absolute = vim.fn.fnamemodify(file, ":p")
      message = input == "" and ("Look at this file: " .. absolute) or string.format("File: %s\n\n%s", absolute, input)
    elseif input ~= "" then
      message = input
    else
      vim.notify("Nothing to send", vim.log.levels.WARN)
      return
    end

    herdr.prompt(message)
  end)
end

return M
