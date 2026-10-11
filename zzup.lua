-- zzup
-- shows which norns community
-- scripts are new to you, and
-- which installed scripts
-- have updates.
--
-- E1 sort (far left: key)
-- E2/E3 scroll
-- K2 hide installed
-- K3 details
--
-- v2.5 @billwolf

--------------------------------------------------------------------------
-- overview
--
-- zzup lists every script in the norns community catalog and marks:
--
--   +   scripts that are new to you (added since your last visit)
--   *   installed and up to date
--   !   installed, and a newer version has been published
--   m   installed, and modified locally (edits or your own commits)
--   ?   installed, but can't be checked (not a git install, or the
--       repo can't be reached)
--   ~   local only: in dust/code but not from the catalog
--
-- where the information comes from:
--
--   catalog      monome's community.json: names, authors, descriptions
--   dates.json   a daily-updated file (billwolfhub/zzup-data) with the
--                date each script was added to the catalog and the
--                latest commit on its repo. optional: without it, zzup
--                falls back to dates it records itself.
--   your norns   installed scripts are checked with git, locally, in the
--                background. nothing about them is ever uploaded.
--
-- see DESIGN.md in the zzup repo for the full design.
--------------------------------------------------------------------------

local CATALOG_URL = "https://raw.githubusercontent.com/monome/norns-community/main/community.json"
local DEFAULT_DATES_URL = "https://raw.githubusercontent.com/billwolfhub/zzup-data/main/dates.json"

-- files this script keeps in dust/data/zzup/
local DATA_DIR      = _path.data .. "zzup/"
local STATE_FILE    = DATA_DIR .. "state.tsv"       -- your record and settings (plain text)
local CATALOG_CACHE = DATA_DIR .. "catalog.json"    -- last good catalog download
local DATES_CACHE   = DATA_DIR .. "dates.json"      -- last good dates.json download
local CHECK_SCRIPT  = DATA_DIR .. "check.sh"        -- the git checks, written fresh each run
local OLD_SEEN_FILE = DATA_DIR .. "seen.tsv"        -- zzup v1's record, imported once

-- maiden saves its own copies of the catalogs here; used as a fallback
-- when we're offline and have never downloaded a catalog ourselves
local MAIDEN_CATS   = _path.data .. "catalogs/"

local NEW_FIRST_RUN_DAYS = 30   -- first run: "new" = added in the last 30 days
local NEW_EXPIRY_DAYS    = 14   -- a "new" mark clears itself after two weeks
local DATES_MAX_AGE      = 6 * 3600  -- re-download dates.json at most every 6 hours
local BULK_IMPORT_DATE   = "2019-10-21"  -- the catalog's 2019 bulk import:
                                         -- "added" really means 2019 or earlier

-- screen layout: norns is 128x64. a header line on top, then ROWS
-- rows of text spaced ROW_H pixels apart.
local ROWS = 5
local ROW_H = 10
local W = 128
-- x positions of the columns in each row
local X_NEW, X_MARK, X_DATE, X_NAME = 0, 5, 17, 53

-- the sort orders E1 steps through
local SORTS = { "status", "added", "a-z", "updated", "author" }
-- how each sort order is named in the header ("sort: status, date")
local SORT_LABELS = {
  ["status"] = "status, date",
  ["added"] = "added",
  ["a-z"] = "a-z",
  ["updated"] = "update date",
  ["author"] = "author",
}

--------------------------------------------------------------------------
-- state
--------------------------------------------------------------------------

-- your record, saved in state.tsv
local seen = nil        -- project name -> date first seen ("YYYY-MM-DD").
                        -- nil until the first catalog has been recorded.
local newmark = {}      -- project name -> date it was marked new to you;
                        -- absent once cleared
local settings = {      -- remembered between runs
  sort = "status",
  hide_installed = false,
  dates_on = true,
  dates_url = DEFAULT_DATES_URL,
  dates_fetched = 0,    -- os.time() of the last good dates.json download
}

-- data loaded this run
local entries = {}      -- catalog entries (decoded tables), plus local-only rows
local catalog = {}      -- the catalog entries alone
local dates = nil       -- dates.json "scripts" table, or nil if unavailable
local folders = {}      -- folder name -> true, for every folder in dust/code
local checks = {}       -- folder name -> result of the git check (see run_checks)

-- what's on screen
local list = {}         -- the rows shown, in order
local view = "list"     -- "list" | "detail" | "key". no opening screen of
                        -- our own: the comment block at the top of this
                        -- file is what norns shows before launching.
local cursor, top = 1, 1                -- selected row, and first visible row
local detail_lines, detail_top = {}, 1  -- wrapped text for the detail screen
local busy = ""         -- what's running in the background, shown in the header
local offline = false   -- the last catalog download failed
local counts = { new = 0, upd = 0 }     -- for the header

