--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

-- References to prefabs and world objects that will be cloned and manipulated during the minigame
local dotElement = ReplicatedStorage.Instances.GuiPrefab.Elements.Dot
local forgingPrefab = ReplicatedStorage.Instances.GuiPrefab.Forging
local accuracyLabelsFolder = ReplicatedStorage.Instances.GuiPrefab.Accuracy
local anvil = Workspace:WaitForChild("Anvil")
local anvilMesh = anvil:WaitForChild("AnvilMesh")
local cameraPart = anvil:WaitForChild("CameraPart")
local camera = Workspace.CurrentCamera :: Camera

-- Cloning of the main prefab that will be displayed to the player during the minigame
local instance = forgingPrefab:Clone() -- ScreenGui
local dotSpawnZone = instance:FindFirstChild("Zone") -- Frame

-- Constants that control the timing and behavior of dots in the minigame
local SPEED_VARIANCE_CAP = 0.5
local DOT_SPAWN_DELAY = 0.1
local APPEAR_TIME = 0.15
local DOT_LIFETIME = 1.5

local UIForging = {}
UIForging._instance = instance
UIForging.dotCompleted = Instance.new("BindableEvent")
UIForging._isGameActive = false
UIForging._cameraData = {
	tween = nil,
	connection = nil
} :: { tween: Tween?, connection: RBXScriptConnection? }

-- Enumerator that categorizes precision levels based on distance from perfect timing
local AccuracyRarity = {
	Perfect = "Perfect" :: "Perfect",
	Great = "Great" :: "Great",
	Good = "Good" :: "Good",
	Ok = "Ok" :: "Ok",
	Bad = "Bad" :: "Bad"
}

local AccuracyByRarity = {
	{ threshold = 0.2, rarity = AccuracyRarity.Perfect },
	{ threshold = 0.4, rarity = AccuracyRarity.Great },
	{ threshold = 0.6, rarity = AccuracyRarity.Good },
	{ threshold = 0.8, rarity = AccuracyRarity.Ok },
	{ threshold = 1.0, rarity = AccuracyRarity.Bad },
}

-- Initializes the module by connecting it to the specified parent, registering its event listeners,
-- and integrating it into the UI layer system through the UIHandler
function UIForging.setup(parent: Instance)
	UIForging._instance.Parent = parent
	UIForging._setupListeners()
end

function UIForging.show()
	UIForging._instance.Enabled = true
end

function UIForging.hide()
	UIForging._instance.Enabled = false
end

