-- MA3 Wing sync: wysyla pozycje faderow (2xx) i galek (3xx, 4xx) z aktualnej strony
-- przez OSC do mostu MA3 Wing na laptopie. Uruchom raz (klik na plugin w puli).
-- Ponowne klikniecie = wyslij wszystko jeszcze raz.

local OSC_LINE = 3        -- NUMER linii OSC w In & Out > OSC, ktora ma Send = Yes (port 9000)
local COLUMNS  = 15       -- ile kolumn executorow sprawdzac (x01..x15)
local PERIOD   = 0.1      -- co ile sekund sprawdzac zmiany

local ROWS = {200, 300, 400}

local function send(addr, v)
    Cmd(string.format('SendOSC %d "%s,i,%d"', OSC_LINE, addr, v))
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

return function()
    if MA3WingSyncRunning then
        MA3WingForceResend = true
        Printf('MA3 Wing sync: wysylam wszystko ponownie')
        return
    end
    MA3WingSyncRunning = true
    MA3WingForceResend = false
    Printf('MA3 Wing sync: start (linia OSC ' .. OSC_LINE .. ')')

    local last, lastPage = {}, nil
    while MA3WingSyncRunning do
        local page = pageNumber()
        if page ~= lastPage or MA3WingForceResend then
            last, lastPage, MA3WingForceResend = {}, page, false
        end
        for _, base in ipairs(ROWS) do
            for i = 1, COLUMNS do
                local n = base + i
                local v = math.floor(faderValue(n) + 0.5)
                if last[n] ~= v then
                    last[n] = v
                    send('/Page' .. page .. '/Fader' .. n, v)
                end
            end
        end
        coroutine.yield(PERIOD)
    end
end
