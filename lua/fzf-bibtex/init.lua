local has_fzf, fzf = pcall(require, 'fzf-lua')
local utils = require('fzf-bibtex.utils')

if not has_fzf then
  error('This plugin requires fzf-lua')
end

local builtin = require('fzf-lua.previewer.builtin')
local scan = require('plenary.scandir')
local path = require('plenary.path')
local loop = vim.uv

local depth = 1
local formats = {}
formats['tex'] = '\\cite{%s}'
formats['md'] = '@%s'
formats['markdown'] = '@%s'
formats['typst'] = '@%s'
formats['rmd'] = '@%s'
formats['quarto'] = '@%s'
formats['pandoc'] = '@%s'
formats['plain'] = '%s'
local fallback_format = 'plain'
local use_auto_format = false
local user_format = ''
local user_files = {}
local files = {}
local entries = {}
local context_files = {}
local search_fields = { 'author', 'year', 'title' }
local citation_format = '{{author}} ({{year}}), {{title}}.'
local citation_trim_firstname = true
local citation_max_auth = 2
local user_context = false
local user_context_fallback = true
local delimiter = '\u{2002}'
local keymap = {
  default = 'insert_key',
  ['ctrl-e'] = 'insert_entry',
  ['ctrl-c'] = 'insert_citation',
  ['ctrl-f'] = 'manage_fields',
  ['ctrl-y'] = 'yank_key',
  ['ctrl-o'] = 'open_in_zotero',
}

local function table_contains(table, element)
  for _, value in pairs(table) do
    if value == element then
      return true
    end
  end
  return false
end

local function get_context_bib_files(bufnr)
  local is_explicit_call = bufnr ~= nil
  bufnr = bufnr or 0 -- Default to current buffer if not provided

  local found_files = {}
  if utils.is_pandoc_file(bufnr) then
    found_files = utils.parse_pandoc(bufnr)
  elseif utils.is_latex_file(bufnr) then
    found_files = utils.parse_latex(bufnr)
  end

  if is_explicit_call then
    -- If bufnr was provided, this is for the new exported function.
    -- Return a new table directly without touching the module-level variable.
    local files_for_buffer = {}
    for _, file in pairs(found_files) do
      if not utils.file_present(files_for_buffer, file) then
        table.insert(files_for_buffer, { name = file, mtime = 0, entries = {} })
      end
    end
    return files_for_buffer
  else
    -- This is the original behavior, called from get_entries().
    -- Clear and populate the module-level context_files.
    context_files = {}
    for _, file in pairs(found_files) do
      if not utils.file_present(context_files, file) then
        table.insert(context_files, { name = file, mtime = 0, entries = {} })
      end
    end
    -- No return value needed here as it modifies the upvalue.
  end
end

local function get_bib_files(dir)
  scan.scan_dir(dir, {
    depth = depth,
    search_pattern = '.*%.bib',
    on_insert = function(file)
      local p = path:new(file):absolute()
      if not utils.file_present(files, p) then
        table.insert(files, { name = p, mtime = 0, entries = {} })
      end
    end,
  })
end

local function init_files()
  for _, file in pairs(user_files) do
    local p = path:new(file)
    if p:is_dir() then
      get_bib_files(file)
    elseif p:is_file() then
      if not utils.file_present(files, file) then
        table.insert(files, { name = file, mtime = 0, entries = {} })
      end
    end
  end
  get_bib_files('.')
end

