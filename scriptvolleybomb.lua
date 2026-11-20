--=====================================================================
--  VOLLEY BOMB  ·  Trajectory Predictor + Landing Marker + Aim Tools
--  Plataforma : PC          Executor : Solara
--  UI         : [RightShift] abre/cierra   |   [F] activa/desactiva
--=====================================================================
--[[
  CÓMO USAR
  1. Entra a una partida de Volley Bomb y ejecuta el script con Solara.
  2. Abre el menú con RightShift.
  3. Activa "Trayectoria" y "Aro de caída".
  4. Ajusta grosor / pasos / radio a tu gusto en el menú.

  Si el balón no se detecta, agrega su nombre exacto en CONFIG.BallNames
  (abajo) y vuelve a ejecutar.
]]

if getgenv().VB_Unload then pcall(getgenv().VB_Unload) end

local Players   = game:GetService("Players")
local RunService= game:GetService("RunService")
local UIS       = game:GetService("UserInputService")
local WS        = game:GetService("Workspace")
local VIM       = game:GetService("VirtualInputManager")

local LP = Players.LocalPlayer

--=====================================================================
-- CONFIG
--=====================================================================
local CONFIG = {
    BallNames      = { "ball", "volley", "bomb", "pelota" }, -- coincidencias por nombre
    MaxBallDist    = 350,     -- studs: ignora balones más lejos
    ScanInterval   = 0.4,     -- seg entre re-escaneos del mapa
    DragDefault    = 0.015,   -- resistencia del aire (0 = ninguna)
}

local State = {
    Enabled      = true,
    MenuOpen     = true,
    Trajectory   = true,
    LandingRing  = true,
    PlumbLine    = true,
    ImpactText   = true,
    BallESP      = true,
    AutoHit      = false,
    AutoAim      = false,
    Thickness    = 2,
    Steps        = 160,
    RingRadius   = 5,
    HitRange     = 15,
    Drag         = CONFIG.DragDefault,
    Accent       = Color3.fromRGB(0, 200, 255),
}

local Connections = {}
local function bind(signal, fn)
    local c = signal:Connect(fn)
    table.insert(Connections, c)
    return c
end

--=====================================================================
-- DRAWING POOL
--=====================================================================
if not Drawing then
    return warn("[VolleyBomb] Este executor no tiene la librería Drawing.")
end

local MAX_SEG = 420
local MAX_RING = 48
local SegLines, RingLines = {}, {}
local ImpactText = Drawing.new("Text")
local PlumbLine  = Drawing.new("Line")

for i = 1, MAX_SEG do
    local l = Drawing.new("Line")
    l.Visible, l.Thickness, l.Transparency = false, 2, 0.2
    SegLines[i] = l
end
for i = 1, MAX_RING do
    local l = Drawing.new("Line")
    l.Visible, l.Thickness, l.Transparency = false, 2, 0.1
    RingLines[i] = l
end

ImpactText.Visible = false
ImpactText.Center  = true
ImpactText.Outline = true
ImpactText.Font    = Enum.Font.GothamBold
ImpactText.Size    = 16

PlumbLine.Visible, PlumbLine.Thickness, PlumbLine.Transparency = false, 1, 0.5

local function hideAll()
    for _, l in ipairs(SegLines) do l.Visible = false end
    for _, l in ipairs(RingLines) do l.Visible = false end
    ImpactText.Visible = false
    PlumbLine.Visible = false
end

--=====================================================================
-- DETECCIÓN DE BALÓN
--=====================================================================
local ballList = {}
local lastScan = 0
local espHighlight = nil
local espBall = nil

local function isBall(inst)
    if not inst:IsA("BasePart") then return false end
    local n = inst.Name:lower()
    for _, pat in ipairs(CONFIG.BallNames) do
        if n:find(pat, 1, true) then return true end
    end
    local p = inst.Parent
    if p then
        local pn = p.Name:lower()
        for _, pat in ipairs(CONFIG.BallNames) do
            if pn:find(pat, 1, true) then return true end
        end
    end
    return false
end

