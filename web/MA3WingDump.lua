-- MA3 Wing Dump v3: co MA wie o presetach Gobo (pula 3) - obrazek, zawartosc, typy urzadzen.
-- Uzycie: kliknij plugin (nic nie trzeba zaznaczac), przeslij plik MA3Wing-presety.txt z folderu MA3.

local function say(t) if Printf then Printf('MA3 Wing Dump: ' .. t) else print('MA3 Wing Dump: ' .. t) end end
local function isHandle(v) return v ~= nil and (type(v) == 'userdata' or (type(v) == 'table' and v.Children ~= nil)) end

local function outPath()
    local tries = {}
    if os and os.getenv then
        local up = os.getenv('USERPROFILE')
        if up then
            tries[#tries + 1] = up .. '\\OneDrive\\Desktop\\MA3\\MA3Wing-presety.txt'
            tries[#tries + 1] = up .. '\\Desktop\\MA3Wing-presety.txt'
        end
        local t = os.getenv('TEMP') or os.getenv('TMP')
        if t then tries[#tries + 1] = t .. '\\MA3Wing-presety.txt' end
    end
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
    end
    return table.concat(parts, '  ')
end
local function class(h) local ok, c = pcall(function() return h:GetClass() end); return ok and tostring(c) or '?' end
local function children(h) local ok, c = pcall(function() return h:Children() end); if ok and type(c) == 'table' then return c end; return {} end

local lines = {}
local function w(t) lines[#lines + 1] = t end
local function get(h, k)
    for _, n in ipairs({k, k:lower(), k:upper()}) do
        local ok, v = pcall(function() return h[n] end)
        if ok and v ~= nil then return v end
        ok, v = pcall(function() return h:Get(n) end)
        if ok and v ~= nil then return v end
    end
    return nil
end
local function tree(h, ind, depth, maxDepth, maxKids)
    w(ind .. '[' .. class(h) .. '] ' .. props(h))
    if depth >= maxDepth then return end
    local kids = children(h)
    for i, c in ipairs(kids) do
        if i > maxKids then w(ind .. '    ... (' .. #kids .. ' dzieci)'); break end
        tree(c, ind .. '    ', depth + 1, maxDepth, maxKids)
    end
end

local function run()
    local okv, ver = pcall(Version)
    w('MA3 Wing Dump v4 (presety Gobo)  ' .. os.date('%Y-%m-%d %H:%M:%S') .. '  wersja MA: ' .. (okv and tostring(ver) or '?'))
    lines = {}
    local okl, list = pcall(ObjectList, 'Preset 3.1 Thru 3.1000')
    if not okl or type(list) ~= 'table' then list = {} end
    if #list == 0 then                                  -- jak w glownej wtyczce: bezposrednio z DataPool
        local okd, dp = pcall(DataPool)
        local pp = okd and dp and get(dp, 'PresetPools') or nil
        if isHandle(pp) then
            for _, pool in ipairs(children(pp)) do
                if tonumber(get(pool, 'No')) == 3 then list = children(pool) end
            end
            if #list == 0 then local ok3, pool = pcall(function() return pp[3] end); if ok3 and isHandle(pool) then list = children(pool) end end
        end
        w('(ObjectList pusty - odczyt z DataPool: ' .. #list .. ')')
    end
    w('== Pula 3: ' .. #list .. ' presetow')
    for _, p in ipairs(list) do w(props(p)) end
    local want = { [2] = true, [3] = true, [145] = true, [146] = true, [180] = true, [181] = true, [201] = true, [202] = true, [216] = true, [217] = true }
    local picks = {}
    for _, p in ipairs(list) do
        local okn, no = pcall(function() return p.no end)
        no = okn and tonumber(no) or nil
        if no and want[no] then picks[#picks + 1] = p end
    end
    if #picks == 0 then for i = 1, math.min(4, #list) do picks[#picks + 1] = list[i] end end
    -- zawartosc presetow: SELECTIONDATA, DEPENDENCIES i GetPresetData (wartosci per urzadzenie / atrybut)
    local function dumpTable(t, ind, depth, budget)
        if budget.n <= 0 then return end
        if type(t) ~= 'table' then w(ind .. str(t)); budget.n = budget.n - 1; return end
        local keys = {}
        for k, _ in pairs(t) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for i, k in ipairs(keys) do
            if budget.n <= 0 then w(ind .. '...'); return end
            if i > 40 then w(ind .. '... (' .. #keys .. ' kluczy)'); return end
            local v = t[k]
            if type(v) == 'table' and depth > 0 then
                w(ind .. tostring(k) .. ' = {'); budget.n = budget.n - 1
                dumpTable(v, ind .. '  ', depth - 1, budget)
                w(ind .. '}')
            else
                w(ind .. tostring(k) .. ' = ' .. str(v)); budget.n = budget.n - 1
            end
        end
    end
    for _, p in ipairs(picks) do
        w(''); w('---------- ' .. str(p))
        for _, key in ipairs({'SELECTIONDATA', 'DEPENDENCIES'}) do
            local v = get(p, key)
            w('  ' .. key .. ':'); dumpTable(v, '    ', 4, {n = 120})
        end
        if type(GetPresetData) == 'function' then
            for _, args in ipairs({{}, {false, true}}) do
                local ok, d = pcall(GetPresetData, p, table.unpack(args))
                w('  GetPresetData(' .. table.concat((function() local s = {} for _, a in ipairs(args) do s[#s + 1] = tostring(a) end return s end)(), ',') .. '): ' .. (ok and '' or ('BLAD ' .. tostring(d))))
                if ok then dumpTable(d, '    ', 5, {n = 250}) end
            end
        else
            w('  (brak funkcji GetPresetData)')
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
