# fzf-bibtex.nvim

Search and insert entries from `*.bib` files with [fzf-lua](https://github.com/ibhagwan/fzf-lua).

The `*.bib` files should either be found in the current working directory, or defined as global files (see [Configuration](#configuration)).

## Dependency

[fzf-lua](https://github.com/ibhagwan/fzf-lua)

## Installation

Plug

```vim
Plug 'ibhagwan/fzf-lua'
Plug 'twio142/fzf-bibtex.nvim'
```

Packer

```lua
use {
    'twio142/fzf-bibtex.nvim',
    requires = { { 'ibhagwan/fzf-lua' } },
    opts = {},
}
```

## Usage

```vim
:lua require('fzf-bibtex').search()
```

### Keybindings (Actions)

The entry picker comes with four different actions.

| key     | Description                  | Result |
|---------|------------------------------|--------|
| `<cr>`  | Insert citekey               |@Newton1687|
| `<c-y>` | Yank citekey                 |        |
| `<c-f>` | Insert formatted citation    | Newton, I. (1687), _Philosophiae naturalis principa mathematica_.|
| `<c-e>` | Focus on the preview window,<br /> allow you to yank any text.  |  |
| `<c-o>` | Insert the whole entry       |@book{newton1687philosophiae,<br />&nbsp;&nbsp; title={Philosophiae naturalis principia mathematica},<br />&nbsp;&nbsp;  author={Newton, I.},<br />&nbsp;&nbsp;  year={1687},<br />&nbsp;&nbsp;  publisher={J. Societatis Regiae ac Typis J. Streater}<br />  }|

## Configuration

Default configuration:

```lua
require('fzf-bibtex').setup {
    -- Depth of file tree to search for *.bib files
    depth = 1,
    -- Custom format of citekey
    custom_formats = {},
    -- Format of citekey to use
    -- By default, it will try to find the right format based on the filetype
    -- Use 'plain' for no format
    format = '',
    -- Path to global *.bib files
    global_files = {},
    -- Entry fields to search for
    search_fields = { 'author', 'year', 'title' },
    -- Template for formatted citation
    citation_format = '{{author}} ({{year}}), {{title}}.',
    -- Trim first names (only leave initials) in formatted citation
    citation_trim_firstname = true,
    -- Max number of authors to keep in formatted citation
    -- Truncate the rest with "et al."
    citation_max_auth = 2,
    -- Context awareness, disabled by default
    context = false,
    -- Fallback to global / local *.bib files if no context available
    -- Only takes effect when context = true
    context_fallback = true,
    -- user defined mappings
    mappings = {
        ["default"] = 'insert_key',
        ["ctrl-c"]  = 'insert_citation',
        ["ctrl-e"]  = 'insert_entry',
        ["ctrl-f"]  = 'manage_fields',
        ["ctrl-y"]  = 'yank_key',
    },
}
```

### Context Aware Bibliography File

If `context` is set to `true`, the plugin will look in the current file for a bibliography context, based on the filetype:

| Filetype              | Context                                                                                      |
| --------------------- | -------------------------------------------------------------------------------------------- |
| `pandoc`, `md`, `rmd` | `bibliography: file_path_with_ext`                                                           |
| `tex`                 | `\bibliography{relative_file_path_no_ext}` or `\addbibresource{relative_file_path_with_ext}` |

_Note:_ Setting context awareness ignores any global or project-wide bibliography files.

If `context_fallback` is set to `true`, the plugin will fallback to the global / local *.bib files if no context is available in the current file.

To change this setting temporarily, specify it in the options:

```
:lua require('fzf-bibtex').bibtex({ context = true })
```

### Citekey formats

The following formats are predefined:

| ID                | Format         |
| ----------        | -------------- |
| `tex`            | `\cite{key}` |
| `markdown`, `md` | `@key`       |
| `plain`          | `key`        |

You can define custom formats under `custom_formats` and enable it by setting the `format` option to its `id`.

```lua
{
    -- Custom format for citation key
    custom_formats = { { id = 'myCoolFormat', cite_marker = '#%s#' } },
    format = 'myCoolFormat',
}
```

Set `cite_marker` to a lua pattern matching to apply the format.
In the example above, the inserted text would then be `#citekey#`.

If `format` is not defined, the plugin will try to find the right format based on the filetype.
If there is no format for the filetype it will fall back to `plain` format.

To quickly change the format, you can specify it via the options:

```
:lua require('fzf-bibtex').bibtex({format = 'markdown'})
```

### Search keys

You can search entries by certain fields, by setting the `search_fields` option.
The fields are searched in the order they are defined.

Example:

```lua
search_fields = { 'publisher', 'author', 'citekey' }
```

### Formatted citations

You can insert a formatted citation.

Note that citation style such as `Chicago`, `APA` are currently unsupported.
Instead, you need to provide a template by setting the `citation_format` option.

You can use any bibtex field in it.
Additionally, `{{citekey}}` and `{{type}}` ('Book', 'Journal Article', etc) are also supported.

Example:

```lua
citation_format = "[[^@{{citekey}}]]: {{author}} ({{year}}), {{title}}.",
```

You can trim the first names, leave only the initials by setting `citation_trim_firstname` to `true`.

You can truncate multiple authors with _et al._ by setting `citation_max_auth` to the desired number of authors to keep.

### Custom Mappings

To define a custom mapping you need to define one of the [actions](#keybindings-actions) provided by the plugin.
You can pass options to the action to further customize it.
One use case would be to bind a key for inserting the latex format `\cite{key}`:

```lua
local actions = require('fzf-bibtex').actions

mappings = {
    ["<C-a>"] = actions.insert_key({ -- format_string: a string with %s to be replaced by the citekey
        format_string = [[\citep{%s}]]
    }),
    ["<C-b>"] = actions.insert_citation({ -- citation_format: a string with keys in {{}} to be replaced
        citation_format = "[^@{{citekey}}]: {{author}}, {{title}}, {{journal}}, {{year}}, vol. {{volume}}, no. {{number}}, p. {{pages}}."
    }),
    ["<C-c>"] = actions.insert_entry(),
}
```
