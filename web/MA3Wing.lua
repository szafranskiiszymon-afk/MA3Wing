-- MA3 Wing sync: zapisuje pozycje faderow (2xx) i galek (3xx, 4xx) z aktualnej strony
-- do pliku tymczasowego, ktory czyta most MA3 Wing na tym samym laptopie.
-- Uruchom raz (klik na plugin w puli). Ponowne klikniecie = restart i zapis wszystkiego od nowa.

local COLUMNS = 15        -- ile kolumn executorow sprawdzac (x01..x15)
local PERIOD  = 0.1       -- co ile sekund sprawdzac zmiany
local ROWS = {200, 300, 400}
-- Konsola grandMA3 (albo gdy nie da sie zapisac pliku): dane ida przez siec komenda SendOSC.
local OSC_LINE  = 1       -- numer linii w Menu - In & Out - OSC, ktora wysyla (Send=Yes) do laptopa z mostem
local FORCE_NET = false   -- true = zawsze przez siec, nawet na onPC (do testu)

local function say(t) if Printf then Printf('MA3 Wing: ' .. t) else print('MA3 Wing: ' .. t) end end

local function stateFile()
    local dir = nil
    if os and os.getenv then dir = os.getenv('TEMP') or os.getenv('TMP') end
    return (dir or 'C:\\Windows\\Temp') .. '\\MA3Wing-faders.txt'
end

local function faderValue(n)
    local ok, ex = pcall(GetExecutor, n)
    if not ok or ex == nil then return 0 end
    local ok2, v = pcall(function() return ex:GetFader({}) end)
    if ok2 and type(v) == 'number' then return v end
    return 0
end

local function pageNumber()
    local ok, _, page = pcall(GetExecutor, 201)
    if ok and page ~= nil then
        local ok2, no = pcall(function() return page.no end)
        if ok2 and tonumber(no) then return tonumber(no) end
    end
    return 1
end

-- bezpieczny odczyt wlasciwosci obiektu MA (rozne wersje: h.name / h.Name / h:Get('Name'))
local function prop(h, k)
    if h == nil then return nil end
    local K = k:sub(1,1):upper() .. k:sub(2)
    for _, key in ipairs({k, K}) do
        local ok, v = pcall(function() return h[key] end)
        if ok and v ~= nil and v ~= '' then return v end
    end
    local ok, v = pcall(function() return h:Get(K) end)
    if ok and v ~= nil and v ~= '' then return v end
    return nil
end

-- atrybuty pierwszego zaznaczonego urzadzenia:
-- { {grupa, nazwa, ladna nazwa, min, max, "channelset1;channelset2;..."}, ... }
local function children(h)
    if h == nil or type(h) == 'string' then return {} end
    local ok, c = pcall(function() return h:Children() end)
    if ok and type(c) == 'table' then return c end
    return {}