-- Returns the current minigame state, allowing other systems to check
-- whether they should process forging-related inputs or not (example: it's used on binding to toggle the game state)
function UIForging.isGameActive()
	return UIForging._isGameActive
end

-- Controls the visibility of green UIGradients inside the dot, which function as
-- visual indicators when the inner circle reaches the ideal size for a perfect hit
function UIForging._highlightDot(dot: GuiButton, enabled: boolean)
	for _, descendant in dot:GetDescendants() do
		if not descendant:IsA("UIGradient") then continue end
		descendant.Enabled = enabled
	end
end

-- Converts the scale value (0-1) to an absolute distance measure from the perfect point,
-- using the mathematical function abs(1 - value) to normalize both values above and below 1
function UIForging._mapToLineAbs(value: number): number
	return math.abs(1 - value)
end

-- Iterates through the accuracy thresholds in order, returning the first rarity
-- whose threshold is greater than or equal to the distance from perfect timing
function UIForging._getAccuracyRarity(accuracy: number): string
	local distanceFromPerfect = UIForging._mapToLineAbs(accuracy)

	for _, entry in ipairs(AccuracyByRarity) do
		if distanceFromPerfect <= entry.threshold then
			return entry.rarity
		end
	end

	-- Fallback (should never happen if thresholds cover all cases)
	return AccuracyRarity.Bad
end

-- Generates a randomized speed for each dot by applying a percentage variation (0-50%)
-- over the base lifetime, making some dots faster and others slower
function UIForging._calculateDotSpeed(): number
	local variance = math.min(math.random(), SPEED_VARIANCE_CAP)
	return DOT_LIFETIME / (1 + variance)
end

-- Instantiates a new dot by cloning the prefab, positioning it randomly within the spawn
-- zone through scale coordinates (0-1 on both axes)
function UIForging._createDotInstance(): GuiButton
	local dot = dotElement:Clone()
	local body = dot:FindFirstChild("Body")
	dot.Position = UDim2.fromScale(math.random(), math.random())
	dot.Parent = dotSpawnZone
	return dot
end

-- Creates a "pop-in" effect by growing the dot from zero size to its original size
-- using a short tween, preventing it from appearing instantly on screen
function UIForging._animateDotAppearance(dot: GuiButton)
	local originalSize = dot.Size
	dot.Size = UDim2.fromScale(0, 0)
	local appearTween = TweenService:Create(
		dot,
		TweenInfo.new(APPEAR_TIME),
		{ Size = originalSize }
	)
	appearTween:Play()
	return appearTween
end

-- Sets up the dot's visual timer through a linear tween that shrinks the inner circle
-- from scale 1.0 to 0.0, while continuously monitoring the size to activate/deactivate
-- the green highlight when it's in the perfect timing zone
function UIForging._setupDotTimer(dot: GuiButton, speed: number)
	local body = dot:FindFirstChild("Body")
	local innerCircle = body:FindFirstChild("InnerCircle") :: Frame

	local timerTween = TweenService:Create(
		innerCircle,
		TweenInfo.new(speed, Enum.EasingStyle.Linear),
		{ Size = UDim2.fromScale(0, 0) }
	)

	local sizeConnection = innerCircle
		:GetPropertyChangedSignal("Size")
		:Connect(function()
			local accuracy = innerCircle.Size.X.Scale
			local accuracyRarity = UIForging._getAccuracyRarity(accuracy)
			local isPerfect = accuracyRarity == AccuracyRarity.Perfect
			UIForging._highlightDot(dot, isPerfect)
		end)

	timerTween:Play()

	return {
		tween = timerTween,
		connection = sizeConnection,
		innerCircle = innerCircle
	}
end

-- Disconnects all listeners and cancels the active tween to prevent memory leaks and
-- unexpected behaviors when a dot is removed before completing naturally
function UIForging._cleanupDotInteraction(timerData, clickConnection, completedConnection)
	timerData.connection:Disconnect()
	timerData.tween:Cancel()

	if completedConnection then
		completedConnection:Disconnect()
	end
	if clickConnection then
		clickConnection:Disconnect()
	end
end

-- Establishes two parallel paths to finalize the dot: manual player click or
-- automatic tween completion, both converging to the same cleanup function
-- and firing the dotCompleted event with the current accuracy
function UIForging._setupDotInteraction(dot: GuiButton, timerData)
	local clickConnection: RBXScriptConnection
	local completedConnection: RBXScriptConnection

	local function onDotFinished()
		UIForging._cleanupDotInteraction(timerData, clickConnection, completedConnection)

		local accuracy = timerData.innerCircle.Size.X.Scale
		UIForging.dotCompleted:Fire(dot, accuracy)
	end

	clickConnection = dot.MouseButton1Click:Once(onDotFinished)
	completedConnection = timerData.tween.Completed:Once(onDotFinished)
end

-- Orchestrates the complete creation of a dot following a sequence: active state check,
-- instantiation, entrance animation (with yield), timer setup and interaction setup,
-- all protected by pcall to prevent crashes
function UIForging._spawnDot()
	if not UIForging.isGameActive() then
		return
	end

	local dot = UIForging._createDotInstance()

	local appearTween = UIForging._animateDotAppearance(dot)
	appearTween.Completed:Wait()

	local speed = UIForging._calculateDotSpeed()
	local success, timerData = pcall(UIForging._setupDotTimer, dot, speed)
	if not success then return end

	UIForging._setupDotInteraction(dot, timerData)
end

-- Transitions the camera from Custom to Scriptable, calculating a CFrame that looks from CameraPart
-- to AnvilMesh with a 90° rotation, and schedules the first dot spawn for when
-- the camera animation finishes
function UIForging.startMinigame()
	UIForging._isGameActive = true

	camera.CameraType = Enum.CameraType.Scriptable
	local lookAt = CFrame.lookAt(cameraPart.Position, anvilMesh.Position) * CFrame.Angles(0, 0, math.rad(90))
	local cameraTween = TweenService:Create(
		camera,
		TweenInfo.new(1),
		{ CFrame = lookAt }
	)

	cameraTween:Play()
	UIForging._cameraData.connection = cameraTween.Completed:Once(UIForging._spawnDot)
	UIForging._cameraData.tween = cameraTween
end

-- Interrupts the minigame flow by reverting the camera to Custom, canceling pending tweens,
-- disconnecting events and destroying all active dots in the spawn zone to completely
-- reset the visual state
function UIForging.stopMinigame()
	UIForging._isGameActive = false

	if UIForging._cameraData.tween then
		UIForging._cameraData.tween:Cancel()
	end
	if UIForging._cameraData.connection then
		UIForging._cameraData.connection:Disconnect()
	end

	camera.CameraType = Enum.CameraType.Custom

	for _, child in dotSpawnZone:GetChildren() do
		if child:IsA("GuiButton") then
			child:Destroy()
		end
	end
end

-- Creates an "explosion" effect by expanding the dot's body while simultaneously
-- fading out all visual elements (Frames and UIStrokes), returning the last tween
-- to allow completion detection
function UIForging._animateDotDisappearance(dot: GuiButton): Tween?
	local body = dot:FindFirstChild("Body") :: Frame
	if not body then return nil end
	local originalSize = body.Size
	local goalSize = originalSize + UDim2.fromScale(originalSize.X.Scale, originalSize.Y.Scale)

	local disappear = TweenService:Create(
		body,
		TweenInfo.new(APPEAR_TIME),
		{ Size = goalSize }
	)
	disappear:Play()

	local lastTween: Tween?
	for _, descendant in body:GetDescendants() do
		if not descendant:IsA("Frame") and not descendant:IsA("UIStroke") then continue end
		local tween = TweenService:Create(
			descendant,
			TweenInfo.new(APPEAR_TIME),
			{ Transparency = 1 }
		)
		tween:Play()
		lastTween = tween
	end

	return lastTween
end

-- Searches the accuracy labels folder for the CanvasGroup corresponding to the provided rarity,
-- using CanvasGroup specifically because its GroupTransparency property allows
-- animating the fade out of all child elements at once
function UIForging._getAccuracyCanvas(accuracyRarity: string): CanvasGroup
	local label = accuracyLabelsFolder:FindFirstChild(accuracyRarity) :: CanvasGroup
	assert(label, `Missing label for {accuracyRarity}`)
	return label
end

-- Animates the accuracy label off-screen diagonally (position 1, -1) while
-- progressively increasing group transparency, creating a "fly away" effect
-- with duration 3x longer than the appearance animation
function UIForging._animateCanvasDisappearance(canvas: CanvasGroup)
	task.wait(.075)

	local disappearTime = APPEAR_TIME * 3

	local tween = TweenService:Create(
		canvas,
		TweenInfo.new(disappearTime),
		{
			Position = UDim2.fromScale(1, -1),
			GroupTransparency = 1,
		}
	)
	tween:Play()
	return tween
end

-- Callback executed when a dot is finalized (by click or timeout), which determines
-- the accuracy rarity, clones and attaches the corresponding label to the dot, executes
-- disappearance animations in parallel, and schedules the dot destruction and
-- next dot spawn after the configured delay
function UIForging._onDotCompleted(dot: GuiButton, accuracy: number)
	local accuracyRarity = UIForging._getAccuracyRarity(accuracy)
	local canvas = UIForging._getAccuracyCanvas(accuracyRarity)
	local canvasClone = canvas:Clone()
	canvasClone.Parent = dot

	UIForging._animateDotDisappearance(dot)
	local canvasTween = UIForging._animateCanvasDisappearance(canvasClone)

	if canvasTween then
		canvasTween.Completed:Once(function()
			if dot.Parent then
				dot:Destroy()
			end
		end)
	end

	if UIForging.isGameActive() then
		task.wait(DOT_SPAWN_DELAY)
		
		UIForging._spawnDot()
	end
end

-- Connects the _onDotCompleted callback to the dotCompleted event, establishing the event
-- loop that allows each completed dot to trigger result processing and the creation of the next dot
function UIForging._setupListeners()
	UIForging.dotCompleted.Event:Connect(UIForging._onDotCompleted)
end

return UIForging
