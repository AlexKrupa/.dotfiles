-- kotlin-lsp attaches no sources to the dependencies of Android modules, to Gradle's own jars, or to
-- the Android SDK. For them, it locates a symbol in a class file, which shows only a decompiled
-- stub. This module moves such a location to the declaration in the sources: the sources jar of the
-- library, the Gradle source distribution, or the SDK sources. If the sources are missing, it
-- starts their download, and the location stays on the class file until a next jump.
local M = {}

local gradle_files = vim.fn.expand '~/.gradle/caches/modules-2/files-2.1'
local extract_root = vim.fn.stdpath 'cache' .. '/kotlin-lsp-sources'
local started_fetches = {}
local decompiled_by_uri = {}

---@return { code: string, language: string }? stub source of a class file from the server
local function find_client(root_dir)
  return vim.iter(vim.lsp.get_clients { name = 'kotlin_lsp' }):find(function(candidate)
    return candidate.root_dir == root_dir
  end)
end

function M.decompile(uri, root_dir)
  if decompiled_by_uri[uri] then
    return decompiled_by_uri[uri]
  end
  local client = find_client(root_dir)
  if not client then
    return nil
  end
  local response = client:request_sync('workspace/executeCommand', { command = 'decompile', arguments = { uri } }, 10000)
  decompiled_by_uri[uri] = response and response.result
  return decompiled_by_uri[uri]
end

---@return string? coordinate `group:artifact:version`
local function find_coordinate(jar_path)
  local group, artifact, version = jar_path:match '/modules%-2/files%-2%.1/([^/]+)/([^/]+)/([^/]+)/'
  if group then
    return ('%s:%s:%s'):format(group, artifact, version)
  end
  -- An AAR `<name>.aar` becomes `transforms/<hash>/transformed/<name>/jars/classes.jar`. The name
  -- has no group, and the AAR of a Kotlin Multiplatform library has no version in its name either.
  -- Of the AARs with that name, the one whose `classes.jar` has the same size is the source.
  local name = jar_path:match '/transformed/([^/]+)/jars/classes%.jar$'
  if not name then
    return nil
  end
  local aar_paths = vim.fn.glob(('%s/*/*/*/*/%s.aar'):format(gradle_files, name), false, true)
  local jar_size = assert(vim.uv.fs_stat(jar_path)).size
  local source_aar = vim.iter(aar_paths):find(function(aar_path)
    local listing = vim.system({ 'unzip', '-l', aar_path, 'classes.jar' }, { text = true }):wait().stdout
    return tonumber(listing:match '\n%s*(%d+)%s+%S+%s+%S+%s+classes%.jar') == jar_size
  end)
  if not source_aar then
    return nil
  end
  group, artifact, version = source_aar:sub(#gradle_files + 2):match '^([^/]+)/([^/]+)/([^/]+)/'
  return ('%s:%s:%s'):format(group, artifact, version)
end

---@return string? sources_jar_path
local function find_sources_jar(coordinate)
  local group, artifact, version = unpack(vim.split(coordinate, ':'))
  local pattern = ('%s/%s/%s/%s/*/%s-%s-sources.jar'):format(gradle_files, group, artifact, version, artifact, version)
  return vim.fn.glob(pattern, false, true)[1]
end

local function start_fetch(name, command)
  if started_fetches[name] then
    return
  end
  started_fetches[name] = true
  vim.notify(('kotlin_lsp: fetching the sources of %s'):format(name))
  vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      if result.code == 0 then
        vim.notify(('kotlin_lsp: sources of %s fetched, jump again'):format(name))
      else
        vim.notify(('kotlin_lsp: no sources for %s: %s'):format(name, result.stderr), vim.log.levels.WARN)
      end
    end)
  end)
end

local function fetch_sources(coordinate, root_dir)
  if vim.fn.executable 'ksrc' == 1 then
    start_fetch(coordinate, { 'ksrc', 'fetch', coordinate, '--project', root_dir })
  end
end

local function fetch_sdk_sources(sdk_root, platform)
  if vim.fn.executable 'android' == 1 then
    start_fetch('Android SDK ' .. platform, { 'android', '--sdk=' .. sdk_root, 'sdk', 'install', 'sources/' .. platform })
  end
end

local function extract_directory(archive)
  return extract_root .. '/' .. vim.fn.sha256(archive):sub(1, 16)