local function scanBalls()
    if tick() - lastScan < CONFIG.ScanInterval then return end
    lastScan = tick()
    ballList = {}
    for _, d in ipairs(WS:GetDescendants()) do
        if isBall(d) then ballList[#ballList + 1] = d end
    end
end

local function getBall()
    scanBalls()
    local cam = WS.CurrentCamera
    if not cam then return nil end
    local origin = cam.CFrame.Position
    local best, bestD = nil, CONFIG.MaxBallDist
    for _, b in ipairs(ballList) do
        if b.Parent and b:IsA("BasePart") then
            local d = (b.Position - origin).Magnitude
            if d < bestD then best, bestD = b, d end
        end
    end
    return best
end

--=====================================================================
-- SIMULACIÓN DE TRAYECTORIA
--=====================================================================
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function refreshFilter()
    local list = {}
    if LP.Character then table.insert(list, LP.Character) end
    for _, b in ipairs(ballList) do table.insert(list, b) end
    rayParams.FilterDescendantsInstances = list
end

local function predict(ball)
    local pts = {}
    local pos = ball.Position
    local vel = ball.AssemblyLinearVelocity
    if vel.Magnitude < 2 then return pts end

    local dt    = 1 / 60
    local steps = math.clamp(math.floor(State.Steps), 20, MAX_SEG - 20)
    local g     = WS.Gravity

    for i = 1, steps do
        vel = vel * (1 - State.Drag * dt)
        vel = vel - Vector3.new(0, g * dt, 0)
        local nextPos = pos + vel * dt
        local dir = nextPos - pos
        if dir.Magnitude > 0.001 then
            local hit = WS:Raycast(pos, dir, rayParams)
            if hit then
                pts[#pts + 1] = hit.Position
                return pts, hit.Position, hit.Normal, i * dt
            end
        end
        pts[#pts + 1] = nextPos
        pos = nextPos
    end
    return pts
end

--=====================================================================
-- AUTO HIT / AUTO AIM
--=====================================================================
local lastHit = 0
local function tryAutoHit(ball, tti)
    if not State.AutoHit then return end
    if tick() - lastHit < 0.28 then return end
    local char = LP.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    if (ball.Position - hrp.Position).Magnitude > State.HitRange then return end
    if tti and tti > 0.8 then return end

    lastHit = tick()
    task.spawn(function()
        local cam = WS.CurrentCamera
        if not cam then return end
        local vp = cam:WorldToViewportPoint(ball.Position)
        VIM:SendMouseButtonEvent(vp.X, vp.Y, 0, true,  game, 1)
        task.wait(0.03)
        VIM:SendMouseButtonEvent(vp.X, vp.Y, 0, false, game, 1)
    end)
end

--=====================================================================
-- RENDER
--=====================================================================
local function onRender()
    local cam = WS.CurrentCamera
    if not cam then return end

    if not State.Enabled then hideAll() return end
    refreshFilter()

    local ball = getBall()
    if not ball then hideAll() return end

    -- ESP
    if State.BallESP then
        if espBall ~= ball then
            if espHighlight then pcall(function() espHighlight:Destroy() end) end
            espHighlight = Instance.new("Highlight")
            espHighlight.FillColor = State.Accent
            espHighlight.FillTransparency = 0.65
            espHighlight.OutlineColor = State.Accent
            espHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            espHighlight.Adornee = ball
            espHighlight.Parent = ball
            espBall = ball
        else
            espHighlight.FillColor = State.Accent
            espHighlight.OutlineColor = State.Accent
        end
    elseif espHighlight then
        pcall(function() espHighlight:Destroy() end)
        espHighlight, espBall = nil, nil
    end

    local pts, hitPos, hitNormal, tti = predict(ball)
    if #pts < 2 then hideAll() return end

    -- línea vertical (plomada) hasta el punto de caída
    if hitPos and State.PlumbLine then
        local a, onA = cam:WorldToViewportPoint(ball.Position)
        local b, onB = cam:WorldToViewportPoint(hitPos)
        if onA and onB then
            PlumbLine.From = Vector2.new(a.X, a.Y)
            PlumbLine.To   = Vector2.new(b.X, b.Y)
            PlumbLine.Color = State.Accent
            PlumbLine.Visible = true
        end
    end

    -- arco de trayectoria
    local n = 0
    if State.Trajectory then
        for i = 1, #pts - 1 do
            local a, onA = cam:WorldToViewportPoint(pts[i])
            local b, onB = cam:WorldToViewportPoint(pts[i + 1])
            if onA and onB and n < MAX_SEG then
                n = n + 1
                local f = i / #pts
                local line = SegLines[n]
                line.From  = Vector2.new(a.X, a.Y)
                line.To    = Vector2.new(b.X, b.Y)
                line.Color = State.Accent:Lerp(Color3.fromRGB(255, 85, 55), f)
                line.Thickness = State.Thickness
                line.Transparency = 0.12 + f * 0.5
                line.Visible = true
            end
        end
    end
    for i = n + 1, MAX_SEG do SegLines[i].Visible = false end

    -- aro de caída
    if hitPos and State.LandingRing then
        local up = hitNormal
        local right = up:Cross(Vector3.new(0, 0, 1))
        if right.Magnitude < 0.01 then right = up:Cross(Vector3.new(0, 1, 0)) end
        right = right.Unit
        local fwd = up:Cross(right).Unit

        local segs = math.clamp(math.floor(State.RingRadius * 6), 16, MAX_RING)
        local r = State.RingRadius * (1 + math.sin(tick() * 9) * 0.05)
        local hot = (tti or 99) < 1 and Color3.fromRGB(255, 70, 60) or State.Accent

        for i = 1, segs do
            local a1 = (i - 1) / segs * math.pi * 2
            local a2 = i / segs * math.pi * 2
            local p1 = hitPos + right * (math.cos(a1) * r) + fwd * (math.sin(a1) * r) + up * 0.2
            local p2 = hitPos + right * (math.cos(a2) * r) + fwd * (math.sin(a2) * r) + up * 0.2
            local s1, o1 = cam:WorldToViewportPoint(p1)
            local s2, o2 = cam:WorldToViewportPoint(p2)
            local l = RingLines[i]
            if o1 and o2 then
                l.From, l.To = Vector2.new(s1.X, s1.Y), Vector2.new(s2.X, s2.Y)
                l.Color, l.Thickness, l.Transparency = hot, 2, 0.05
                l.Visible = true
            else
                l.Visible = false
            end
        end
        for i = segs + 1, MAX_RING do RingLines[i].Visible = false end

        -- texto de impacto
        if State.ImpactText and tti then
            local t, onT = cam:WorldToViewportPoint(hitPos + up * 1.2)
            if onT then
                ImpactText.Position  = Vector2.new(t.X, t.Y)
                ImpactText.Text      = string.format("%.2fs", tti)
                ImpactText.Color     = hot
                ImpactText.Visible   = true
            end
        end

        -- auto hit
        tryAutoHit(ball, tti)

        -- auto aim
        if State.AutoAim then
            local target = hitPos
            cam.CFrame = cam.CFrame:Lerp(CFrame.lookAt(cam.CFrame.Position, target), 0.12)
        end
    else
        for i = 1, MAX_RING do RingLines[i].Visible = false end
        ImpactText.Visible = false
    end
end

--=====================================================================
-- UI
--=====================================================================
local function guiParent()
    local ok, h = pcall(function() return gethui() end)
    if ok and h then return h end
    local ok2, cg = pcall(function() return game:GetService("CoreGui") end)
    if ok2 and cg then return cg end
    return LP:WaitForChild("PlayerGui")
end

local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end

local gui = new("ScreenGui", {
    Name = "VolleyBombHub",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    DisplayOrder = 999,
}, guiParent())

local main = new("Frame", {
    Size = UDim2.new(0, 300, 0, 430),
    Position = UDim2.new(0, 40, 0, 120),
    BackgroundColor3 = Color3.fromRGB(13, 16, 22),
    BorderSizePixel = 0,
}, gui)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, main)
local stroke = new("UIStroke", { Color = State.Accent, Thickness = 1, Transparency = 0.45 }, main)

local bar = new("Frame", {
    Size = UDim2.new(1, 0, 0, 42),
    BackgroundColor3 = Color3.fromRGB(18, 22, 30),
    BorderSizePixel = 0,
}, main)
new("UICorner", { CornerRadius = UDim.new(0, 10) }, bar)
new("Frame", { Size = UDim2.new(1, 0, 0, 12), Position = UDim2.new(0, 0, 1, -12),
    BackgroundColor3 = Color3.fromRGB(18, 22, 30), BorderSizePixel = 0 }, bar)

new("TextLabel", {
    Size = UDim2.new(1, -60, 0, 20), Position = UDim2.new(0, 12, 0, 6),
    BackgroundTransparency = 1, Font = Enum.Font.GothamBlack, TextSize = 14,
    TextColor3 = Color3.fromRGB(240, 245, 255), TextXAlignment = Enum.TextXAlignment.Left,
    Text = "VOLLEY BOMB",
}, bar)
new("TextLabel", {
    Size = UDim2.new(1, -60, 0, 14), Position = UDim2.new(0, 12, 0, 23),
    BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 10,
    TextColor3 = State.Accent, TextXAlignment = Enum.TextXAlignment.Left,
    Text = "trajectory · landing marker",
}, bar)

local minBtn = new("TextButton", {
    Size = UDim2.new(0, 22, 0, 22), Position = UDim2.new(1, -32, 0, 10),
    BackgroundColor3 = Color3.fromRGB(30, 36, 46), Text = "–",
    Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = Color3.fromRGB(220, 225, 235),
    BorderSizePixel = 0, AutoButtonColor = false,
}, bar)
new("UICorner", { CornerRadius = UDim.new(0, 6) }, minBtn)

-- arrastre
local dragging, dragStart, startPos = false, nil, nil
bar.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging, dragStart, startPos = true, i.Position, main.Position
    end
end)
bind(UIS.InputChanged, function(i)
    if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then
        local d = i.Position - dragStart
        main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                  startPos.Y.Scale, startPos.Y.Offset + d.Y)
    end
end)
bind(UIS.InputEnded, function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
end)

