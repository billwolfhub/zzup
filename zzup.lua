-- zzup
-- which catalog scripts are
-- new to this norns?
--
-- tracks the community catalog
-- and remembers the date each
-- script first appeared here.
--
-- E2 scroll   E3 page
-- K3 details  K2 back / filter
-- hold K2: hide installed
--
-- v1.2 @billwolf

--------------------------------------------------------------------------
-- overview
--
-- the norns community catalog lists every published script, but it has
-- no dates, so there's no way to tell new scripts from old ones. this
-- script keeps its own record instead:
--
--   1. download the current catalog (in the background)
--   2. compare it with the list of scripts this norns has already seen
--   3. stamp anything new with today's date and save the record
--   4. show the dated (new) scripts first, newest at the top
--
-- the very first run has no history to compare against, so it scans
-- dust/code instead: scripts already installed become the undated
-- "baseline", and everything else is marked new as of that day.
--------------------------------------------------------------------------

-- where the catalog comes from. this is the same file maiden's project
-- manager uses for its "community" catalog.
local CATALOG_URL = "https://raw.githubusercontent.com/monome/norns-community/main/community.json"

-- files this script keeps in dust/data/zzup/
local DATA_DIR     = _path.data .. "zzup/"
local SEEN_FILE    = DATA_DIR .. "seen.tsv"          -- first-seen record (plain text)
local CACHE_FILE   = DATA_DIR .. "catalog.json"      -- last good download, for offline use
local TMP_FILE     = DATA_DIR .. "catalog.download"  -- download in progress

-- maiden saves its own copies of the catalogs here; used as a fallback
-- when we're offline and have never downloaded a catalog ourselves
local MAIDEN_CATS  = _path.data .. "catalogs/"

-- screen layout: norns is 128x64. a header line on top, then ROWS
-- lines of text spaced ROW_H pixels apart.
local ROWS = 5
local ROW_H = 10
local W = 128

-- how long K2 must be held (seconds) to count as a long press
local HOLD_TIME = 0.5

--------------------------------------------------------------------------
-- state
--------------------------------------------------------------------------

local seen = nil        -- project name -> "YYYY-MM-DD" (first seen),
                        -- "" for baseline entries, "?" if the clock was unset.
                        -- nil until the first catalog has been recorded.
local first_scan = {}   -- names marked new by the first-run scan (not installed then).
                        -- they sort below scripts that genuinely appeared later.
local meta = {}         -- extra values stored in seen.tsv: baseline date, last check
local entries = {}      -- the current catalog: a list of entry tables
local list = {}         -- the entries shown on screen under the current filter
local filter = "new"    -- "new" shows dated entries only; "all" adds the baseline
local hide_installed = false  -- leave installed scripts out of the list (hold K2);
                              -- saved in seen.tsv so it sticks between runs
local view = "intro"    -- which screen is showing: "intro" | "list" | "detail"
local cursor, top = 1, 1                -- selected row, and first visible row
local detail_lines, detail_top = {}, 1  -- wrapped text for the detail screen
local status = ""       -- short message in the header ("checking...", "+2 today")
local latest = nil      -- the most recent first-seen date; those rows draw brightest
local fetching = false  -- true while a download is running
local k2_clock = nil    -- timer running while K2 is held, to detect a long press
local k2_down = false   -- K2 was pressed while the list was showing
local k2_long = false   -- the current K2 press already counted as a long press

--------------------------------------------------------------------------
-- json decoding
--
-- norns doesn't ship a json library, so this is a small decoder that
-- handles everything the catalog uses: objects, arrays, strings (with
-- escapes, including \uXXXX), numbers, true/false/null.
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
-- files
--------------------------------------------------------------------------

-- the whole contents of a file, or nil if it doesn't exist
local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- turn tabs and newlines into spaces, so text can't break the
-- one-script-per-line format of seen.tsv or the screen layout
local function clean(s)
  return (tostring(s or ""):gsub("[\t\r\n]", " "))