local function read_file(file)
  local keys = {}
  local contents = {}
  local search_relevants = {}
  local p = path:new(file)
  if not p:exists() then
    return {}, {}, {}
  end
  local data = p:read()
  data = data:gsub('\r', '')
  local entry = ''
  while true do
    entry = data:match('@%w*%s*%b{}')
    if entry == nil then
      break
    end
    local citekey = entry:match('{%s*[^{},~#%\\]+,\n')
    if citekey then
      citekey = vim.trim(citekey:gsub('\n', ''):sub(2, -2))
      local content = vim.split(entry, '\n')
      table.insert(keys, citekey)
      contents[citekey] = content
      search_relevants[citekey] = {}
      if table_contains(search_fields, 'citekey') then
        search_relevants[citekey]['citekey'] = citekey
      end
      for _, field in pairs(search_fields) do
        local value = utils.extract_field(entry, field)
        if value ~= nil then
          search_relevants[citekey][string.lower(field)] = value
        end
      end
    end
    data = data:sub(#entry + 2)
  end
  return keys, contents, search_relevants
end

local function format_display(entry)
  local display_string = ''
  for _, val in pairs(search_fields) do
    if tonumber(entry[val]) ~= nil then
      display_string = display_string .. ' ' .. '(' .. entry[val] .. ')'
    elseif entry[val] ~= nil then
      display_string = display_string .. ', ' .. entry[val]
    end
  end
  return vim.trim(display_string:sub(2))
end

local function parse_format_string(opts)
  local format_string = nil
  if opts.format_string ~= nil then
    format_string = opts.format_string
  elseif opts.format ~= nil then
    format_string = formats[opts.format]
  elseif use_auto_format then
    format_string = formats[vim.bo.filetype]
    if format_string == nil and vim.bo.filetype:match('markdown%.%a+') then
      format_string = formats['markdown']
    end
  end
  format_string = format_string or formats[user_format]
  return format_string
end

local function parse_context(opts)
  local context = nil
  if opts.context ~= nil then
    context = opts.context
  else
    context = user_context
  end
  return context
end

local function parse_context_fallback(opts)
  local context_fallback = nil
  if opts.context_fallback ~= nil then
    context_fallback = opts.context_fallback
  else
    context_fallback = user_context_fallback
  end
  return context_fallback
end

local function get_entries(opts)
  local context = parse_context(opts)
  local context_fallback = parse_context_fallback(opts)
  if context then
    get_context_bib_files()
  end
  entries = {}
  local current_files = files
  if context and (not context_fallback or next(context_files)) then
    current_files = context_files
  end
  for _, file in pairs(current_files) do
    local mtime = loop.fs_stat(file.name).mtime.sec
    if mtime ~= file.mtime then
      file.entries = {}
      local result, content, search_relevants = read_file(file.name)
      for _, entry in pairs(result) do
        entries[entry] = {
          key = entry,
          content = content[entry],
          search_fields = search_relevants[entry],
        }
        table.insert(file.entries, {
          key = entry,
          content = content[entry],
          search_fields = search_relevants[entry],
        })
      end
      file.mtime = mtime
    else
      for _, entry in pairs(file.entries) do
        entries[entry.key] = entry
      end
    end
  end
  return entries
end

local function get_bib_files_for_buffer(bufnr)
  bufnr = bufnr or 0
  local current_context_files = {}
  if user_context then
    current_context_files = get_context_bib_files(bufnr)
  end

  local bib_files = {}
  if
    user_context and (not user_context_fallback or next(current_context_files))
  then
    for _, file_data in pairs(current_context_files) do
      table.insert(bib_files, file_data.name)
    end
  else
    for _, file_data in pairs(files) do
      table.insert(bib_files, file_data.name)
    end
  end
  return bib_files
end

local previewer = builtin.base:extend()

function previewer:new(o, opts, fzf_win)
  previewer.super.new(self, o, opts, fzf_win)
  setmetatable(self, previewer)
  return self
end

function previewer:populate_preview_buf(entry_str)
  local key = vim.split(entry_str, delimiter)[2]
  local entry = entries[key]
  local bufnr = self:get_tmp_buffer()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, entry.content)
  vim.api.nvim_set_option_value('filetype', 'bib', { buf = bufnr })
  self:set_preview_buf(bufnr)
  self.win:update_preview_scrollbar()
end

function previewer:gen_winopts()
  local new_winopts = {
    wrap = true,
    number = false,
  }
  return vim.tbl_extend('force', self.winopts, new_winopts)
end

local actions = {
  insert_key = function(opts)
    local format_string = parse_format_string(opts)
    return {
      fn = function(selected)
        local mode = vim.api.nvim_get_mode().mode
        local key = vim.split(selected[1], delimiter)[2]
        local text = string.format(format_string, key)
        if mode == 'i' then
          vim.api.nvim_put({ text }, '', false, true)
          vim.api.nvim_feedkeys('a', 'n', true)
        else
          vim.api.nvim_put({ text }, '', true, true)
        end
      end,
      desc = 'insert-key',
      header = 'Insert key',
    }
  end,

  insert_citation = function(opts)
    return {
      fn = function(selected)
        local key = vim.split(selected[1], delimiter)[2]
        local text = entries[key].content
        local citation = utils.format_citation(
          text,
          opts.citation_format or citation_format,
          opts
        )
        local mode = vim.api.nvim_get_mode().mode
        if mode == 'i' then
          vim.api.nvim_put({ citation }, '', false, true)
          vim.api.nvim_feedkeys('a', 'n', true)
        else
          vim.api.nvim_paste(citation, true, -1)
        end
      end,
      desc = 'insert-citation',
      header = 'Insert citation',
    }
  end,

  insert_entry = {
    fn = function(selected)
      local key = vim.split(selected[1], delimiter)[2]
      local text = entries[key].content
      local mode = vim.api.nvim_get_mode().mode
      if mode == 'i' then
        vim.api.nvim_put(text, '', false, true)
        vim.api.nvim_feedkeys('a', 'n', true)
      else
        vim.api.nvim_put(text, '', true, true)
      end
    end,
    desc = 'insert-entry',
    header = 'Insert entry',
  },

  manage_fields = {
    fn = function()
      local winid = vim.api.nvim_get_current_win()
      vim.api.nvim_feedkeys('<c-\\><c-n>', 'n', true)
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == 'bib' then
          vim.api.nvim_set_current_win(win)
          vim.keymap.set('n', 'q', '<c-w>' .. winid .. 'w', { buffer = buf })
          break
        end
      end
    end,
    desc = 'manage-fields',
    exec_silent = true,
  },

  yank_key = {
    fn = function(selected)
      local key = vim.split(selected[1], delimiter)[2]
      vim.fn.setreg('"', key)
      vim.notify('Yanked: ' .. key)
    end,
    desc = 'yank-key',
    exec_silent = true,
  },

  open_in_zotero = {
    fn = function(selected)
      local key = vim.split(selected[1], '\u{2002}')[2]
      vim.ui.open('zotero://select/items/@' .. key)
    end,
    desc = 'open-in-zotero',
    header = 'Open in Zotero',
    exec_silent = true,
  },
}