end
local uiDumped = false
local function clean(t) return (tostring(t or ''):gsub('[|=;~\r\n]', ' ')) end
local function logicalChannel(ui)
    local ok, u = pcall(GetUIChannel, ui)
    if not ok or u == nil then return nil end
    local lc = nil
    for _, k in ipairs({'logical_channel', 'logicalchannel', 'LogicalChannel'}) do
        local okk, v = pcall(function() return u[k] end)
        if okk and v ~= nil and type(v) ~= 'string' and type(v) ~= 'number' then lc = v; break end
    end
    if lc == nil and not uiDumped then
        uiDumped = true
        local keys = {}
        if type(u) == 'table' then for k, _ in pairs(u) do keys[#keys + 1] = tostring(k) end end
        say('nie znalazlem logical channel - pola UIChannel: ' .. table.concat(keys, ', '))
    end
    return lc
end
-- channel sety kanalu: kazda channel function (np. Gobo2, Gobo2WheelSpin) ma swoje sety.
-- Wynik: "funkcja~nazwa~dmx24;..." - iPad ustawia set przez: Attribute "X" At Absolute Decimal24 <dmx>
local function channelInfoRaw(lc)
    local sets, mn, mx = {}, nil, nil
    for _, cf in ipairs(children(lc)) do
        local fattr = tostring(prop(cf, 'attribute') or prop(cf, 'name') or '')
        if fattr ~= 'NoFeature' then
            if mn == nil then
                mn = tonumber(prop(cf, 'physicalfrom')); mx = tonumber(prop(cf, 'physicalto'))
            end
            local slots = nil
            local okw, wh = pcall(function() return cf.wheel end)
            if okw and wh ~= nil and type(wh) ~= 'string' then slots = children(wh) end
            for _, cs in ipairs(children(cf)) do
                local n = clean(prop(cs, 'name')):gsub('^%s+', ''):gsub('%s+$', '')
                local img, rgba = '', ''
                local si = tonumber(prop(cs, 'wheelslotindex'))
                if slots and si and slots[si] then
                    img = tostring(prop(slots[si], 'mediafilename') or ''):gsub('\\', '/')
                    local c = tostring(prop(slots[si], 'imagergba') or '')
                    if c:match('^%x%x%x%x%x%x%x%x$') and c:upper() ~= 'FFFFFFFF' then rgba = c:sub(1, 6) end
                end
                local d1 = tonumber(prop(cs, 'dmxfrom')); local d2 = tonumber(prop(cs, 'dmxto'))
                if n ~= '' and n ~= 'No Feature' and d1 and d2 and #sets < 120 then
                    local d = math.floor((d1 + d2) / 2)
                    if d > 16777215 then d = 16777215 end
                    sets[#sets + 1] = clean(fattr) .. '~' .. n .. '~' .. d .. '~' .. clean(img) .. '~' .. rgba
                end
            end
        end
    end
    local f = function(v) if v == nil then return '' end return string.format('%g', v) end
    if mn ~= nil and mx ~= nil and mn > mx then mn, mx = mx, mn end
    return f(mn), f(mx), table.concat(sets, ';')
end
local csCache = {}
local function channelInfo(ui)
    local lc = logicalChannel(ui)
    if lc == nil then return '', '', '' end
    local okk, key = pcall(function() return lc:ToAddr() end)
    if okk and key and csCache[key] then local c = csCache[key]; return c[1], c[2], c[3] end
    local a, b, c = channelInfoRaw(lc)
    if okk and key then csCache[key] = {a, b, c} end
    return a, b, c
end
-- numery zaznaczonych urzadzen (w kolejnosci zaznaczenia), np. "101,102,121"
local function selectionList()
    local ids, seen = {}, {}
    local ok, idx = pcall(SelectionFirst)
    local guard = 0
    while ok and idx ~= nil and guard < 3000 do
        guard = guard + 1
        local oks, sub = pcall(GetSubfixture, idx)
        if oks and sub ~= nil then
            local fid = tonumber(prop(sub, 'fid'))
            if fid == nil then
                local fx = prop(sub, 'fixture')
                if fx ~= nil and type(fx) ~= 'string' then fid = tonumber(prop(fx, 'fid')) end
            end
            if fid and not seen[fid] then seen[fid] = true; ids[#ids + 1] = fid end
        end
        ok, idx = pcall(SelectionNext, idx)
    end
    return table.concat(ids, ',')
end
local function attrsOf(sf, onlyGroups)
    local list = {}
    local ok2, chans = pcall(GetUIChannels, sf)
    if not ok2 or type(chans) ~= 'table' then return list, 'none' end
    local seen = {}
    for _, ui in ipairs(chans) do
        local ok3, a = pcall(GetAttributeByUIChannel, ui)
        if ok3 and a ~= nil then
            local name = tostring(prop(a, 'name') or '')
            if name ~= '' and not seen[name] then
                seen[name] = true
                local pretty = tostring(prop(a, 'pretty') or name)
                local grp = ''
                local feat = prop(a, 'feature')
                if type(feat) ~= 'string' and feat ~= nil then
                    local okp, par = pcall(function() return feat:Parent() end)
                    if okp and par ~= nil then grp = tostring(prop(par, 'name') or '') end
                end
                if onlyGroups == nil or onlyGroups[grp] or name:match('^Prism') then
                    local okc, mn, mx, sets = pcall(channelInfo, ui)
                    if not okc then mn, mx, sets = '', '', '' end
                    list[#list + 1] = { grp, name, pretty, mn, mx, sets }
                end
            end
        end
    end
    return list
end
local function attrList()
    local ok, sf = pcall(SelectionFirst)
    if not ok or sf == nil then return {}, 'none' end
    local list = attrsOf(sf)
    return list, tostring(sf) .. ':' .. #list
end
-- typy urzadzen w zaznaczeniu (do zakladki Gobo): { {name, fids={...}, attrs={...gobo...}}, ... }
local typeCache = {}
local function typeOf(sf)
    local okc, chans = pcall(GetUIChannels, sf)
    if not okc or type(chans) ~= 'table' or chans[1] == nil then return nil end
    local lc = logicalChannel(chans[1])
    if lc == nil then return nil end
    local h = lc
    for _ = 1, 12 do
        local okp, par = pcall(function() return h:Parent() end)
        if not okp or par == nil then break end
        h = par
        local okk, cls = pcall(function() return h:GetClass() end)
        if okk and cls == 'FixtureType' then
            local oka, addr = pcall(function() return h:ToAddr() end)
            return (oka and addr) or tostring(prop(h, 'name')), tostring(prop(h, 'name') or '?')
        end
    end
    return nil
end
local GOBO_GROUPS = { Gobo = true }
local function selectionTypes()
    local types, byKey = {}, {}
    local ok, idx = pcall(SelectionFirst)
    local guard = 0
    while ok and idx ~= nil and guard < 3000 do
        guard = guard + 1
        local key, name = typeOf(idx)
        if key then
            local t = byKey[key]
            if not t then
                if #types >= 6 then break end
                t = { name = name, fids = {}, sf = idx, key = key }
                byKey[key] = t; types[#types + 1] = t
            end
            local oks, sub = pcall(GetSubfixture, idx)
            local fid = oks and sub and tonumber(prop(sub, 'fid'))
            if fid then t.fids[#t.fids + 1] = fid end
        end
        ok, idx = pcall(SelectionNext, idx)
    end
    for _, t in ipairs(types) do
        if not typeCache[t.key] then typeCache[t.key] = attrsOf(t.sf, GOBO_GROUPS) end
        t.attrs = typeCache[t.key]
    end
    return types
end

-- nazwy i kolory (Appearance) obiektow pod executorami
local EXECS = {}
for _, base in ipairs({100, 200, 300, 400}) do for i = 1, COLUMNS do EXECS[#EXECS + 1] = base + i end end
for i = 1, 8 do EXECS[#EXECS + 1] = 190 + i; EXECS[#EXECS + 1] = 290 + i end   -- Xkeys

local dumped = false
local function firstNum(h, names)
    for _, n in ipairs(names) do
        local v = tonumber(prop(h, n))
        if v ~= nil then return v end
    end
    return nil
end
local function appearanceColor(obj)
    local ap = prop(obj, 'appearance')
    if ap == nil or type(ap) == 'string' or type(ap) == 'number' then return '' end
    local r = firstNum(ap, {'backr', 'back_r', 'colorr', 'r'})
    local g = firstNum(ap, {'backg', 'back_g', 'colorg', 'g'})
    local b = firstNum(ap, {'backb', 'back_b', 'colorb', 'b'})
    local a = firstNum(ap, {'backalpha', 'back_alpha', 'alpha', 'a'})
    if r == nil or g == nil or b == nil then
        if not dumped then
            dumped = true
            say('nie znam nazw kolorow Appearance - ponizej opis, przeslij zrzut:')
            pcall(function() ap:Dump() end)
        end
        return ''
    end
    if a ~= nil and a <= 0 then return '' end
    local m = math.max(r, g, b)
    local k = (m <= 1) and 255 or 1       -- 0..1 albo 0..255
    local function c(x) x = math.floor(x * k + 0.5); if x < 0 then x = 0 elseif x > 255 then x = 255 end; return x end
    return string.format('#%02x%02x%02x', c(r), c(g), c(b))
end
local function execInfo()
    local out, sig = {}, {}
    for _, n in ipairs(EXECS) do
        local name, col = '', ''
        local ok, ex = pcall(GetExecutor, n)
        if ok and ex ~= nil then
            local obj = prop(ex, 'object')
            if obj ~= nil and type(obj) ~= 'string' then
                name = clean(prop(obj, 'name'))
                col = appearanceColor(obj)
            end
            if name == '' then name = clean(prop(ex, 'name')) end
        end
        out[n] = name .. '|' .. col
        sig[#sig + 1] = out[n]
    end
    return out, table.concat(sig, ';')
end

-- zawartosc pul: grupy i presety (numer -> nazwa|kolor) + lista istniejacych numerow
local PRESET_POOLS = {2, 3, 6}       -- 2 = Position, 3 = Gobo, 6 = Focus
local POOL_MAX = 500
-- drugi sposob: bezposrednio z DataPool (gdy ObjectList nic nie zwraca)
local function viaDataPool(kind, t)
    local okd, dp = pcall(DataPool)
    if not okd or dp == nil then return {} end
    if kind == 'GRP' then return children(prop(dp, 'groups')) end
    local pp = prop(dp, 'presetpools')
    for _, pool in ipairs(children(pp)) do
        if tonumber(prop(pool, 'no')) == t then return children(pool) end
    end
    local ok, pool = pcall(function() return pp[t] end)
    if ok and pool ~= nil then return children(pool) end
    return {}
end
local poolCounts = {}
local function poolScan()
    local out, keys = {}, {}
    local function scan(prefix, query, kind, t)
        local nums = {}
        local ok, list = pcall(ObjectList, query)
        if not ok or type(list) ~= 'table' or #list == 0 then list = viaDataPool(kind, t); ok = true end
        if ok and type(list) == 'table' then
            for _, h in ipairs(list) do
                local no = tonumber(prop(h, 'no'))
                if no then
                    nums[#nums + 1] = no
                    out[prefix .. no] = clean(prop(h, 'name')) .. '|' .. appearanceColor(h)
                    keys[#keys + 1] = prefix .. no
                end
            end
        end
        table.sort(nums)
        poolCounts[prefix] = #nums
        out[prefix .. 'LIST'] = table.concat(nums, ',')
        keys[#keys + 1] = prefix .. 'LIST'
    end
    scan('GRP', 'Group 1 Thru ' .. POOL_MAX, 'GRP')
    for _, t in ipairs(PRESET_POOLS) do scan('PRE' .. t .. '.', 'Preset ' .. t .. '.1 Thru ' .. t .. '.' .. POOL_MAX, 'PRE', t) end
    local sig = {}
    for _, k in ipairs(keys) do sig[#sig + 1] = k .. '=' .. out[k] end
    return out, keys, table.concat(sig, ';')
end

-- ===== Layouty: elementy (pozycja, rozmiar, nazwa, adres obiektu, kolor) =====
local function addrOf(h)
    if h == nil or type(h) == 'string' or type(h) == 'number' then return '' end
    local ok, a = pcall(function() return h:ToAddr() end)
    if ok and type(a) == 'string' and a ~= '' then return a end
    ok, a = pcall(ToAddr, h)
    if ok and type(a) == 'string' then return a end
    return ''
end
local layoutDumped = false
local layoutCount, elementCount = 0, 0
local function layoutScan()
    local out, keys = {}, {}
    local function put(k, v) out[k] = v; keys[#keys + 1] = k end
    local list = {}
    local ok, l = pcall(ObjectList, 'Layout 1 Thru 999')
    if ok and type(l) == 'table' and #l > 0 then list = l
    else
        local okd, dp = pcall(DataPool)
        if okd and dp ~= nil then list = children(prop(dp, 'layouts')) end
    end
    local nums = {}
    elementCount = 0
    for _, lay in ipairs(list) do
        local no = tonumber(prop(lay, 'no'))
        if no then
            nums[#nums + 1] = no
            put('LAY' .. no, clean(prop(lay, 'name')) .. '|' .. appearanceColor(lay))
            local en = 0
            for _, e in ipairs(children(lay)) do
                if not layoutDumped then
                    -- diagnostyka: pelny opis pierwszego elementu, zeby poznac nazwy pozycji/rozmiaru
                    layoutDumped = true
                    say('opis pierwszego elementu layoutu ' .. no .. ' (przeslij zrzut):')
                    pcall(function() e:Dump() end)
                end
                local x = firstNum(e, {'posx', 'positionx', 'x'})
                local y = firstNum(e, {'posy', 'positiony', 'y'})
                if x == nil or y == nil then
                    -- brak pozycji: element pomijamy
                else
                    local w = firstNum(e, {'positionw', 'width', 'sizew', 'w'}) or 1
                    local hh = firstNum(e, {'positionh', 'height', 'sizeh', 'h'}) or 1
                    local obj = prop(e, 'object')
                    if type(obj) == 'string' or type(obj) == 'number' then obj = nil end
                    local addr = addrOf(obj)
                    local label = prop(e, 'name')
                    if (label == nil or label == '') and obj ~= nil then label = prop(obj, 'name') end
                    local col = appearanceColor(e)
                    if col == '' and obj ~= nil then col = appearanceColor(obj) end
                    en = en + 1
                    put('LAYEL' .. no .. '.' .. en, string.format('%g|%g|%g|%g|%s|%s|%s', x, y, w, hh, clean(label), clean(addr), col))
                end
            end
            put('LAYN' .. no, tostring(en))
            elementCount = elementCount + en
        end
    end
    table.sort(nums)
    layoutCount = #nums
    put('LAYLIST', table.concat(nums, ','))
    local sig = {}
    for _, k in ipairs(keys) do sig[#sig + 1] = k .. '=' .. out[k] end
    return out, keys, table.concat(sig, ';')
end

-- tekst w linii komend MA (nazwa wlasciwosci rozni sie miedzy wersjami - probujemy kilku)
local cmdProp = nil
local function cmdLine()
    local ok, co = pcall(CmdObj)
    if not ok or co == nil then return nil end
    local names = cmdProp and {cmdProp} or {'cmdtext', 'text', 'cmdline', 'input', 'commandline', 'edittext'}
    for _, n in ipairs(names) do
        local ok2, v = pcall(function() return co[n] end)
        if ok2 and type(v) == 'string' then cmdProp = n; return v end
    end
    return nil
end

-- ===== linia komend z iPada -> linia komend onPC (tylko podglad; komenda idzie przez OSC) =====
local function cmdlineFile()
    local dir = (os and os.getenv) and (os.getenv('TEMP') or os.getenv('TMP')) or nil
    return (dir or 'C:\\Windows\\Temp') .. '\\MA3Wing-cmdline.txt'
end
local mirrorMethod, mirrorFailed, mirrorAnnounced = nil, false, false
local clearKey = nil
-- aktualny tekst w linii komend MA
local function cmdText()
    local ok, co = pcall(CmdObj)
    if not ok or co == nil then return nil end
    for _, p in ipairs({'CmdText', 'cmdtext'}) do
        local okv, v = pcall(function() return co[p] end)
        if okv and type(v) == 'string' then return v end
    end
    return nil
end
-- wpisanie znakow wewnatrz MA (Keyboard), na chwile bez skrotow klawiszowych
local function typeChars(s)
    if s == '' then return end
    local sc, prev = nil, nil
    pcall(function() sc = CurrentProfile().KeyboardShortCuts; prev = sc.KeyboardShortcutsActive end)
    pcall(function() FindBestFocus(GetDisplayByIndex(1).CmdLineSection) end)
    if sc then pcall(function() sc.KeyboardShortcutsActive = false end) end
    for i = 1, #s do pcall(Keyboard, 1, 'char', s:sub(i, i)) end
    if sc and prev ~= nil then pcall(function() sc.KeyboardShortcutsActive = prev end) end
end
local function pressKey(k)
    pcall(Keyboard, 1, 'press', k); pcall(Keyboard, 1, 'release', k)
end
-- czyszczenie linii komend: Esc (nazwe klawisza trzeba odgadnac), w razie potrzeby Backspace
local function clearLine()
    local cur = cmdText()
    if cur == nil or cur == '' then return true end
    pcall(function() FindBestFocus(GetDisplayByIndex(1).CmdLineSection) end)
    local tries = clearKey and {clearKey} or {'Escape', 'Esc', 'ESCAPE', 'escape', 'Backspace', 'BackSpace', 'Back'}
    for _, k in ipairs(tries) do
        if k:lower():find('back') then
            for _ = 1, #cur do pressKey(k) end
        else
            pressKey(k)
        end
        coroutine.yield(0.05)
        local now = cmdText()
        if now == '' then clearKey = k; return true end
    end
    return false
end
local function setCmdLine(text)
    if mirrorFailed then return end
    if type(Keyboard) ~= 'function' then mirrorFailed = true; say('brak funkcji Keyboard - podglad linii komend wylaczony'); return end
    local cur = cmdText()
    if cur == nil then mirrorFailed = true; say('nie moge odczytac CmdObj().CmdText - podglad linii komend wylaczony'); return end
    if cur == text then return end
    if text:sub(1, #cur) == cur then
        typeChars(text:sub(#cur + 1))
    else
        if not clearLine() then
            say('nie umiem wyczyscic linii komend (sprobowano Escape/Backspace) - przeslij zrzut')
            mirrorFailed = true
            return
        end
        typeChars(text)
    end
    coroutine.yield(0.05)
    local now = cmdText()
    if not mirrorAnnounced and text ~= '' then
        mirrorAnnounced = true
        if now == text then say('podglad linii komend z iPada: OK' .. (clearKey and (' (czyszczenie: ' .. clearKey .. ')') or ''))
        else say('podglad linii komend: wpisalem "' .. text .. '", MA pokazuje "' .. tostring(now) .. '"') end
    end
end
-- Esc z iPada: plik MA3Wing-esc.txt zmienia zawartosc -> naciskamy Esc w MA (zamyka okna / pop-upy)
local lastEsc = nil
local function escTick()
    local dir = (os and os.getenv) and (os.getenv('TEMP') or os.getenv('TMP')) or nil
    local f = io.open((dir or 'C:\\Windows\\Temp') .. '\\MA3Wing-esc.txt', 'r')
    if not f then return end
    local t = f:read('*a') or ''
    f:close()
    if lastEsc == nil then lastEsc = t; return end      -- stary stan z poprzedniej sesji - ignoruj
    if t ~= lastEsc then
        lastEsc = t
        local k = clearKey or 'Escape'
        pcall(Keyboard, 1, 'press', k); pcall(Keyboard, 1, 'release', k)
    end
end
local lastMirror = nil
local function mirrorTick()
    local f = io.open(cmdlineFile(), 'r')
    if not f then return end
    local t = f:read('*a') or ''
    f:close()
    t = t:gsub('[\r\n]', '')
    if t ~= lastMirror then
        lastMirror = t
        local ok, err = pcall(setCmdLine, t)
        if not ok then say('linia komend: ' .. tostring(err)); mirrorFailed = true end
    end
end

-- wszystkie dane jako lista {klucz, wartosc}
local function stateLines(page, vals, attrs, execs, cmd, pools, poolKeys, lays, layKeys, sel, types)
    local L = {}
    local function put(k, v) L[#L + 1] = {k, tostring(v)} end
    for _, base in ipairs(ROWS) do
        for i = 1, COLUMNS do local n = base + i; put('/Page' .. page .. '/Fader' .. n, vals[n] or 0) end
    end
    for _, n in ipairs(EXECS) do if execs and execs[n] then put('EXEC' .. n, execs[n]) end end
    if cmd ~= nil then put('CMDLINE', clean(cmd)) end
    if pools and poolKeys then for _, k in ipairs(poolKeys) do put(k, pools[k]) end end
    if lays and layKeys then for _, k in ipairs(layKeys) do put(k, lays[k]) end end
    if sel ~= nil then put('SEL', sel) end
    if types ~= nil then
        put('TYPEN', #types)
        for i, t in ipairs(types) do
            put('TYPE' .. i, clean(t.name) .. '|' .. table.concat(t.fids, ','))
            put('TATTRN' .. i, #t.attrs)
            for j, a in ipairs(t.attrs) do
                put('TATTR' .. i .. '.' .. j, a[1] .. '|' .. a[2] .. '|' .. a[3] .. '|' .. (a[4] or '') .. '|' .. (a[5] or '') .. '|' .. (a[6] or ''))
            end
        end
    end
    attrs = attrs or {}
    put('ATTRN', #attrs)
    for i, a in ipairs(attrs) do
        put('ATTR' .. i, a[1] .. '|' .. a[2] .. '|' .. a[3] .. '|' .. (a[4] or '') .. '|' .. (a[5] or '') .. '|' .. (a[6] or ''))
    end
    return L
end
local function writeState(file, ...)
    local f, err = io.open(file, 'w')
    if not f then return false, err end
    for _, kv in ipairs(stateLines(...)) do f:write(kv[1], '=', kv[2], '\n') end
    f:write('END\n')
    f:close()
    return true
end
-- ===== tryb sieciowy (konsola): tylko zmiany, paczkami przez SendOSC "/ma3wing,s,..." =====
local netLast = {}
local function enc(s) return (s:gsub('[%%,";\r\n\\]', function(c) return string.format('%%%02X', c:byte()) end)) end
local function netSendRaw(payload)
    local ok, r = pcall(Cmd, string.format('SendOSC %d "/ma3wing,s,%s"', OSC_LINE, payload))
    return ok
end
local function netSend(L)
    local chunk, sent = {}, 0
    local size = 0
    local function flush()
        if #chunk == 0 then return end
        netSendRaw(table.concat(chunk, '%0A'))
        chunk, size = {}, 0
        sent = sent + 1
        if sent % 15 == 0 then coroutine.yield(0.02) end   -- nie zatykaj konsoli przy pierwszym wysylaniu
    end
    for _, kv in ipairs(L) do
        local k, v = kv[1], kv[2]
        if k:sub(1, 5) ~= '/Page' and k ~= 'CMDLINE' and netLast[k] ~= v then   -- fadery wysyla sama konsola (OSC Send)
            netLast[k] = v
            local item = enc(k .. '=' .. v)
            if size + #item > 700 then flush() end
            chunk[#chunk + 1] = item; size = size + #item + 3
        end
    end
    flush()
    return sent
end

local function run()
    -- diagnostyka: czego brakuje w tej wersji MA
    if type(GetExecutor) ~= 'function' then say('BLAD: brak funkcji GetExecutor'); return end
    if type(coroutine) ~= 'table' or type(coroutine.yield) ~= 'function' then say('BLAD: brak coroutine.yield'); return end

    -- zatrzymaj wszystkie starsze wersje tej wtyczki (takze te z SendOSC)
    MA3WingSyncRunning = false
    local token = {}
    MA3WingToken = token          -- kazde klikniecie przejmuje sterowanie; starsza petla sama sie konczy

    local file = stateFile()
    local net = FORCE_NET
    if not net then
        local okw, errw = false, 'brak biblioteki io'
        if type(io) == 'table' and type(io.open) == 'function' then okw, errw = writeState(file, pageNumber(), {}) end
        if not okw then net = true; say('nie moge zapisac pliku (' .. tostring(errw) .. ') - przechodze na tryb sieciowy') end
    end
    if net then
        netLast = {}
        netSendRaw(enc('HELLO=1'))
        say('start (v21), TRYB SIECIOWY: SendOSC przez linie OSC ' .. OSC_LINE .. ' (ustaw w niej IP laptopa z mostem, Send=Yes)')
    else
        say('start (v21), plik: ' .. file .. ', fader 201 = ' .. tostring(faderValue(201)))
    end

    local last, lastPage, lastSig, attrs = {}, nil, nil, {}
    local tick = 0
    local execs, lastExecSig = {}, nil
    local cmd, lastCmd = nil, nil
    local pools, poolKeys, lastPoolSig = {}, {}, nil
    local lays, layKeys, lastLaySig = {}, {}, nil
    local sel, types = nil, nil
    while MA3WingToken == token do
        local page = pageNumber()
        local changed = (page ~= lastPage)
        tick = tick + 1
        if tick % 3 == 1 then                       -- zaznaczenie sprawdzamy co ~0.3 s
            local l, sig = attrList()
            if sig ~= lastSig then attrs, lastSig, changed = l, sig, true end
            local s = selectionList()
            if s ~= sel then sel, changed = s, true; types = selectionTypes() end
        end
        if not net then mirrorTick(); escTick() end
        cmd = cmdLine()
        if cmd ~= lastCmd then lastCmd, changed = cmd, true end
        if tick % 50 == 3 then                      -- layouty co ~5 s
            local lo, lk, lsig = layoutScan()
            if lastLaySig == nil then say(string.format('layouty: %d, elementow: %d', layoutCount, elementCount)) end
            if lsig ~= lastLaySig then lays, layKeys, lastLaySig, changed = lo, lk, lsig, true end
        end
        if tick % 20 == 2 then                      -- pule grup i presetow co ~2 s
            local pl, pk, psig = poolScan()
            if lastPoolSig == nil then
                say(string.format('pule: grupy=%d, presety Position=%d, Focus=%d',
                    poolCounts['GRP'] or 0, poolCounts['PRE2.'] or 0, poolCounts['PRE6.'] or 0))
            end
            if psig ~= lastPoolSig then pools, poolKeys, lastPoolSig, changed = pl, pk, psig, true end
        end
        if tick % 10 == 1 then                      -- nazwy i kolory co ~1 s
            local e, esig = execInfo()
            if esig ~= lastExecSig then execs, lastExecSig, changed = e, esig, true end
        end
        local vals = {}
        for _, base in ipairs(ROWS) do
            for i = 1, COLUMNS do
                local n = base + i
                local v = math.floor(faderValue(n) + 0.5)
                vals[n] = v
                if last[n] ~= v then changed = true end
            end
        end
        if changed then
            local ok, err
            if net then
                ok = true
                netSend(stateLines(page, vals, attrs, execs, cmd, pools, poolKeys, lays, layKeys, sel, types))
            else
                ok, err = writeState(file, page, vals, attrs, execs, cmd, pools, poolKeys, lays, layKeys, sel, types)
            end
            if ok then
                last, lastPage = vals, page
            else
                say('nie moge zapisac pliku: ' .. tostring(err))
                coroutine.yield(2)
            end
        end
        coroutine.yield(PERIOD)
    end
end

return function()
    local ok, err = pcall(run)
    if not ok then
        say('BLAD: ' .. tostring(err))
    end
end