end

-- Gradle's own jars have no sources jar. Its source distribution has the source of all its
-- subprojects, with tests, so only the `src/main` directories are extracted.
---@return string? Gradle version of a jar of a Gradle distribution or of the generated Gradle API
local function find_gradle_version(jar_path)
  return jar_path:match '/wrapper/dists/[^/]+/[^/]+/gradle%-([^/]+)/lib/' or jar_path:match '/generated%-gradle%-jars/gradle%-api%-([^/]+)%.jar$'
end

local function gradle_sources_archive(version)
  return ('%s/gradle-%s-src.zip'):format(extract_root, version)
end

-- The archive appears last, so that a found archive always has its extracted directory.
local fetch_gradle_sources_script = [[
set -eu
url=$1 archive=$2 directory=$3
curl -fsSL -o "$archive.partial" "$url"
expected=$(curl -fsSL "$url.sha256")
actual=$(shasum -a 256 "$archive.partial" | cut -d ' ' -f 1)
if [ "$expected" != "$actual" ]; then
  rm -f "$archive.partial"
  echo "SHA-256 of $url is $actual, expected $expected" >&2
  exit 1
fi
rm -rf "$directory.partial"
unzip -q -o "$archive.partial" '*/src/main/*' -d "$directory.partial"
mv "$directory.partial" "$directory"
mv "$archive.partial" "$archive"
]]

local function fetch_gradle_sources(version)
  local archive = gradle_sources_archive(version)
  local url = ('https://services.gradle.org/distributions/gradle-%s-src.zip'):format(version)
  vim.fn.mkdir(extract_root, 'p')
  start_fetch('Gradle ' .. version, { 'sh', '-c', fetch_gradle_sources_script, 'sh', url, archive, extract_directory(archive) })
end

---@return string directory with the files of the sources jar
local function extract(sources_jar)
  local directory = extract_directory(sources_jar)
  if vim.uv.fs_stat(directory) then
    return directory
  end
  -- An unzip that stops halfway leaves no directory, so a later call extracts again.
  local partial = directory .. '.partial'
  vim.fn.delete(partial, 'rf')
  vim.fn.mkdir(extract_root, 'p')
  local result = vim.system({ 'unzip', '-q', '-o', sources_jar, '-d', partial }):wait()
  if result.code ~= 0 then
    error(('kotlin_lsp: cannot extract %s: %s'):format(sources_jar, result.stderr))
  end
  assert(vim.uv.fs_rename(partial, directory))
  return directory
end