local scroll = new("ScrollingFrame", {
    Size = UDim2.new(1, -16, 1, -54), Position = UDim2.new(0, 8, 0, 48),
    BackgroundTransparency = 1, BorderSizePixel = 0,
    ScrollBarThickness = 3, ScrollBarImageColor3 = State.Accent,
    CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
}, main)

local function section(title)
    local f = new("Frame", { Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1 }, scroll)
    new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = State.Accent,
        TextXAlignment = Enum.TextXAlignment.Left, Text = string.upper(title),
    }, f)
    return f
end

local function addToggle(parent, label, key, cb)
    local row = new("Frame", { Size = UDim2.new(1, 0, 0, 32), BackgroundTransparency = 1 }, parent)
    new("TextLabel", {
        Size = UDim2.new(1, -50, 1, 0), BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium, TextSize = 12,
        TextColor3 = Color3.fromRGB(205, 212, 225),
        TextXAlignment = Enum.TextXAlignment.Left, Text = label,
    }, row)

    local track = new("Frame", {
        Size = UDim2.new(0, 36, 0, 18), Position = UDim2.new(1, -36, 0.5, -9),
        BackgroundColor3 = Color3.fromRGB(40, 46, 58), BorderSizePixel = 0,
    }, row)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, track)
    local knob = new("Frame", {
        Size = UDim2.new(0, 14, 0, 14), Position = UDim2.new(0, 2, 0.5, -7),
        BackgroundColor3 = Color3.fromRGB(150, 158, 172), BorderSizePixel = 0,
    }, track)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, knob)

    local function refresh()
        local on = State[key]
        track.BackgroundColor3 = on and State.Accent or Color3.fromRGB(40, 46, 58)
        knob.Position = on and UDim2.new(1, -16, 0.5, -7) or UDim2.new(0, 2, 0.5, -7)
        knob.BackgroundColor3 = on and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(150, 158, 172)
    end
    refresh()

    local btn = new("TextButton", { Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1, Text = "" }, track)
    btn.MouseButton1Click:Connect(function()
        State[key] = not State[key]
        refresh()
        if cb then cb(State[key]) end
    end)
    return row
