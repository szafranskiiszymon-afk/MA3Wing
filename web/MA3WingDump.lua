-- MA3 Wing Dump: zapisuje do pliku tekstowego wszystko, co MA wie o atrybutach
-- PIERWSZEGO zaznaczonego urzadzenia: UIChannel, Attribute, Logical channel,
-- Channel functions i Channel sets (ze wszystkimi wlasciwosciami).
-- Uzycie: zaznacz jedno urzadzenie (np. Fixture 101), kliknij plugin, przeslij plik.

local function say(t) if Printf then Printf('MA3 Wing Dump: ' .. t) else print('MA3 Wing Dump: ' .. t) end end

local function isHandle(v) return v ~= nil and (type(v) == 'userdata' or (type(v) == 'table' and v.Children ~= nil)) end

local function outPath()
    local tries = {}
    if os and os.getenv then
        local up = os.getenv('USERPROFILE')
        if up then
            tries[#tries + 1] = up .. '\\OneDrive\\Desktop\\MA3\\MA3Wing-channelsets.txt'
            tries[#tries + 1] = up .. '\\Desktop\\MA3Wing-channelsets.txt'
        end
        local t = os.getenv('TEMP') or os.getenv('TMP')
        if t then tries[#tries + 1] = t .. '\\MA3Wing-channelsets.txt' end
    end
    tries[#tries + 1] = 'C:\\Windows\\Temp\\MA3Wing-channelsets.txt'
    for _, p in ipairs(tries) do
        local f = io.open(p, 'w')
        if f then return f, p end
    end
    return nil, nil
end

local function str(v)
    if v == nil then return 'nil' end
    if isHandle(v) then
        local ok, a = pcall(function() return v:ToAddr() end)
        local okn, n = pcall(function() return v.name end)
        return '<obj ' .. (ok and tostring(a) or '?') .. ' "' .. (okn and tostring(n) or '') .. '">'
    end
    return tostring(v)
end

-- wszystkie wlasciwosci obiektu MA (PropertyCount/PropertyName), w jednej linii
local function props(h)
    local parts = {}
    local okc, cnt = pcall(function() return h:PropertyCount() end)
    if okc and type(cnt) == 'number' then
        for i = 0, cnt - 1 do
            local okn, name = pcall(function() return h:PropertyName(i) end)
            if okn and name then
                local okv, val = pcall(function() return h:Get(name) end)
                if not okv or val == nil then okv, val = pcall(function() return h[name] end) end
                parts[#parts + 1] = tostring(name) .. '=' .. str(okv and val or nil)
            end
        end
    else
        for _, k in ipairs({'name', 'no', 'dmxfrom', 'dmxto', 'physfrom', 'physto', 'attribute', 'wheel', 'default'}) do
            local ok, v = pcall(function() return h[k] end)
            if ok and v ~= nil then parts[#parts + 1] = k .. '=' .. str(v) end
        end
    end
    return table.concat(parts, '  ')
end

local function class(h)
    local ok, c = pcall(function() return h:GetClass() end)
    return ok and tostring(c) or '?'
end

local function children(h)
    local ok, c = pcall(function() return h:Children() end)
    if ok and type(c) == 'table' then return c end
    return {}
end

local lines = {}
local function w(t) lines[#lines + 1] = t end

local function tree(h, ind, depth, maxDepth)
    w(ind .. '[' .. class(h) .. '] ' .. props(h))
    if depth >= maxDepth then return end
    for _, c in ipairs(children(h)) do tree(c, ind .. '    ', depth + 1, maxDepth) end
end

local function run()
    local okv, ver = pcall(Version)
    w('MA3 Wing Dump  ' .. os.date('%Y-%m-%d %H:%M:%S') .. '  wersja MA: ' .. (okv and tostring(ver) or '?'))
    local ok, sf = pcall(SelectionFirst)
    if not ok or sf == nil then say('BLAD: nic nie jest zaznaczone. Zaznacz jedno urzadzenie i uruchom ponownie.'); return end
    w('SelectionFirst = ' .. tostring(sf))

    local oks, sub = pcall(GetSubfixture, sf)
    if oks and isHandle(sub) then
        w(''); w('== Subfixture'); w(props(sub))
        local okt, ft = pcall(function() return sub.fixturetype end)
        if okt and isHandle(ft) then w('fixture type: ' .. str(ft)) end
    end

    local okc, chans = pcall(GetUIChannels, sf)
    if not okc or type(chans) ~= 'table' then say('BLAD: GetUIChannels nie dziala'); return end
    w(''); w('== UI channels: ' .. #chans)

    local seenLC = {}
    for idx, ui in ipairs(chans) do
        w(''); w('---------- UIChannel ' .. tostring(ui) .. ' (#' .. idx .. ')')
        local oka, a = pcall(GetAttributeByUIChannel, ui)
        if oka and isHandle(a) then w('Attribute: ' .. props(a)) end
        local oku, u = pcall(GetUIChannel, ui)
        local lc = nil
        if oku and u ~= nil then
            if type(u) == 'table' then
                local keys = {}
                for k, v in pairs(u) do keys[#keys + 1] = tostring(k) .. '=' .. str(v) end
                table.sort(keys)
                w('GetUIChannel: ' .. table.concat(keys, '  '))
                for _, k in ipairs({'logical_channel', 'logicalchannel', 'LogicalChannel'}) do
                    if isHandle(u[k]) then lc = u[k]; break end
                end
            elseif isHandle(u) then
                w('GetUIChannel (obiekt): ' .. props(u))
                local okl, l = pcall(function() return u.logicalchannel or u.logical_channel end)
                if okl and isHandle(l) then lc = l end
            end
        else
            w('GetUIChannel: brak')
        end
        if lc ~= nil then
            local key = str(lc)
            if seenLC[key] then
                w('Logical channel ' .. key .. ' (juz opisany wyzej)')
            else
                seenLC[key] = true
                w('Logical channel -> channel functions -> channel sets:')
                tree(lc, '  ', 0, 3)
            end
        else
            w('Logical channel: NIE ZNALEZIONY')
        end
    end

    local f, path = outPath()
    if not f then say('BLAD: nie moge zapisac pliku'); return end
    f:write(table.concat(lines, '\r\n'), '\r\n')
    f:close()
    say('zapisano ' .. #lines .. ' linii do: ' .. path)
end

return function()
    local ok, err = pcall(run)
    if not ok then say('BLAD: ' .. tostring(err)) end
end
