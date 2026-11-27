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

local function writeState(file, page, vals, attrs)
    local f, err = io.open(file, 'w')
    if not f then return false, err end
    for _, base in ipairs(ROWS) do
        for i = 1, COLUMNS do
            local n = base + i
            f:write('/Page', page, '/Fader', n, '=', vals[n] or 0, '\n')
        end
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

    say('start (v4), plik: ' .. file .. ', fader 201 = ' .. tostring(faderValue(201)))

    local last, lastPage, lastSig, attrs = {}, nil, nil, {}
    local tick = 0
    while MA3WingToken == token do
        local page = pageNumber()
        local changed = (page ~= lastPage)
        tick = tick + 1
        if tick % 3 == 1 then                       -- zaznaczenie sprawdzamy co ~0.3 s
            local l, sig = attrList()
            if sig ~= lastSig then attrs, lastSig, changed = l, sig, true end
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
            local ok, err = writeState(file, page, vals, attrs)
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