local function search(opts)
  opts = opts or {}
  entries = get_entries(opts)
  local _actions = {}
  for key, action in pairs(keymap) do
    if type(action) == 'string' then
      if type(actions[action]) == 'function' then
        _actions[key] = actions[action](opts)
      else
        _actions[key] = actions[action]
      end
    elseif type(action) == 'function' then
      _actions[key] = action(opts)
    else
      _actions[key] = action
    end
  end
  fzf.fzf_exec(function(fzf_cb)
    for key, entry in pairs(entries) do
      local display_string = format_display(entry.search_fields)
      if display_string == '' then
        display_string = key
      end
      display_string = display_string .. delimiter .. key
      fzf_cb(display_string)
    end
    fzf_cb()
  end, {
    query = opts.query or '',
    winopts = {
      title = ' Citations ',
      preview = { border = 'rounded', layout = 'vertical' },
    },
    fzf_opts = { ['--delimiter'] = delimiter, ['--with-nth'] = '1' },
    previewer = previewer,
    actions = _actions,
  })
end

local function find_entry(key, field)
  if #entries == 0 then
    entries = get_entries({})
  end
  local entry = entries[key]
  if not entry then
    return nil
  end
  if field then
    return entry.search_fields[field]
      or utils.extract_field(table.concat(entry.content, '\n'), field)
  else
    return entry
  end
end

local tooltip_buf

local function show_entry_under_cursor()
  if tooltip_buf and vim.api.nvim_buf_is_valid(tooltip_buf) then
    local wins = vim.fn.win_findbuf(tooltip_buf)
    if #wins > 0 then
      vim.api.nvim_set_current_win(wins[1])
      return
    end
  end

  local citekey = utils.get_citekey_under_cursor()
  if not citekey then
    vim.notify('No citekey found')
    return
  end
  citekey = citekey:gsub('^@', '')
  local title = find_entry(citekey, 'title')
  if not title then
    vim.notify('No entry found for @' .. citekey, vim.log.levels.WARN)
    return
  end
  local lines = { title }
  local author = find_entry(citekey, 'author')
  if author then
    author = utils.abbrev_authors({ author = author }, {
      citation_trim_firstname = citation_trim_firstname,
      citation_max_auth = citation_max_auth,
    })
    table.insert(lines, author)
  end
  local year = find_entry(citekey, 'year') or find_entry(citekey, 'date') or ''
  year = year:match('%d%d%d%d')
  if year then
    lines[2] = lines[2] .. ' (' .. year .. ')'
  end
  tooltip_buf = utils.show_tooltip(lines)
  if tooltip_buf then
    vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
      buffer = tooltip_buf,
      once = true,
      callback = function()
        tooltip_buf = nil
      end,
    })
  end
end

return {
  setup = function(opts)
    depth = opts.depth or depth
    local custom_formats = opts.custom_formats or {}
    for _, format in pairs(custom_formats) do
      formats[format.id] = format.cite_marker
    end
    if opts.format ~= nil and formats[opts.format] ~= nil then
      user_format = opts.format
    else
      user_format = fallback_format
      use_auto_format = true
    end
    user_context = opts.context or user_context
    user_context_fallback = opts.context_fallback or user_context_fallback
    if opts.global_files ~= nil then
      for _, file in pairs(opts.global_files) do
        table.insert(user_files, vim.fn.expand(file))
      end
    end
    search_fields = opts.search_fields or search_fields
    citation_format = opts.citation_format or citation_format
    citation_trim_firstname = opts.citation_trim_firstname
      or citation_trim_firstname
    citation_max_auth = opts.citation_max_auth or citation_max_auth
    keymap = vim.tbl_extend('force', keymap, opts.mappings or {})
    init_files()
  end,
  search = search,
  actions = actions,
  find_entry = find_entry,
  show_entry_under_cursor = show_entry_under_cursor,
  get_bib_files_for_buffer = get_bib_files_for_buffer,
}