--------------------------------------------------------------------------
-- json decoding
--
-- norns doesn't ship a json library, so this is a small decoder that
-- handles everything the catalog and dates.json use: objects, arrays,
-- strings (with escapes, including \uXXXX), numbers, true/false/null.
-- returns the decoded value, or nil plus an error message.
--------------------------------------------------------------------------

local function json_decode(s)
  local pos = 1  -- current read position in the string

  -- the single-character escapes json allows after a backslash
  local escapes = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
    b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

  -- skip whitespace
  local function ws() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
  -- the character at the current position
  local function ch() return s:sub(pos, pos) end

  -- read a string; pos is on the opening quote
  local function str()
    pos = pos + 1
    local parts = {}
    while true do
      -- jump to the next quote or backslash, keeping the plain text before it
      local a = s:find('["\\]', pos)
      if not a then error("unterminated string") end
      parts[#parts + 1] = s:sub(pos, a - 1)
      if s:sub(a, a) == '"' then pos = a + 1; break end  -- end of string
      local c = s:sub(a + 1, a + 1)
      if c == "u" then
        -- \uXXXX: a unicode code point, converted to utf-8
        local cp = tonumber(s:sub(a + 2, a + 5), 16)
        if not cp then error("bad unicode escape") end
        pos = a + 6
        -- characters outside the basic plane arrive as two \u escapes
        -- (a "surrogate pair") that combine into one code point
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos, pos + 1) == "\\u" then
          local lo = tonumber(s:sub(pos + 2, pos + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            pos = pos + 6
          end
        end
        parts[#parts + 1] = utf8.char(cp)
      else
        parts[#parts + 1] = escapes[c] or c
        pos = a + 2
      end
    end
    return table.concat(parts)
  end

  local value  -- declared ahead so obj() and arr() can call it

  -- read an object { "key": value, ... }; pos is on the "{"
  local function obj()
    local t = {}
    pos = pos + 1; ws()
    if ch() == "}" then pos = pos + 1; return t end  -- empty object
    while true do
      ws()
      if ch() ~= '"' then error("expected key at " .. pos) end
      local k = str(); ws()
      if ch() ~= ":" then error("expected ':' at " .. pos) end
      pos = pos + 1
      t[k] = value(); ws()
      local d = ch(); pos = pos + 1
      if d == "}" then return t end
      if d ~= "," then error("expected ',' or '}' at " .. (pos - 1)) end
    end
  end

  -- read an array [ value, ... ]; pos is on the "["
  local function arr()
    local t, n = {}, 0
    pos = pos + 1; ws()
    if ch() == "]" then pos = pos + 1; return t end  -- empty array
    while true do
      n = n + 1
      t[n] = value(); ws()
      local d = ch(); pos = pos + 1
      if d == "]" then return t end
      if d ~= "," then error("expected ',' or ']' at " .. (pos - 1)) end
    end
  end

  -- read any value, deciding what it is from its first character
  function value()
    ws()
    local c = ch()
    if c == "{" then return obj()
    elseif c == "[" then return arr()
    elseif c == '"' then return str()
    elseif s:find("^true", pos) then pos = pos + 4; return true
    elseif s:find("^false", pos) then pos = pos + 5; return false
    elseif s:find("^null", pos) then pos = pos + 4; return nil
    else
      local a, b = s:find("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not a then error("unexpected '" .. c .. "' at " .. pos) end
      pos = b + 1
      return tonumber(s:sub(a, b))
    end
  end

  -- errors (bad or truncated json, e.g. an html error page from the
  -- network) are caught here and returned rather than crashing the script
  local ok, res = pcall(value)
  if ok then return res end
  return nil, res
end

--------------------------------------------------------------------------
-- small helpers
--------------------------------------------------------------------------

-- the whole contents of a file, or nil if it doesn't exist
local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- write a file safely: to a temporary file first, then rename it into
-- place, so a crash or power loss can't leave a half-written file
local function write_file(path, text)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then print("zzup: can't write " .. tmp); return false end
  f:write(text)
  f:close()
  os.rename(tmp, path)
  return true
end

-- turn tabs and newlines into spaces, so text can't break the
-- one-script-per-line format of state.tsv or the screen layout
local function clean(s)
  return (tostring(s or ""):gsub("[\t\r\n]", " "))
end

-- quote a string for the shell: 'it'\''s' style
local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- today's date as YYYY-MM-DD, or nil if the clock isn't set.
-- norns has no battery-backed clock; until it syncs time over the
-- network it can report a date around 1970.
local function today()
  local d = os.date("%Y-%m-%d")
  if tonumber(d:sub(1, 4)) < 2020 then return nil end
  return d
end

-- days from date a to date b (both YYYY-MM-DD), or nil if either is bad
local function days_between(a, b)
  local function t(d)
    local y, m, dd = tostring(d):match("^(%d+)-(%d+)-(%d+)$")
    if not y then return nil end
    return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(dd), hour = 12 })
  end
  local ta, tb = t(a), t(b)
  if not ta or not tb then return nil end
  return math.floor((tb - ta) / 86400 + 0.5)
end

--------------------------------------------------------------------------
-- your record: state.tsv
--
-- lines starting with "#" hold settings ("# sort status"); every other
-- line is "<project name><tab><first seen><tab><marked new>". first seen
-- is empty for scripts already in the catalog on zzup's first run (there's
-- no meaningful local date for those), and marked new is empty once the
-- script is no longer new to you.
--------------------------------------------------------------------------

local function load_state()
  local s = read_file(STATE_FILE)
  if not s then return false end
  seen, newmark = {}, {}
  for line in s:gmatch("[^\n]+") do
    local k, v = line:match("^#%s*(%S+)%s*(.*)$")
    if k then
      if k == "sort" then settings.sort = v
      elseif k == "hide_installed" then settings.hide_installed = (v == "1")
      elseif k == "dates_on" then settings.dates_on = (v ~= "0")
      elseif k == "dates_url" and v ~= "" then settings.dates_url = v
      elseif k == "dates_fetched" then settings.dates_fetched = tonumber(v) or 0
      end
    else
      local name, first, nw = line:match("^([^\t]+)\t([^\t]*)\t?([^\t]*)")
      if name then
        seen[name] = first
        if nw ~= "" then newmark[name] = nw end
      end
    end
  end
  return true
end

local function save_state()
  local out = {
    "# zzup 2",
    "# sort " .. settings.sort,
    "# hide_installed " .. (settings.hide_installed and "1" or "0"),
    "# dates_on " .. (settings.dates_on and "1" or "0"),
    "# dates_url " .. settings.dates_url,
    "# dates_fetched " .. string.format("%d", settings.dates_fetched),
  }
  if seen then
    local names = {}
    for name in pairs(seen) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      out[#out + 1] = name .. "\t" .. seen[name] .. "\t" .. (newmark[name] or "")
    end
  end
  write_file(STATE_FILE, table.concat(out, "\n") .. "\n")
end

-- zzup v1 kept seen.tsv. if that's all there is, carry its names over
-- (as already seen, nothing new) so upgrading doesn't count as a first run
local function import_v1()
  local s = read_file(OLD_SEEN_FILE)
  if not s then return false end
  seen, newmark = {}, {}
  for line in s:gmatch("[^\n]+") do
    local name, d, flag = line:match("^([^#\t][^\t]*)\t([^\t]*)\t?(.*)$")
    -- v1's first-scan entries were dated the day of its first run, which
    -- says nothing about them, so they become undated like the rest
    if name then seen[name] = (flag == "first") and "" or d end
  end
  return true
end

--------------------------------------------------------------------------
-- catalog and dates
--------------------------------------------------------------------------

-- decode catalog json into a list of entries. each entry is a table with
-- fields like project_name, project_url, author, description, tags.
-- entries without a project name are skipped. returns nil on failure.
local function decode_catalog(text)
  if not text or #text == 0 then return nil end
  local cat, err = json_decode(text)
  if type(cat) ~= "table" or type(cat.entries) ~= "table" then
    print("zzup: catalog parse failed: " .. tostring(err))
    return nil
  end
  local out = {}
  for _, e in ipairs(cat.entries) do
    if type(e) == "table" and type(e.project_name) == "string" then
      e.project_name = clean(e.project_name)
      out[#out + 1] = e
    end
  end
  if #out == 0 then return nil end
  return out
end

-- decode dates.json; returns its "scripts" table, or nil
local function decode_dates(text)
  if not text or #text == 0 then return nil end
  local d = json_decode(text)
  if type(d) ~= "table" or d.version ~= 1 or type(d.scripts) ~= "table" then
    return nil
  end
  return d.scripts
end

-- offline fallback: read every *.json catalog maiden has saved in
-- dust/data/catalogs and merge them, skipping duplicate project names
local function load_maiden_catalogs()
  local ok, files = pcall(util.scandir, MAIDEN_CATS)
  if not ok or not files then return nil end
  local merged, have = {}, {}
  for _, f in ipairs(files) do
    if f:match("%.json$") then
      for _, e in ipairs(decode_catalog(read_file(MAIDEN_CATS .. f)) or {}) do
        if not have[e.project_name] then
          have[e.project_name] = true
          merged[#merged + 1] = e
        end
      end
    end
  end
  if #merged == 0 then return nil end
  return merged
end

-- "owner/repo" from a github url, lowercased, or nil.
-- handles https and ssh forms, ".git", and links into subfolders or
-- files ("/tree/main", "/blob/main/x.lua", release zips).
local function github_id(url)
  url = tostring(url or "")
  local owner, repo = url:match("github%.com[/:]([^/]+)/([^/%?#]+)")
  if not owner then return nil end
  repo = repo:gsub("%.git$", "")
  return (owner .. "/" .. repo):lower()
end

-- the repo name from a catalog entry's url: a script installed with
-- ;install usually lives in a folder with this name
local function repo_name(e)
  local id = github_id(e.project_url)
  if not id then return nil end
  -- keep the original capitalization for the folder name
  local _, repo = tostring(e.project_url):match("github%.com/([^/]+)/([^/%?#]+)")
  return repo and (repo:gsub("%.git$", "")) or nil
end

--------------------------------------------------------------------------
-- installed scripts
--------------------------------------------------------------------------

-- every folder in dust/code (util.scandir marks folders with a "/")
local function scan_folders()
  folders = {}
  local ok, files = pcall(util.scandir, _path.code)
  if not ok or not files then return end
  for _, f in ipairs(files) do
    local name = f:match("^(.-)/$")
    if name and name ~= "" then folders[name] = true end
  end
end

-- the dust/code folder a catalog entry is installed in, or nil.
-- maiden's catalog installs use the project name; ;install uses the
-- repo name. either counts.
local function install_folder(e)
  if folders[e.project_name] then return e.project_name end
  local r = repo_name(e)
  if r and folders[r] then return r end
  return nil
end

-- the published commit for a catalog entry, from dates.json
local function published_commit(e)
  local d = dates and dates[e.project_name]
  return d and d.commit or nil
end

-- the install mark for an entry, from its git check:
--   "" not installed, "*" up to date, "!" update available,
--   "m" modified locally, "!m" both, "?" can't check, "~" local only
-- marks start as "*" (or "~") and are refined once the checks finish.
local function install_mark(e)
  if e._local then return "~" end
  local folder = e._folder
  if not folder then return "" end
  local c = checks[folder]
  if not c then return "*" end              -- not checked yet
  if c.kind == "nogit" then return "?" end  -- copied by hand
  -- a folder whose git origin isn't this entry's repo is someone else's
  -- copy (a fork, or your own script with the same name)
  local want = github_id(e.project_url)
  if not want or github_id(c.origin) ~= want then return "~" end
  if not published_commit(e) then return "?" end  -- nothing to compare with
  local modified = c.dirty or c.ahead > 0 or c.cstate == "anc"
  local behind = (c.cstate == "nanc" or c.cstate == "missing")
  if behind and modified then return "!m" end
  if behind then return "!" end
  if modified then return "m" end
  return "*"
end

-- write and run the git checks for every installed catalog script, in
-- the background. for each folder this records where its git origin
-- points, whether it has uncommitted edits or unpushed commits, and how
-- its HEAD relates to the published commit:
--   eq       HEAD is the published commit
--   anc      the published commit is in your history: you're ahead
--   nanc     you have the published commit but HEAD doesn't contain it
--   missing  you don't have the published commit: you're behind
--   none     no published commit to compare with
-- no network is used: these are all local git commands.
local function run_checks(done)
  local lines = { "cd " .. shq(_path.code) .. " || exit 0" }
  local n = 0
  for _, e in ipairs(catalog) do
    local folder = e._folder
    if folder then
      n = n + 1
      local c = published_commit(e) or ""
      local d = shq(folder)
      lines[#lines + 1] = table.concat({
        "d=" .. d .. "; C=" .. shq(c),
        'if [ -e "$d/.git" ]; then',
        '  o=$(git -C "$d" config --get remote.origin.url 2>/dev/null)',
        '  h=$(git -C "$d" rev-parse HEAD 2>/dev/null)',
        '  x=0; [ -n "$(git -C "$d" status --porcelain --untracked-files=no 2>/dev/null)" ] && x=1',
        '  a=$(git -C "$d" rev-list --count "@{u}..HEAD" 2>/dev/null); [ -n "$a" ] || a=0',
        '  c=none',
        '  if [ -n "$C" ]; then',
        '    if [ "$h" = "$C" ]; then c=eq',
        '    elif git -C "$d" cat-file -e "$C^{commit}" 2>/dev/null; then',
        '      if git -C "$d" merge-base --is-ancestor "$C" HEAD 2>/dev/null; then c=anc; else c=nanc; fi',
        '    else c=missing; fi',
        '  fi',
        '  printf "R\\t%s\\t%s\\t%s\\t%s\\t%s\\n" "$d" "$o" "$x" "$a" "$c"',
        'else printf "N\\t%s\\n" "$d"; fi',
      }, "\n")
    end
  end
  if n == 0 then checks = {}; done(); return end
  write_file(CHECK_SCRIPT, table.concat(lines, "\n") .. "\n")

  local function parse(output)
    checks = {}
    for line in (output or ""):gmatch("[^\n]+") do
      local kind, rest = line:match("^(%u)\t(.*)$")
      if kind == "N" then
        checks[rest] = { kind = "nogit" }
      elseif kind == "R" then
        local folder, origin, x, a, c = rest:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
        if folder then
          checks[folder] = { kind = "git", origin = origin, dirty = (x == "1"),
            ahead = tonumber(a) or 0, cstate = c }
        end
      end
    end
    done()
  end

  local cmd = "sh " .. shq(CHECK_SCRIPT)
  if norns and norns.system_cmd then
    norns.system_cmd(cmd, parse)
  else
    parse(util.os_capture(cmd, true))
  end
end

--------------------------------------------------------------------------
-- tracking what's new to you
--------------------------------------------------------------------------

-- the date an entry was added to the catalog: from dates.json if we
-- have it, otherwise the date this norns first saw it. scripts that were
-- already in the catalog on zzup's first run have no date that way.
local function added_date(e)
  local d = dates and dates[e.project_name]
  if d and d.added then return d.added end
  local s = seen and seen[e.project_name]
  if not s or s == "" then return nil end
  return s
end

-- record the catalog against your record: anything not seen before is
-- new to you. on the very first run, "new" is anything added to the
-- catalog in the last NEW_FIRST_RUN_DAYS days (needs dates.json).
local function track()
  local d = today()
  if not d then return end  -- clock not set: try again next time
  local first = (seen == nil)
  if first then seen, newmark = {}, {} end
  for _, e in ipairs(catalog) do
    local name = e.project_name
    if seen[name] == nil then
      seen[name] = first and "" or d
      if first then
        local added = dates and dates[name] and dates[name].added
        local age = added and days_between(added, d)
        if age and age <= NEW_FIRST_RUN_DAYS then newmark[name] = d end
      else
        newmark[name] = d
      end
    end
  end
  -- "new" marks clear themselves after NEW_EXPIRY_DAYS
  for name, marked in pairs(newmark) do
    local age = days_between(marked, d)
    if age and age > NEW_EXPIRY_DAYS then newmark[name] = nil end
  end
  save_state()
end

--------------------------------------------------------------------------
-- building the list
--------------------------------------------------------------------------

-- combine the catalog with local-only folders, and work out each row's
-- folder, marks and dates
local function assemble()
  entries = {}
  local claimed = {}
  for _, e in ipairs(catalog) do
    e._folder = install_folder(e)
    if e._folder then claimed[e._folder] = true end
    entries[#entries + 1] = e
  end
  -- folders no catalog entry claims are local-only rows
  for folder in pairs(folders) do
    if not claimed[folder] then
      entries[#entries + 1] = { project_name = folder, _local = true, _folder = folder,
        -- it was in the catalog once if it's in your record
        _removed = seen and seen[folder] ~= nil }
    end
  end
end

-- the group a row belongs to in the "status" sort: things to act on first
local function status_group(e)
  if e._mark == "!" or e._mark == "!m" then return 0 end
  if e._mark == "m" then return 1 end
  if e._new then return 2 end
  return 3
end

local function by_name(a, b) return a.project_name:lower() < b.project_name:lower() end

-- newest first; rows without a date go last
local function by_date(field)
  return function(a, b)
    local da, db = a[field] or "", b[field] or ""
    if da ~= db then return da > db end
    return by_name(a, b)
  end
end

local sorters = {
  ["added"] = by_date("_added"),
  ["a-z"] = by_name,
  ["updated"] = by_date("_updated"),
  ["author"] = function(a, b)
    local aa, ab = (a.author or "~"):lower(), (b.author or "~"):lower()
    if aa ~= ab then return aa < ab end
    return by_name(a, b)
  end,
  ["status"] = function(a, b)
    local ga, gb = status_group(a), status_group(b)
    if ga ~= gb then return ga < gb end
    return by_date("_added")(a, b)
  end,
}

-- rebuild the on-screen list: refresh each row's marks, apply the hide
-- installed setting, sort, and keep the cursor on the same script
local function rebuild()
  local selected = list[cursor]
  counts = { new = 0, upd = 0 }
  list = {}
  for _, e in ipairs(entries) do
    e._mark = install_mark(e)
    e._new = (not e._local) and newmark[e.project_name] ~= nil
    e._added = (not e._local) and added_date(e) or nil
    local d = dates and dates[e.project_name]
    e._updated = (not e._local) and d and d.updated or nil
    if e._new then counts.new = counts.new + 1 end
    if e._mark:sub(1, 1) == "!" then counts.upd = counts.upd + 1 end
    if not (settings.hide_installed and e._mark ~= "") then
      list[#list + 1] = e
    end
  end
  table.sort(list, sorters[settings.sort] or sorters["status"])
  -- put the cursor back on the script that was selected, if it's still shown
  cursor = 1
  for i, e in ipairs(list) do
    if e == selected then cursor = i; break end
  end
end

-- run the git checks, then refresh the list with their results
local function check_installed()
  busy = "checking"
  redraw()
  run_checks(function()
    busy = ""
    rebuild()
    redraw()
  end)
end

-- start using a catalog: record what's new, then build the list
local function use_catalog(es)
  catalog = es
  scan_folders()
  track()
  assemble()
  rebuild()
end

--------------------------------------------------------------------------
-- download
--------------------------------------------------------------------------

local function dates_wanted()
  if not settings.dates_on then return false end
  if not dates then return true end
  return os.time() - settings.dates_fetched > DATES_MAX_AGE
end

-- called when the downloads finish. `output` is whatever the commands
-- printed; each curl prints a marker only if it succeeded.
local function finish_download(output)
  output = output or ""

  if output:find("ZZUP_DATES_OK", 1, true) then
    local d = decode_dates(read_file(DATA_DIR .. "dates.download"))
    if d then
      os.rename(DATA_DIR .. "dates.download", DATES_CACHE)
      dates = d
      settings.dates_fetched = os.time()
    end
  end
  os.remove(DATA_DIR .. "dates.download")

  local es = nil
  if output:find("ZZUP_CATALOG_OK", 1, true) then
    es = decode_catalog(read_file(DATA_DIR .. "catalog.download"))
    if es then os.rename(DATA_DIR .. "catalog.download", CATALOG_CACHE) end
  end
  os.remove(DATA_DIR .. "catalog.download")

  offline = (es == nil)
  if not es then
    -- no network: keep the cached catalog, or fall back to maiden's copy
    es = (#catalog > 0 and catalog) or load_maiden_catalogs()
  end
  if es then use_catalog(es) end
  check_installed()
end

-- download the catalog, and dates.json if it's due, in the background
local function fetch()
  busy = "loading"
  redraw()
  local function curl(url, file, marker)
    return "curl -fsSL --connect-timeout 10 --max-time 30 -o " .. shq(DATA_DIR .. file) ..
      " " .. shq(url) .. " && echo " .. marker
  end
  local cmd = curl(CATALOG_URL, "catalog.download", "ZZUP_CATALOG_OK")
  if dates_wanted() then
    cmd = cmd .. "; " .. curl(settings.dates_url, "dates.download", "ZZUP_DATES_OK")
  end
  if norns and norns.system_cmd then
    -- runs in the background and calls finish_download when done,
    -- so the screen and controls stay responsive meanwhile
    norns.system_cmd(cmd, finish_download)
  else
    -- older norns without system_cmd: run it directly (blocks until done)
    finish_download(util.os_capture(cmd, true))
  end
end

--------------------------------------------------------------------------
-- drawing helpers
--------------------------------------------------------------------------

-- shorten text to fit `width` pixels, adding ".." if anything was cut.
-- trims whole utf-8 characters so accented letters aren't split in half.
local function fit(text, width)
  text = tostring(text)
  if screen.text_extents(text) <= width then return text end
  while #text > 0 and screen.text_extents(text .. "..") > width do
    local cut = utf8.offset(text, -1)
    if not cut or cut < 1 then text = text:sub(1, -2) else text = text:sub(1, cut - 1) end
  end
  return text .. ".."
end

-- break text into lines no wider than `width` pixels, at word boundaries.
-- a single word too long for one line is shortened with fit().
local function wrap(text, width)
  local lines, line = {}, ""
  for word in tostring(text):gmatch("%S+") do
    local try = line == "" and word or (line .. " " .. word)
    if screen.text_extents(try) <= width then
      line = try
    else
      if line ~= "" then lines[#lines + 1] = line end
      line = fit(word, width)
    end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end

-- the date column: YY-MM-DD, or blank
local function short_date(d)
  if not d then return "" end
  return d:sub(3)
end

-- the header used by every screen: a title on the left, optional
-- dim text on the right, and a line underneath
local function draw_header(title, right)
  screen.level(15)
  screen.move(0, 7)
  screen.text(fit(title, W))
  if right and right ~= "" then
    screen.level(4)
    screen.move(W, 7)
    screen.text_right(fit(right, W - screen.text_extents(title) - 6))
  end
  screen.move(0, 10)
  screen.line(W, 10)
  screen.stroke()
end

--------------------------------------------------------------------------
-- screens
--------------------------------------------------------------------------

-- the main list. each row: new mark, install mark, date added, name.
-- the header shows the sort order, the row count ("-*" while installed
-- scripts are hidden) and, on the right, what's busy, "offline", or the
-- counts of new scripts and updates. there's only room for one of those
-- next to the sort label, so "offline" replaces the counts.
local function draw_list()
  local title = "sort: " .. (SORT_LABELS[settings.sort] or settings.sort) .. " " .. #list ..
    (settings.hide_installed and " -*" or "")
  local right = busy
  if right == "" and offline then
    right = "offline"
  elseif right == "" then
    local parts = {}
    if counts.new > 0 then parts[#parts + 1] = "+" .. counts.new end
    if counts.upd > 0 then parts[#parts + 1] = "!" .. counts.upd end
    right = table.concat(parts, " ")
  end
  draw_header(title, right)

  -- nothing to list: explain why
  if #list == 0 then
    screen.level(6)
    screen.move(0, 30)
    if busy ~= "" then
      screen.text("loading...")
    elseif #entries > 0 then
      screen.text("everything is installed")
      screen.move(0, 42)
      screen.text("K2: show installed")
    else
      screen.text("no catalog yet")
      screen.move(0, 42)
      screen.text("connect to wifi and reload")
    end
    return
  end

  -- scroll the window so the cursor row is always visible
  if cursor < top then top = cursor end
  if cursor >= top + ROWS then top = cursor - ROWS + 1 end

  for i = 0, ROWS - 1 do
    local e = list[top + i]
    if not e then break end
    local y = 20 + i * ROW_H
    local sel = (top + i) == cursor
    if sel then
      screen.level(2)
      screen.rect(0, y - 7, W, 9)
      screen.fill()
    end
    -- new scripts and available updates are brighter than the rest
    local bright = e._new or e._mark:sub(1, 1) == "!"
    screen.level(sel and 15 or (bright and 12 or 5))
    if e._new then screen.move(X_NEW, y); screen.text("+") end
    if e._mark ~= "" then screen.move(X_MARK, y); screen.text(e._mark) end
    screen.move(X_DATE, y)
    screen.text(short_date(e._added))
    screen.move(X_NAME, y)
    screen.text(fit(e.project_name, W - X_NAME))
  end
end

-- what a row's install mark means, in words
local MARK_TEXT = {
  ["*"] = "installed, up to date",
  ["!"] = "update available",
  ["m"] = "installed, modified locally",
  ["!m"] = "update available, and modified locally: updating could lose your changes",
  ["?"] = "installed, but can't check for updates",
}

-- prepare the detail screen for entry `e`: each line is { text, brightness }
local function build_detail(e)
  detail_lines = {}
  local function add(s, lvl) detail_lines[#detail_lines + 1] = { s, lvl } end
  local function add_wrapped(s, lvl)
    for _, l in ipairs(wrap(s, W - 2)) do add(l, lvl) end
  end

  if e._local then
    add_wrapped(e._removed and "installed, but no longer in the catalog"
      or "local only: not in the catalog", 10)
    add("folder: " .. e._folder, 6)
    detail_top = 1
    return
  end

  if e._new then add("new to you", 15) end
  if e._mark == "~" then
    add_wrapped("you have a '" .. e._folder .. "' folder from a different repo", 10)
  elseif MARK_TEXT[e._mark] then
    add_wrapped(MARK_TEXT[e._mark], 10)
  end
  if e._added == BULK_IMPORT_DATE then
    add("added: 2019 or earlier", 6)
  elseif e._added then
    add("added: " .. e._added, 6)
  end
  if e._updated then add("updated: " .. e._updated, 6) end
  if e.author then add("by " .. clean(e.author), 6) end
  -- most entries use "tags"; a few older ones use "tag"
  local tags = e.tags or e.tag
  if type(tags) == "table" and #tags > 0 then
    add_wrapped("#" .. table.concat(tags, " #"), 3)
  end
  if e.description then add_wrapped(clean(e.description), 15) end
  detail_top = 1
end

-- detail screen: the script name as the header, then the prepared lines,
-- scrolled by detail_top
local function draw_detail()
  local e = list[cursor]
  if not e then view = "list"; return draw_list() end
  draw_header(e.project_name)
  for i = 0, ROWS - 1 do
    local l = detail_lines[detail_top + i]
    if not l then break end
    screen.level(l[2])
    screen.move(0, 20 + i * ROW_H)
    screen.text(l[1])
  end
end

-- the key: what each mark means, on one screen. reached by turning E1
-- left from the first sort order; E1 right or K2 goes back to the list.
-- "?" (can't check) and the header's "-*" (installed hidden) are left
-- out to keep it to one screen; the README explains them.
local KEY_LINES = {
  { "+",  "new to you" },
  { "*",  "installed, up to date" },
  { "!",  "update available" },
  { "m",  "modified locally" },
  { "!m", "modified + update exists" },
  { "~",  "local only" },
}

local function draw_key()
  draw_header("key", "E1 > list")
  -- six lines at 9 pixels apart fit below the header
  for i, l in ipairs(KEY_LINES) do
    local y = 9 + i * 9
    screen.level(15)
    screen.move(0, y)
    screen.text(l[1])
    screen.level(8)
    screen.move(14, y)
    screen.text(l[2])
  end
end

-- norns calls redraw() when it needs the screen; we also call it
-- after every change
function redraw()
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)
  if view == "detail" then draw_detail()
  elseif view == "key" then draw_key()
  else draw_list() end
  screen.update()
end

--------------------------------------------------------------------------
-- controls
--------------------------------------------------------------------------

-- encoders: n is which encoder (1-3), d is the direction/amount turned
function enc(n, d)
  if view == "detail" then
    -- E2/E3 scroll a long description
    if n == 2 or n == 3 then
      local max_top = math.max(#detail_lines - ROWS + 1, 1)
      detail_top = util.clamp(detail_top + d, 1, max_top)
    end
  elseif view == "key" then
    -- E1 right leaves the key, back to the list
    if n == 1 and d > 0 then view = "list" end
  elseif n == 1 then
    -- E1 steps through the sort orders. turning left past the first one
    -- shows the key.
    local i = 1
    for k, s in ipairs(SORTS) do if s == settings.sort then i = k end end
    if d < 0 and i == 1 then
      view = "key"
      redraw()
      return
    end
    i = util.clamp(i + (d > 0 and 1 or -1), 1, #SORTS)
    if SORTS[i] ~= settings.sort then
      settings.sort = SORTS[i]
      rebuild()
      cursor, top = 1, 1
      save_state()
    end
  elseif #list > 0 then
    -- E2 moves one row, E3 moves a page
    local step = (n == 3) and ROWS or 1
    cursor = util.clamp(cursor + d * step, 1, #list)
  end
  redraw()
end

-- keys: n is which key (1-3), z is 1 on press and 0 on release.
-- K1 is left alone; norns uses it for the system menu.
function key(n, z)
  if z ~= 1 then return end
  if view == "detail" or view == "key" then
    -- K2 goes back to the list
    if n == 2 then view = "list" end
  else
    if n == 2 then
      -- K2 hides or shows installed scripts
      settings.hide_installed = not settings.hide_installed
      rebuild()
      top = 1
      save_state()
    elseif n == 3 and list[cursor] then
      -- K3 opens details. looking at a script means it's no longer new.
      local e = list[cursor]
      build_detail(e)
      view = "detail"
      if newmark[e.project_name] then
        newmark[e.project_name] = nil
        save_state()
        rebuild()  -- the cursor stays on this script
      end
    end
  end
  redraw()
end

--------------------------------------------------------------------------
-- settings in the norns PARAMS menu
--------------------------------------------------------------------------

local function add_params()
  params:add_separator("zzup")
  params:add_option("zzup_dates", "dates.json", { "on", "off" }, settings.dates_on and 1 or 2)
  params:set_action("zzup_dates", function(v)
    settings.dates_on = (v == 1)
    if not settings.dates_on then dates = nil end
    settings.dates_fetched = 0
    save_state()
  end)
  -- text settings need a newer norns; without them the address can still
  -- be changed on the "# dates_url" line in dust/data/zzup/state.tsv
  if params.add_text then
    params:add_text("zzup_dates_url", "dates url", settings.dates_url)
    params:set_action("zzup_dates_url", function(v)
      if v == nil or v == "" then v = DEFAULT_DATES_URL end
      if v ~= settings.dates_url then
        settings.dates_url = v
        settings.dates_fetched = 0  -- download from the new address next time
        save_state()
      end
    end)
  end
end

--------------------------------------------------------------------------
-- lifecycle: norns calls init() when the script loads and cleanup()
-- when it's replaced or norns shuts down
--------------------------------------------------------------------------

function init()
  util.make_dir(DATA_DIR)
  if not load_state() then import_v1() end
  -- an unknown saved sort order falls back to "status"
  local known = false
  for _, s in ipairs(SORTS) do if s == settings.sort then known = true end end
  if not known then settings.sort = "status" end
  add_params()

  -- show the cached data straight away, then refresh from the network
  if settings.dates_on then dates = decode_dates(read_file(DATES_CACHE)) end
  local cached = decode_catalog(read_file(CATALOG_CACHE))
  if cached then
    catalog = cached
    scan_folders()
    assemble()
    rebuild()
  end
  fetch()
end

function cleanup()
  save_state()
end