end

-- today's date as YYYY-MM-DD
local function today()
  local d = os.date("%Y-%m-%d")
  -- norns has no battery-backed clock; until it syncs time over the
  -- network it can report a date around 1970. record "?" instead of
  -- a wrong date in that case.
  if tonumber(d:sub(1, 4)) < 2020 then return "?" end
  return d
end

-- read seen.tsv into a table of name -> date.
-- format: lines starting with "#" hold settings ("# baseline 2026-10-10"),
-- every other line is "<project name><tab><date>" (date empty for baseline),
-- optionally followed by "<tab>first" for entries from the first-run scan.
-- returns nil if the file doesn't exist yet (i.e. this is the first run).
local function load_seen()
  local s = read_file(SEEN_FILE)
  if not s then return nil end
  local t = {}
  meta = {}
  first_scan = {}
  for line in s:gmatch("[^\n]+") do
    local k, v = line:match("^#%s*(%S+)%s*(.*)$")
    if k then
      meta[k] = v
    else
      local name, date, flag = line:match("^([^\t]+)\t([^\t]*)\t?(.*)$")
      if name then
        t[name] = date
        if flag == "first" then first_scan[name] = true end
      end
    end
  end
  return t
end

-- write the seen table back to seen.tsv, sorted by name.
-- writes to a temporary file first and then renames it, so a crash or
-- power loss mid-write can't leave a half-written record behind.
local function save_seen()
  local names = {}
  for name in pairs(seen) do names[#names + 1] = name end
  table.sort(names)
  local out = {
    "# zzup 1",
    "# baseline " .. (meta.baseline or ""),
    "# checked " .. (meta.checked or ""),
    "# hide_installed " .. (hide_installed and "1" or "0"),
  }
  for _, name in ipairs(names) do
    out[#out + 1] = name .. "\t" .. seen[name] .. (first_scan[name] and "\tfirst" or "")
  end
  local tmp = SEEN_FILE .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then print("zzup: can't write " .. tmp); return end
  f:write(table.concat(out, "\n"), "\n")
  f:close()
  os.rename(tmp, SEEN_FILE)
end

--------------------------------------------------------------------------
-- catalog
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
  return out
end

-- offline fallback: read every *.json catalog maiden has saved in
-- dust/data/catalogs and merge them, skipping duplicate project names.
-- returns nil if there's nothing usable.
local function load_maiden_catalogs()
  local ok, files = pcall(util.scandir, MAIDEN_CATS)
  if not ok or not files then return nil end
  local merged, have = {}, {}
  for _, f in ipairs(files) do
    if f:match("%.json$") then
      local es = decode_catalog(read_file(MAIDEN_CATS .. f))
      for _, e in ipairs(es or {}) do
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

-- the repository name from a github url, e.g.
-- "https://github.com/tehn/awake.git" -> "awake".
-- a script's install folder usually matches either this or its project name.
local function repo_name(e)
  local url = e.project_url or ""
  local name = url:match("github%.com/[^/]+/([^/%?#]+)")
  if name then name = name:gsub("%.git$", "") end
  return name
end

-- true if the script appears to be installed in dust/code
local function installed(e)
  if util.file_exists(_path.code .. e.project_name) then return true end
  local r = repo_name(e)
  return r ~= nil and util.file_exists(_path.code .. r)
end

--------------------------------------------------------------------------
-- tracking: compare a catalog with what we've seen, and record new entries
--------------------------------------------------------------------------

-- record first-seen dates for anything new in the catalog `es`.
-- returns: how many entries were new, and whether this was the first run.
local function track(es)
  local fresh = 0
  local d = today()
  if seen == nil then
    -- first run: there's no history to compare against, so use what's
    -- installed instead. scripts already in dust/code are clearly known,
    -- so they become the undated baseline. everything else is new to
    -- this norns and gets today's date. scripts that appear in later
    -- runs get later dates, so they still sort above this first batch.
    seen = {}
    for _, e in ipairs(es) do
      if installed(e) then
        seen[e.project_name] = ""
      else
        seen[e.project_name] = d
        first_scan[e.project_name] = true
        fresh = fresh + 1
      end
    end
    meta.baseline = d
    meta.checked = d
    save_seen()
    return fresh, true
  end
  -- later runs: any name we haven't seen before is new as of today.
  -- names we've already seen keep their original date.
  for _, e in ipairs(es) do
    if seen[e.project_name] == nil then
      seen[e.project_name] = d
      fresh = fresh + 1
    end
  end
  meta.checked = d
  save_seen()
  return fresh, false
end

-- how an entry ranks in the list: scripts that appeared after the first
-- scan (2) come first, then the first scan's not-installed scripts (1),
-- then the installed baseline (0)
local function rank(e)
  if e._seen == "" then return 0 end
  if first_scan[e.project_name] then return 1 end
  return 2
end

-- rebuild the on-screen list from `entries` and the seen record.
-- dated entries come first: genuinely new ones above the first scan's,
-- each group newest date first, then alphabetical. baseline entries
-- follow alphabetically, but only in the "all" filter.
-- installed scripts are left out entirely when hide_installed is on.
-- auto = true picks the filter automatically: "new" if there's anything
-- dated, otherwise "all" (used when a catalog loads, not on K2 toggles).
local function rebuild(auto)
  latest = nil
  local dated, base = {}, {}
  for _, e in ipairs(entries) do
    local d = seen and seen[e.project_name] or ""
    -- cache the date and installed state on the entry, so sorting and
    -- drawing don't have to look them up again
    e._seen = d
    e._inst = installed(e)
    if hide_installed and e._inst then
      -- skip it
    elseif d ~= "" then
      dated[#dated + 1] = e
      -- only genuinely new scripts count toward the bright "latest" batch
      if d ~= "?" and not first_scan[e.project_name]
        and (latest == nil or d > latest) then latest = d end
    else
      base[#base + 1] = e
    end
  end
  -- YYYY-MM-DD strings sort correctly as plain text
  table.sort(dated, function(a, b)
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then return ra > rb end
    if a._seen ~= b._seen then return a._seen > b._seen end
    return a.project_name:lower() < b.project_name:lower()
  end)
  table.sort(base, function(a, b)
    return a.project_name:lower() < b.project_name:lower()
  end)

  if auto then filter = (#dated > 0) and "new" or "all" end
  list = {}
  for _, e in ipairs(dated) do list[#list + 1] = e end
  if filter == "all" then
    for _, e in ipairs(base) do list[#list + 1] = e end
  end
  -- keep the cursor on a valid row if the list got shorter
  cursor = util.clamp(cursor, 1, math.max(#list, 1))
  top = util.clamp(top, 1, math.max(cursor, 1))
end

-- make `es` the current catalog: record anything new, rebuild the list,
-- and set the header status message.
-- offline = true when the catalog came from a local copy, not the network.
local function use(es, offline)
  entries = es
  local fresh, first = track(es)
  cursor, top = 1, 1
  rebuild(true)
  if first then
    status = "first scan"
  elseif fresh > 0 then
    status = "+" .. fresh .. " today"
  else
    status = "up to date"
  end
  if offline then status = "offline" end
end

--------------------------------------------------------------------------
-- download
--------------------------------------------------------------------------

-- called when curl finishes. `output` is whatever the command printed;
-- the command only prints ZZUP_OK if curl succeeded.
local function finish_download(output)
  fetching = false
  local text = nil
  if output and output:find("ZZUP_OK", 1, true) then
    text = read_file(TMP_FILE)
  end
  local es = decode_catalog(text)
  if es and #es > 0 then
    -- good download: keep it as the offline cache and use it
    os.rename(TMP_FILE, CACHE_FILE)
    use(es)
  else
    -- no network, or the download wasn't a valid catalog
    os.remove(TMP_FILE)
    if #entries == 0 then
      -- nothing cached either (fresh install): try maiden's saved catalogs
      local fallback = load_maiden_catalogs()
      if fallback then
        use(fallback, true)
      else
        status = "offline"
      end
    else
      -- keep showing the cached catalog loaded in init()
      status = "offline"
    end
  end
  redraw()
end

-- start downloading the catalog. curl saves it to TMP_FILE; -f makes curl
-- fail on http errors, and --max-time stops it hanging without network.
local function fetch()
  if fetching then return end
  fetching = true
  status = "checking..."
  redraw()
  local cmd = "curl -fsSL --max-time 30 -o '" .. TMP_FILE .. "' '" ..
    CATALOG_URL .. "' && echo ZZUP_OK"
  if norns and norns.system_cmd then
    -- runs in the background and calls finish_download when done,
    -- so the screen and controls stay responsive meanwhile
    norns.system_cmd(cmd, finish_download)
  else
    -- older norns without system_cmd: run it directly (blocks until done)
    finish_download(util.os_capture(cmd))
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

-- the date column in the list: YY-MM-DD, "--" for baseline, "??" if unknown
local function short_date(d)
  if d == "" then return "  --" end
  if d == "?" then return "  ??" end
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

-- opening screen: what the script does. the catalog downloads in the
-- background while this is showing, so the list is ready on K3.
local INTRO = "shows which scripts in the norns community catalog " ..
  "are new to this norns, and the date it first saw each one."

local function draw_intro()
  draw_header("zzup", status)
  screen.level(10)
  local lines = wrap(INTRO, W - 2)
  for i = 1, math.min(#lines, 5) do
    screen.move(0, 10 + i * 9)
    screen.text(lines[i])
  end
  screen.level(4)
  screen.move(0, 63)
  screen.text("K3 continue")
end

-- the main list: date seen on the left, script name on the right.
-- the selected row gets a highlight bar; the newest batch is brighter.
-- the title shows the filter and count, plus "-*" while installed
-- scripts are hidden.
local function draw_list()
  local title = (filter == "new" and "new" or "all") .. " " .. #list
  if hide_installed then title = title .. " -*" end
  draw_header(title, status)

  -- nothing to list: explain why
  if #list == 0 then
    screen.level(6)
    screen.move(0, 30)
    if fetching then
      screen.text("loading...")
    elseif seen then
      screen.text("nothing new since " .. (meta.baseline or "?"))
      screen.move(0, 42)
      screen.text("K2: show all")
      if hide_installed then
        screen.move(0, 52)
        screen.text("hold K2: show installed")
      end
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
    local idx = top + i
    local e = list[idx]
    if not e then break end
    local y = 20 + i * ROW_H
    local sel = idx == cursor
    if sel then
      screen.level(2)
      screen.rect(0, y - 7, W, 9)
      screen.fill()
    end
    local bright = rank(e) == 2 and e._seen == latest
    screen.level(sel and 15 or (bright and 12 or 5))
    screen.move(1, y)
    screen.text(short_date(e._seen))
    screen.move(38, y)
    -- "*" marks scripts that are already installed
    local name = e.project_name .. (e._inst and " *" or "")
    screen.text(fit(name, W - 39))
  end
end

-- prepare the detail screen for entry `e`: each line is { text, brightness }
local function build_detail(e)
  detail_lines = {}
  local function add(s, lvl) detail_lines[#detail_lines + 1] = { s, lvl } end
  local d = e._seen
  if d == "" then d = "installed before " .. (meta.baseline or "tracking")
  elseif d == "?" then d = "unknown (clock not set)"
  elseif first_scan[e.project_name] then d = d .. " (first scan)" end
  add("seen: " .. d, 10)
  if e.author then add("by " .. clean(e.author), 6) end
  if e._inst then add("installed", 6) end
  -- most entries use "tags"; a few older ones use "tag"
  local tags = e.tags or e.tag
  if type(tags) == "table" and #tags > 0 then
    for _, l in ipairs(wrap("#" .. table.concat(tags, " #"), W - 2)) do add(l, 3) end
  end
  if e.description then
    for _, l in ipairs(wrap(clean(e.description), W - 2)) do add(l, 15) end
  end
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

-- norns calls redraw() when it needs the screen; we also call it
-- after every change
function redraw()
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)
  if view == "intro" then draw_intro()
  elseif view == "detail" then draw_detail()
  else draw_list() end
  screen.update()
end

--------------------------------------------------------------------------
-- controls
--------------------------------------------------------------------------

-- encoders: n is which encoder (1-3), d is the direction/amount turned
function enc(n, d)
  if view == "intro" then return end
  if view == "detail" then
    -- E2/E3 scroll a long description
    if n == 2 or n == 3 then
      local max_top = math.max(#detail_lines - ROWS + 1, 1)
      detail_top = util.clamp(detail_top + d, 1, max_top)
    end
  else
    -- E2 moves one row, E3 moves a page
    if #list == 0 then return end
    local step = (n == 3) and ROWS or 1
    if n == 2 or n == 3 then
      cursor = util.clamp(cursor + d * step, 1, #list)
    end
  end
  redraw()
end

-- K2 short press in the list: toggle between "new" and "all"
local function toggle_filter()
  filter = (filter == "new") and "all" or "new"
  cursor, top = 1, 1
  rebuild()
end

-- K2 long press in the list: hide or show installed scripts.
-- the choice is saved so it's still in effect next time.
local function toggle_installed()
  hide_installed = not hide_installed
  cursor, top = 1, 1
  rebuild()
  status = hide_installed and "* hidden" or "* shown"
  if seen then save_seen() end
end

-- keys: n is which key (1-3), z is 1 on press and 0 on release.
-- K1 is left alone; norns uses it for the system menu.
function key(n, z)
  -- K2 in the list tells a short press from a long one. pressing starts
  -- a timer; if K2 is still down when it runs out, that's a long press
  -- and it acts right away, so you see the change without letting go.
  -- releasing before then cancels the timer and counts as a short press.
  if n == 2 and view == "list" then
    if z == 1 then
      k2_down, k2_long = true, false
      k2_clock = clock.run(function()
        clock.sleep(HOLD_TIME)
        k2_clock = nil
        k2_long = true
        toggle_installed()
        redraw()
      end)
    elseif k2_down then
      k2_down = false
      if k2_clock then clock.cancel(k2_clock); k2_clock = nil end
      if not k2_long then
        toggle_filter()
        redraw()
      end
    end
    return
  end

  if z ~= 1 then return end
  if view == "intro" then
    -- K2 or K3 leaves the opening screen
    if n == 2 or n == 3 then view = "list" end
  elseif view == "detail" then
    -- K2 goes back to the list
    if n == 2 then view = "list" end
  else
    -- (K2 in the list is handled above)
    if n == 3 and list[cursor] then
      -- K3 opens details for the selected script
      build_detail(list[cursor])
      view = "detail"
    end
  end
  redraw()
end

--------------------------------------------------------------------------
-- lifecycle: norns calls init() when the script loads and cleanup()
-- when it's replaced or norns shuts down
--------------------------------------------------------------------------

function init()
  util.make_dir(DATA_DIR)
  seen = load_seen()
  hide_installed = meta.hide_installed == "1"  -- restore the saved setting
  -- load the cached catalog first so the list is ready even if the
  -- network is slow or down, then refresh it from the network
  local cached = decode_catalog(read_file(CACHE_FILE))
  if cached and seen then
    entries = cached
    rebuild(true)
  end
  fetch()
end

function cleanup()
  if k2_clock then clock.cancel(k2_clock) end
  if seen then save_seen() end
end
