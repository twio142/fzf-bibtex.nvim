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
local files_initialized = false
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
}

local function table_contains(table, element)
  for _, value in pairs(table) do
    if value == element then
      return true
    end
  end
  return false
end

local function getContextBibFiles()
  local found_files = {}
  context_files = {}
  if utils.isPandocFile() then
    found_files = utils.parsePandoc()
  elseif utils.isLatexFile() then
    found_files = utils.parseLatex()
  end
  for _, file in pairs(found_files) do
    if not utils.file_present(context_files, file) then
      table.insert(context_files, { name = file, mtime = 0, entries = {} })
    end
  end
end

local function getBibFiles(dir)
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

local function initFiles()
  for _, file in pairs(user_files) do
    local p = path:new(file)
    if p:is_dir() then
      getBibFiles(file)
    elseif p:is_file() then
      if not utils.file_present(files, file) then
        table.insert(files, { name = file, mtime = 0, entries = {} })
      end
    end
  end
  getBibFiles('.')
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
      if table_contains(search_fields, [[citekey]]) then
        search_relevants[citekey]['citekey'] = citekey
      end
      for _, field in pairs(search_fields) do
        local key_pattern = utils.construct_case_insensitive_pattern(field)
        local match_base = '%f[%w]' .. key_pattern
        local s = nil
        local bracket_match = entry:match(match_base .. '%s*=%s*%b{}')
        local quote_match = entry:match(match_base .. '%s*=%s*%b""')
        local number_match = entry:match(match_base .. '%s*=%s*%d+')
        if bracket_match ~= nil then
          s = bracket_match:match('%b{}')
        elseif quote_match ~= nil then
          s = quote_match:match('%b""')
        elseif number_match ~= nil then
          s = number_match:match('%d+')
        end
        if s ~= nil then
          s = s:gsub('["{}\n]', ''):gsub('%s%s+', ' ')
          search_relevants[citekey][string.lower(field)] = vim.trim(s)
        end
      end
    end
    data = data:sub(#entry + 2)
  end
  return keys, contents, search_relevants
end

local function formatDisplay(entry)
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
    getContextBibFiles()
  end
  if not files_initialized then
    initFiles()
    files_initialized = true
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
          search_field = search_relevants[entry],
        }
        table.insert(file.entries, {
          key = entry,
          content = content[entry],
          search_field = search_relevants[entry],
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

local MyPreviewer = builtin.base:extend()

function MyPreviewer:new(o, opts, fzf_win)
  MyPreviewer.super.new(self, o, opts, fzf_win)
  setmetatable(self, MyPreviewer)
  return self
end

function MyPreviewer:populate_preview_buf(entry_str)
  local key = vim.split(entry_str, delimiter)[2]
  local entry = entries[key]
  local bufnr = self:get_tmp_buffer()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, entry.content)
  vim.api.nvim_set_option_value('filetype', 'bib', { buf = bufnr })
  self:set_preview_buf(bufnr)
  self.win:update_preview_scrollbar()
end

function MyPreviewer:gen_winopts()
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
    }
  end,

  insert_entry = function()
    return {
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
    }
  end,

  insert_citation = function(opts)
    return {
      fn = function(selected)
        local key = vim.split(selected[1], delimiter)[2]
        local text = entries[key].content
        local citation = utils.format_citation(text, opts.citation_format or citation_format, opts)
        local mode = vim.api.nvim_get_mode().mode
        if mode == 'i' then
          vim.api.nvim_put({ citation }, '', false, true)
          vim.api.nvim_feedkeys('a', 'n', true)
        else
          vim.api.nvim_paste(citation, true, -1)
        end
      end,
      desc = 'insert-citation',
    }
  end,

  manage_fields = function()
    return {
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
    }
  end,

  yank_key = function()
    return {
      fn = function(selected)
        local key = vim.split(selected[1], delimiter)[2]
        vim.fn.setreg('"', key)
        vim.notify('Yanked: ' .. key)
      end,
      desc = 'yank-key',
      exec_silent = true,
    }
  end,
}

local function search(opts)
  opts = opts or {}
  entries = get_entries(opts)
  local _actions = {}
  for key, action in pairs(keymap) do
    if type(action) == 'string' then
      _actions[key] = actions[action](opts)
    elseif type(action) == 'function' then
      _actions[key] = action(opts)
    else
      _actions[key] = action
    end
  end
  fzf.fzf_exec(function(fzf_cb)
    for key, entry in pairs(entries) do
      local display_string = formatDisplay(entry.search_field)
      if display_string == '' then
        display_string = key
      end
      display_string = display_string .. delimiter .. key
      fzf_cb(display_string)
    end
    fzf_cb()
  end, {
    winopts = {
      title = ' Search citations ',
      preview = { border = 'rounded', layout = 'vertical' },
    },
    fzf_opts = { ['--delimiter'] = delimiter, ['--with-nth'] = '1' },
    previewer = MyPreviewer,
    actions = _actions,
  })
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
    search_fields = opts.search_field or search_fields
    citation_format = opts.citation_format or citation_format
    citation_trim_firstname = opts.citation_trim_firstname
      or citation_trim_firstname
    citation_max_auth = opts.citation_max_auth or citation_max_auth
    keymap = vim.tbl_extend('force', keymap, opts.mappings or {})
  end,
  search = search,
  actions = actions,
}
