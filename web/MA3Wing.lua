-- MA3 Wing sync: zapisuje pozycje faderow (2xx) i galek (3xx, 4xx) z aktualnej strony
-- do pliku tymczasowego, ktory czyta most MA3 Wing na tym samym laptopie.
-- Uruchom raz (klik na plugin w puli). Ponowne klikniecie = restart i zapis wszystkiego od nowa.

local COLUMNS = 15        -- ile kolumn executorow sprawdzac (x01..x15)
local PERIOD  = 0.1       -- co ile sekund sprawdzac zmiany
local ROWS = {200, 300, 400}

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

-- atrybuty pierwszego zaznaczonego urzadzenia: { {grupa, nazwa, ladna nazwa}, ... }
local function attrList()
    local list = {}
    local ok, sf = pcall(SelectionFirst)
    if not ok or sf == nil then return list, 'none' end
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
                list[#list + 1] = { grp, name, pretty }
            end
        end
    end
    return list, tostring(sf) .. ':' .. #list
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
local function clean(t) return (tostring(t or ''):gsub('[|=\r\n]', ' ')) end
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
local PRESET_POOLS = {2, 6}          -- 2 = Position, 6 = Focus
local POOL_MAX = 500
local function children(h)
    if h == nil or type(h) == 'string' then return {} end
    local ok, c = pcall(function() return h:Children() end)
    if ok and type(c) == 'table' then return c end
    return {}
end
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

local function writeState(file, page, vals, attrs, execs, cmd, pools, poolKeys)
    local f, err = io.open(file, 'w')
    if not f then return false, err end
    for _, base in ipairs(ROWS) do
        for i = 1, COLUMNS do
            local n = base + i
            f:write('/Page', page, '/Fader', n, '=', vals[n] or 0, '\n')
        end
    end
    for _, n in ipairs(EXECS) do
        if execs and execs[n] then f:write('EXEC', n, '=', execs[n], '\n') end
    end
    if cmd ~= nil then f:write('CMDLINE=', clean(cmd), '\n') end
    if pools and poolKeys then
        for _, k in ipairs(poolKeys) do f:write(k, '=', pools[k], '\n') end
    end
    attrs = attrs or {}
    f:write('ATTRN=', #attrs, '\n')
    for i, a in ipairs(attrs) do
        f:write('ATTR', i, '=', a[1], '|', a[2], '|', a[3], '\n')
    end
    f:write('END\n')
    f:close()
    return true
end

local function run()
    -- diagnostyka: czego brakuje w tej wersji MA
    if type(io) ~= 'table' or type(io.open) ~= 'function' then say('BLAD: brak biblioteki io (zapis plikow zablokowany)'); return end
    if type(GetExecutor) ~= 'function' then say('BLAD: brak funkcji GetExecutor'); return end
    if type(coroutine) ~= 'table' or type(coroutine.yield) ~= 'function' then say('BLAD: brak coroutine.yield'); return end

    -- zatrzymaj wszystkie starsze wersje tej wtyczki (takze te z SendOSC)
    MA3WingSyncRunning = false
    local token = {}
    MA3WingToken = token          -- kazde klikniecie przejmuje sterowanie; starsza petla sama sie konczy

    local file = stateFile()
    local okw, errw = writeState(file, pageNumber(), {})
    if not okw then say('BLAD: nie moge zapisac ' .. file .. ' (' .. tostring(errw) .. ')'); return end

    say('start (v9), plik: ' .. file .. ', fader 201 = ' .. tostring(faderValue(201)))

    local last, lastPage, lastSig, attrs = {}, nil, nil, {}
    local tick = 0
    local execs, lastExecSig = {}, nil
    local cmd, lastCmd = nil, nil
    local pools, poolKeys, lastPoolSig = {}, {}, nil
    while MA3WingToken == token do
        local page = pageNumber()
        local changed = (page ~= lastPage)
        tick = tick + 1
        if tick % 3 == 1 then                       -- zaznaczenie sprawdzamy co ~0.3 s
            local l, sig = attrList()
            if sig ~= lastSig then attrs, lastSig, changed = l, sig, true end
        end
        cmd = cmdLine()
        if cmd ~= lastCmd then lastCmd, changed = cmd, true end
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
            local ok, err = writeState(file, page, vals, attrs, execs, cmd, pools, poolKeys)
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
