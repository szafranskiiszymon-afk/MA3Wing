-- MA3 Wing sync: zapisuje pozycje faderow (2xx) i galek (3xx, 4xx) z aktualnej strony
-- do pliku tymczasowego, ktory czyta most MA3 Wing na tym samym laptopie.
-- Uruchom raz (klik na plugin w puli). Ponowne klikniecie = zapisz wszystko jeszcze raz.

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

local function writeState(file, page, vals)
    local f, err = io.open(file, 'w')
    if not f then return false, err end
    for _, base in ipairs(ROWS) do
        for i = 1, COLUMNS do
            local n = base + i
            f:write('/Page', page, '/Fader', n, '=', vals[n] or 0, '\n')
        end
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

    if MA3WingSyncRunning then
        MA3WingForceResend = true
        say('zapisuje wszystko ponownie')
        return
    end

    local file = stateFile()
    local okw, errw = writeState(file, pageNumber(), {})
    if not okw then say('BLAD: nie moge zapisac ' .. file .. ' (' .. tostring(errw) .. ')'); return end

    MA3WingSyncRunning = true
    MA3WingForceResend = true
    say('start, plik: ' .. file .. ', fader 201 = ' .. tostring(faderValue(201)))

    local last, lastPage = {}, nil
    while MA3WingSyncRunning do
        local page = pageNumber()
        local changed = (page ~= lastPage) or MA3WingForceResend
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
            local ok, err = writeState(file, page, vals)
            if ok then
                last, lastPage, MA3WingForceResend = vals, page, false
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
        MA3WingSyncRunning = false
        say('BLAD: ' .. tostring(err))
    end
end
