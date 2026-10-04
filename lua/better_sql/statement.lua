local M = {}

local function line_starts(lines)
  local starts = {}
  local offset = 1
  for row, line in ipairs(lines) do
    starts[row] = offset
    offset = offset + #line + 1
  end
  return starts
end

local function offset_at(lines, starts, row, col)
  local line = lines[row + 1]
  if not line or col < 0 or col > #line then
    return nil
  end
  return starts[row + 1] + col
end

local function position_at(starts, offset)
  for row = #starts, 1, -1 do
    if offset >= starts[row] then
      return row - 1, offset - starts[row]
    end
  end
end

local function dollar_delimiter(source, index)
  return source:match("^%$[%a_][%w_]*%$", index) or source:match("^%$%$", index)
end

-- Scan once from left to right. state_at is the state before the byte at
-- target_offset; this makes a cursor at the end of a line useful to completion.
local function scan(source, target_offset)
  local spans = {}
  local tokens = {}
  local quoted_start
  local name_end = 0
  local state = "normal"
  local state_at
  local block_depth = 0
  local dollar_tag
  local escape_string = false
  local statement_start = 1
  local index = 1

  while index <= #source do
    if index == target_offset then
      state_at = state
    end

    local char = source:sub(index, index)
    local next_char = source:sub(index + 1, index + 1)
    local step = 1
    local state_before = state

    if state == "normal" then
      if char == "'" then
        local prefix = source:sub(index - 1, index - 1)
        local before_prefix = source:sub(index - 2, index - 2)
        escape_string = prefix:match("[Ee]") ~= nil and before_prefix:match("[%w_$]") == nil
        state = "single_quote"
      elseif char == '"' then
        state = "double_quote"
        quoted_start = index
      elseif char == "$" then
        local delimiter = dollar_delimiter(source, index)
        if delimiter then
          state = "dollar_quote"
          dollar_tag = delimiter
          step = #delimiter
        end
      elseif char == "-" and next_char == "-" then
        state = "line_comment"
        step = 2
      elseif char == "/" and next_char == "*" then
        state = "block_comment"
        block_depth = 1
        step = 2
      elseif char == ";" then
        spans[#spans + 1] = { first = statement_start, last = index }
        statement_start = index + 1
      elseif index > name_end and char:match("[%a_]") then
        local word = source:match("^[%a_][%w_$]*", index)
        name_end = index + #word - 1
        tokens[#tokens + 1] = { value = word:lower(), kind = "name", first = index, last = name_end }
      elseif char == "." or char == "," or char == "(" or char == ")" then
        tokens[#tokens + 1] = { value = char, kind = "punctuation", first = index, last = index }
      end
    elseif state == "single_quote" then
      if escape_string and char == "\\" and next_char ~= "" then
        step = 2
      elseif char == "'" then
        if next_char == "'" then
          step = 2
        else
          state = "normal"
          escape_string = false
        end
      end
    elseif state == "double_quote" then
      if char == '"' then
        if next_char == '"' then
          step = 2
        else
          tokens[#tokens + 1] = {
            value = source:sub(quoted_start + 1, index - 1):gsub('""', '"'),
            kind = "name", first = quoted_start, last = index, quoted = true,
          }
          quoted_start = nil
          state = "normal"
        end
      end
    elseif state == "dollar_quote" then
      if source:sub(index, index + #dollar_tag - 1) == dollar_tag then
        step = #dollar_tag
        state = "normal"
        dollar_tag = nil
      end
    elseif state == "line_comment" then
      if char == "\n" then
        state = "normal"
      end
    elseif state == "block_comment" then
      if char == "/" and next_char == "*" then
        block_depth = block_depth + 1
        step = 2
      elseif char == "*" and next_char == "/" then
        block_depth = block_depth - 1
        step = 2
        if block_depth == 0 then
          state = "normal"
        end
      end
    end

    if target_offset and target_offset > index and target_offset < index + step then
      state_at = state_before == "normal" and state or state_before
    end
    index = index + step
  end

  if target_offset == #source + 1 then
    state_at = state
  end
  if statement_start <= #source then
    spans[#spans + 1] = { first = statement_start, last = #source }
  end
  return spans, state_at, tokens
end

-- Select the same semicolon-delimited span as at_cursor, then trim only
-- whitespace. Comments remain part of the SQL sent to PostgreSQL.
local function selected_statement(source, starts, spans, cursor)
  for _, span in ipairs(spans) do
    if cursor >= span.first and (cursor <= span.last or (cursor == #source + 1 and span.last == #source)) then
      local first, last = span.first, span.last
      while first <= last and source:sub(first, first):match("%s") do
        first = first + 1
      end
      while last >= first and source:sub(last, last):match("%s") do
        last = last - 1
      end
      if first <= last then
        local start_row, start_col = position_at(starts, first)
        local end_row, end_col = position_at(starts, last + 1)
        return {
          sql = source:sub(first, last),
          start_row = start_row,
          start_col = start_col,
          end_row = end_row,
          end_col = end_col,
        }, first, last
      end
      return nil
    end
  end
end

local function relative_token(token, first, last, value)
  return {
    value = value or token.value,
    kind = token.kind,
    first = token.first - first + 1,
    last = last - first + 1,
    quoted = token.quoted,
  }
end

-- row and col are zero-based byte positions in lines. Token first/last are
-- one-based, inclusive byte offsets in the selected statement. cursor counts
-- bytes before the cursor relative to its trimmed start. Prefix tokens are
-- independent records, so completion can annotate each list with query scopes.
function M.context(lines, row, col)
  local starts = line_starts(lines)
  local cursor = offset_at(lines, starts, row, col)
  if not cursor then return nil end
  local source = table.concat(lines, "\n")
  local spans, state, scanned = scan(source, cursor)
  local selected, first, last = selected_statement(source, starts, spans, cursor)
  local context = { state = state, statement = selected, tokens = {}, prefix_tokens = {} }
  if not selected then return context end
  context.cursor = cursor - first
  for _, token in ipairs(scanned) do
    if token.first >= first and token.last <= last then
      context.tokens[#context.tokens + 1] = relative_token(token, first, token.last)
      if token.last < cursor then
        context.prefix_tokens[#context.prefix_tokens + 1] = relative_token(token, first, token.last)
      elseif token.first < cursor and token.kind == "name" and not token.quoted then
        context.prefix_tokens[#context.prefix_tokens + 1] = relative_token(
          token, first, cursor - 1, source:sub(token.first, cursor - 1):lower())
      end
    end
  end
  return context
end

-- The selected statement's end position is exclusive.
function M.at_cursor(lines, row, col)
  local context = M.context(lines, row, col)
  return context and context.statement or nil
end

-- State immediately before the cursor byte, including end-of-line positions.
function M.state_at(lines, row, col)
  local context = M.context(lines, row, col)
  return context and context.state or nil
end

return M