end

local function addSlider(parent, label, minV, maxV, step, key)
    local row = new("Frame", { Size = UDim2.new(1, 0, 0, 42), BackgroundTransparency = 1 }, parent)
    new("TextLabel", {
        Size = UDim2.new(1, -50, 0, 18), BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium, TextSize = 12,
        TextColor3 = Color3.fromRGB(205, 212, 225),
        TextXAlignment = Enum.TextXAlignment.Left, Text = label,
    }, row)
    local val = new("TextLabel", {
        Size = UDim2.new(0, 46, 0, 18), Position = UDim2.new(1, -46, 0, 0),
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 12,
        TextColor3 = State.Accent, TextXAlignment = Enum.TextXAlignment.Right,
        Text = tostring(State[key]),
    }, row)

    local track = new("Frame", {
        Size = UDim2.new(1, 0, 0, 5), Position = UDim2.new(0, 0, 0, 26),
        BackgroundColor3 = Color3.fromRGB(40, 46, 58), BorderSizePixel = 0,
    }, row)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, track)
    local fill = new("Frame", { Size = UDim2.new(0, 0, 1, 0),
        BackgroundColor3 = State.Accent, BorderSizePixel = 0 }, track)
    new("UICorner", { CornerRadius = UDim.new(1, 0) }, fill)

    local function apply(v)
        v = math.clamp(v, minV, maxV)
        if step > 0 then v = math.floor(v / step + 0.5) * step end
        State[key] = v
        val.Text = (step >= 1) and tostring(math.floor(v)) or string.format("%.2f", v)
        local p = (v - minV) / (maxV - minV)
        fill.Size = UDim2.new(p, 0, 1, 0)
    end
    apply(State[key])

    local held = false
    track.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            held = true
            apply(minV + (i.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X * (maxV - minV))
        end
    end)
    bind(UIS.InputChanged, function(i)
        if held and i.UserInputType == Enum.UserInputType.MouseMovement then
            apply(minV + (i.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X * (maxV - minV))
        end
    end)
    bind(UIS.InputEnded, function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then held = false end
    end)
    return row
end

-- contenido
section("General")
addToggle(scroll, "Script activo  [F]", "Enabled")
addToggle(scroll, "Trayectoria del balón", "Trajectory")
addToggle(scroll, "Aro de caída", "LandingRing")
addToggle(scroll, "Línea vertical", "PlumbLine")
addToggle(scroll, "Tiempo de impacto", "ImpactText")

section("Balón")
addToggle(scroll, "Resaltado (ESP)", "BallESP")

section("Automatización")
addToggle(scroll, "Auto hit (clic)", "AutoHit")
addToggle(scroll, "Auto apuntado cámara", "AutoAim")
addSlider(scroll, "Rango de golpe", 5, 40, 1, "HitRange")

section("Visuales")
addSlider(scroll, "Grosor de línea", 1, 6, 1, "Thickness")
addSlider(scroll, "Pasos de simulación", 60, 380, 10, "Steps")
addSlider(scroll, "Radio del aro", 2, 14, 1, "RingRadius")
addSlider(scroll, "Arrastre del aire", 0, 0.2, 0.005, "Drag")

-- color presets
local cRow = new("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1 }, scroll)
local presets = {
    Color3.fromRGB(0, 200, 255), Color3.fromRGB(120, 255, 140),
    Color3.fromRGB(255, 170, 60), Color3.fromRGB(200, 120, 255),
}
for i, c in ipairs(presets) do
    local b = new("TextButton", {
        Size = UDim2.new(0, 26, 0, 22), Position = UDim2.new(0, (i - 1) * 32, 0, 2),
        BackgroundColor3 = c, Text = "", BorderSizePixel = 0, AutoButtonColor = false,
    }, cRow)
    new("UICorner", { CornerRadius = UDim.new(0, 5) }, b)
    b.MouseButton1Click:Connect(function()
        State.Accent = c
        stroke.Color = c
        ImpactText.Color = c
    end)
end

section("Teclas")
new("TextLabel", {
    Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1,
    Font = Enum.Font.GothamMedium, TextSize = 11, TextWrapped = true,
    TextColor3 = Color3.fromRGB(150, 158, 172), TextXAlignment = Enum.TextXAlignment.Left,
    Text = "RightShift : abrir / cerrar menú\nF : activar / desactivar script",
}, scroll)

minBtn.MouseButton1Click:Connect(function()
    State.MenuOpen = not State.MenuOpen
    scroll.Visible = State.MenuOpen
    main.Size = State.MenuOpen and UDim2.new(0, 300, 0, 430) or UDim2.new(0, 300, 0, 42)
    minBtn.Text = State.MenuOpen and "–" or "+"
end)

bind(UIS.InputBegan, function(i, gp)
    if gp then return end
    if i.KeyCode == Enum.KeyCode.RightShift then
        minBtn:Fire("MouseButton1Click")
    elseif i.KeyCode == Enum.KeyCode.F then
        State.Enabled = not State.Enabled
    end
end)

--=====================================================================
-- LOOP + LIMPIEZA
--=====================================================================
local renderConn = RunService.RenderStepped:Connect(onRender)

local function cleanup()
    if renderConn then renderConn:Disconnect() end
    for _, c in ipairs(Connections) do pcall(function() c:Disconnect() end) end
    hideAll()
    for _, l in ipairs(SegLines) do pcall(function() l:Remove() end) end
    for _, l in ipairs(RingLines) do pcall(function() l:Remove() end) end
    pcall(function() ImpactText:Remove() end)
    pcall(function() PlumbLine:Remove() end)
    if espHighlight then pcall(function() espHighlight:Destroy() end) end
    pcall(function() gui:Destroy() end)
    getgenv().VB_Loaded = nil
    getgenv().VB_Unload = nil
end

getgenv().VB_Unload = cleanup
getgenv().VB_Loaded = true