---@return string? identifier at the position of a request
local function find_symbol(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local line = vim.api.nvim_buf_get_lines(bufnr, params.position.line, params.position.line + 1, false)[1] or ''
  local column = params.position.character + 1
  for start_column, identifier in line:gmatch '()([%w_]+)' do
    if column >= start_column and column < start_column + #identifier then
      return identifier
    end
  end
  return nil
end

-- Removes annotations, type arguments, package names, and spaces, so that a type in a stub
-- (`kotlin.collections.List<T>`) and in a source file (`List<T>`) give the same text.
local function simple_type(type_text)
  local text = type_text:gsub('@[%w_.]+%b()', ''):gsub('@[%w_.]+', ''):gsub('%b<>', '')
  return (text:gsub('%f[%w_]%l[%w_]*%.', ''):gsub('%s+', ''))
end

local function split_parameters(text)
  local parts = {}
  local depth = 0
  local start = 1
  -- The `>` of a function type arrow is not a closing bracket.
  text = text:gsub('%->', ' returns ')
  for index = 1, #text do
    local char = text:sub(index, index)
    if char:match '[(<%[]' then
      depth = depth + 1
    elseif char:match '[)>%]]' then
      depth = depth - 1
    elseif char == ',' and depth == 0 then
      table.insert(parts, text:sub(start, index - 1))
      start = index + 1
    end
  end
  table.insert(parts, text:sub(start))
  -- A Kotlin trailing comma leaves an empty last part.
  return vim.tbl_filter(function(part)
    return vim.trim(part) ~= ''
  end, parts)
end

local function parameter_type(parameter)
  parameter = parameter:gsub('@[%w_.]+%b()', ''):gsub('@[%w_.]+', ''):gsub('=.*$', '')
  local kotlin_type = parameter:match '^[^:]-:(.*)$'
  if kotlin_type then
    local vararg = parameter:find '%f[%w]vararg%f[%W]' and 'vararg ' or ''
    return vararg .. simple_type(kotlin_type)
  end
  local java_type = vim.trim(parameter):gsub('^final%s+', ''):match '^(.-)%s+[%w_]+$'
  return simple_type(java_type or parameter)
end

---@return string? receiver and parameter types of the first declaration of `symbol` in `text`
local function signature_key(text, symbol)
  local symbol_start, parenthesis = text:match('()%f[%w_]' .. symbol .. '%s*()%(')
  local parameters = symbol_start and text:match('^%b()', parenthesis)
  if not parameters then
    return nil
  end
  local receiver = ''
  local prefix = text:sub(1, symbol_start - 1)
  if prefix:match '%.%s*$' then
    prefix = prefix:gsub('%.%s*$', '')
    local depth = 0
    local index = #prefix
    while index > 0 do
      local char = prefix:sub(index, index)
      if char == '>' then
        depth = depth + 1
      elseif char == '<' then
        depth = depth - 1
      elseif char:match '%s' and depth == 0 then
        break
      end
      index = index - 1
    end
    receiver = simple_type(prefix:sub(index + 1))
  end
  local types = {}
  if vim.trim(parameters:sub(2, -2)) ~= '' then
    for _, parameter in ipairs(split_parameters(parameters:sub(2, -2))) do
      table.insert(types, parameter_type(parameter))
    end
  end
  return receiver .. '(' .. table.concat(types, ',') .. ')'
end

-- A declaration can span several lines, for example one parameter on each line.
local declaration_line_count = 40

-- `sources` is an archive (a sources jar or a source zip) or a directory (Android SDK sources).
---@return string directory with the source files
---@return fun(path: string): string uri of a source file in the directory
local function open_sources(sources)
  if vim.fn.isdirectory(sources) == 1 then
    return sources, vim.uri_from_fname
  end
  local directory = extract(sources)
  return directory, function(path)
    return ('jar://%s!/%s'):format(sources, path:sub(#directory + 2))
  end
end

---@return string[] paths of the source files of a package
local function find_package_files(directory, package_name)
  local escaped_package = package_name:gsub('%.', '\\.')
  local pattern = '^package ' .. escaped_package .. ';?\\s*$'
  local result = vim.system({ 'rg', '-l', '-g', '*.kt', '-g', '*.java', pattern, directory }, { text = true }):wait()
  return vim.split(vim.trim(result.stdout), '\n', { trimempty = true })
end

---@param paths string[] files or directories
---@param types_only boolean
---@return { path: string, line_index: integer, character: integer }[]
local function search_declarations(paths, symbol, types_only)
  local function search(pattern, globs)
    local command = { 'rg', '-n', '--column', '--no-heading', '--with-filename', '-e', pattern }
    for _, glob in ipairs(globs) do
      vim.list_extend(command, { '-g', glob })
    end
    return vim.trim(vim.system(vim.list_extend(command, paths), { text = true }):wait().stdout)
  end
  local type_declaration = '\\b(class|interface|object|enum|record|typealias)\\s+' .. symbol .. '\\b|@interface\\s+' .. symbol .. '\\b'
  local declaration = type_declaration .. '|\\b(fun|val|var)\\s+(<[^>]*>\\s*)?([\\w.<>?, ]+\\.)?' .. symbol .. '\\b'
  -- A Java member has a type before its name. A call in a method body can match too, so this
  -- search runs only when no other declaration matches.
  local java_member = '^\\s*[\\w@<>\\[\\],.? ]+\\s' .. symbol .. '\\s*[(=;]'
  local matches = search(types_only and type_declaration or declaration, { '*.kt', '*.java' })
  if matches == '' and not types_only then
    matches = search(java_member, { '*.java' })
  end
  local declarations = {}
  for match in vim.gsplit(matches, '\n', { trimempty = true }) do
    local path, line, column = match:match '^(.-):(%d+):(%d+):'
    table.insert(declarations, { path = path, line_index = tonumber(line) - 1, character = tonumber(column) - 1 })
  end
  return declarations
end

---@return { location: lsp.Location, path: string, line_index: integer }
local function to_declaration(uri_for, match)
  local position = { line = match.line_index, character = match.character }
  return {
    location = { uri = uri_for(match.path), range = { start = position, ['end'] = position } },
    path = match.path,
    line_index = match.line_index,
  }
end

---@return { location: lsp.Location, path: string, line_index: integer }[]
local function find_declarations(sources, package_name, class_name, symbol)
  local directory, uri_for = open_sources(sources)
  local files = find_package_files(directory, package_name)
  if #files == 0 then
    return {}
  end
  -- For a symbol with the name of the class file, the server located the class, not a function of
  -- the same name, for example the builder function `Json()` next to the class `Json`.
  local matches = symbol == class_name and search_declarations(files, symbol, true) or {}
  if #matches == 0 then
    matches = search_declarations(files, symbol, false)
  end
  local declarations = {}
  local preferred = {}
  for _, match in ipairs(matches) do
    -- The file named after the class holds its members: `Foo.java` for `Foo`, `Foo.kt` for the
    -- Kotlin file facade `FooKt`. A facade with `@file:JvmName` can be spread over several files.
    local file_name = vim.fn.fnamemodify(match.path, ':t:r')
    local named_after_class = file_name == class_name or file_name .. 'Kt' == class_name
    table.insert(named_after_class and preferred or declarations, to_declaration(uri_for, match))
  end
  return #preferred > 0 and preferred or declarations
end

-- The server does not know the source files that this module opens, so it locates nothing in
-- them. A name lookup replaces it: a type through the imports and the package of the file, any
-- other name through declarations in the file, the package, and then all sources of the library.
-- A name from another library goes to the server by its full name. The lookup lists all members of
-- the same name.
local name_lookup_limit = 30

---@return string? sources of a document that this module opened
local function find_document_sources(uri)
  local archive = uri:match '^jar://(.-)!/.+%.kt$' or uri:match '^jar://(.-)!/.+%.java$'
  if archive then
    return archive
  end
  return vim.uri_to_fname(uri):match '^(.*/sources/android%-[^/]+)/'
end

-- The server finds the class file of a full name, and that class file maps to sources like any
-- location from the server.
---@return lsp.Location[]?
local function find_in_other_libraries(full_names, params, root_dir)
  local client = find_client(root_dir)
  if not client then
    return nil
  end
  for _, full_name in ipairs(full_names) do
    local response = client:request_sync('workspace/symbol', { query = full_name }, 10000)
    local found = vim.iter(response and response.result or {}):find(function(item)
      return item.name == full_name
    end)
    if found then
      return M.to_sources({ found.location }, params, root_dir)
    end
  end
  return nil
end

---@return lsp.Location[]?
local function find_by_name(params, root_dir)
  local sources = find_document_sources(params.textDocument.uri)
  local symbol = find_symbol(params)
  if not (sources and symbol) then
    return nil
  end
  local directory, uri_for = open_sources(sources)
  local lines = vim.api.nvim_buf_get_lines(vim.uri_to_bufnr(params.textDocument.uri), 0, -1, false)
  -- Each scope is a list of files or directories. The first scope with a declaration wins.
  local scopes = {}
  -- Full names to ask the server for, when no scope has a declaration.
  local full_names = {}
  for _, line in ipairs(lines) do
    local imported = line:match('^import%s+static%s+([%w_.]+)%.' .. symbol .. '%f[^%w_]') or line:match('^import%s+([%w_.]+)%.' .. symbol .. '%f[^%w_]')
    if imported then
      local files = find_package_files(directory, imported)
      if #files == 0 then
        -- The import names a class: a nested class or a static member of `<package>.<class>`.
        local package_name, class_name = imported:match '^(.*)%.([%w_]+)$'
        files = vim.tbl_filter(function(path)
          return vim.fn.fnamemodify(path, ':t:r') == class_name
        end, package_name and find_package_files(directory, package_name) or {})
      end
      -- An import that is not in this library names a declaration in another library, so a
      -- declaration of the same name in this library is not the target.
      if #files == 0 then
        return find_in_other_libraries({ imported .. '.' .. symbol }, params, root_dir) or {}
      end
      table.insert(scopes, files)
    end
  end
  local document_path = params.textDocument.uri:match '^jar://' and directory .. '/' .. params.textDocument.uri:match '!/(.+)$'
    or vim.uri_to_fname(params.textDocument.uri)
  table.insert(scopes, { document_path })
  for _, line in ipairs(lines) do
    local package_name = line:match '^package%s+([%w_.]+)' or line:match '^import%s+([%w_.]+)%.%*'
    if package_name then
      table.insert(scopes, find_package_files(directory, package_name))
      table.insert(full_names, package_name .. '.' .. symbol)
    end
  end
  table.insert(scopes, { directory })
  -- A capitalized name is usually a type, but it can also be a function, for example a composable.
  local passes = symbol:match '^%u' and { true, false } or { false }
  for _, types_only in ipairs(passes) do
    for _, paths in ipairs(scopes) do
      local matches = #paths > 0 and search_declarations(paths, symbol, types_only) or {}
      if #matches > 0 then
        return vim
          .iter(matches)
          :take(name_lookup_limit)
          :map(function(match)
            return to_declaration(uri_for, match).location
          end)
          :totable()
      end
    end
  end
  return find_in_other_libraries(full_names, params, root_dir) or {}
end

-- The stub of the class file has the signature of the overload that the server located.
local function select_overloads(declarations, location, root_dir, symbol)
  local stub = M.decompile(location.uri or location.targetUri, root_dir)
  if not stub then
    return declarations
  end
  local stub_lines = vim.split(stub.code, '\n')
  local stub_line = (location.range or location.targetSelectionRange).start.line + 1
  local stub_text = table.concat(stub_lines, ' ', stub_line, math.min(#stub_lines, stub_line + declaration_line_count))
  local stub_key = signature_key(stub_text, symbol)
  local matching = vim.tbl_filter(function(declaration)
    local lines = vim.fn.readfile(declaration.path, '', declaration.line_index + declaration_line_count)
    local text = table.concat(lines, ' ', declaration.line_index + 1)
    return stub_key ~= nil and signature_key(text, symbol) == stub_key
  end, declarations)
  return #matching > 0 and matching or declarations
end

---@param result lsp.Location|lsp.Location[]|lsp.LocationLink[]|nil
---@return lsp.Location|lsp.Location[]|lsp.LocationLink[]|nil
function M.to_sources(result, params, root_dir)
  if result == nil or (vim.islist(result) and #result == 0) then
    return find_by_name(params, root_dir) or result
  end
  local locations = vim.islist(result) and result or { result }
  local mapped = {}
  local mapped_keys = {}
  local function add(location)
    local start = (location.range or location.targetSelectionRange).start
    local key = ('%s:%d:%d'):format(location.uri or location.targetUri, start.line, start.character)
    if not mapped_keys[key] then
      mapped_keys[key] = true
      table.insert(mapped, location)
    end
  end
  for _, location in ipairs(locations) do
    local uri = location.uri or location.targetUri
    local jar_path, entry_path = uri:match '^jar://(.-)!/(.+)%.class$'
    local declarations = {}
    if jar_path then
      local package_name = vim.fs.dirname(entry_path):gsub('/', '.')
      local class_name = vim.fs.basename(entry_path):gsub('%$.*', '')
      local sdk_root, platform = jar_path:match '^(.*)/platforms/(android%-[^/]+)/android%.jar$'
      local gradle_version = sdk_root == nil and find_gradle_version(jar_path) or nil
      local coordinate = sdk_root == nil and gradle_version == nil and find_coordinate(jar_path) or nil
      local sources
      if sdk_root then
        local directory = ('%s/sources/%s'):format(sdk_root, platform)
        sources = vim.fn.isdirectory(directory) == 1 and directory or nil
      elseif gradle_version then
        local archive = gradle_sources_archive(gradle_version)
        sources = vim.uv.fs_stat(archive) and archive or nil
      elseif coordinate then
        sources = find_sources_jar(coordinate)
      end
      local symbol = find_symbol(params)
      if sources and symbol then
        declarations = find_declarations(sources, package_name, class_name, symbol)
      elseif sources == nil and sdk_root then
        fetch_sdk_sources(sdk_root, platform)
      elseif sources == nil and gradle_version then
        fetch_gradle_sources(gradle_version)
      elseif sources == nil and coordinate then
        fetch_sources(coordinate, root_dir)
      end
      if #declarations > 1 then
        declarations = select_overloads(declarations, location, root_dir, symbol)
      end
    end
    if #declarations == 0 then
      add(location)
    end
    for _, declaration in ipairs(declarations) do
      add(declaration.location)
    end
  end
  return mapped
end

return M
