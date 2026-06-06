local function builderClaimTweaks(name, unitDef)
	if unitDef.builder
		and not unitDef.yardmap
		and unitDef.builddistance
		and unitDef.builddistance > 0
		and unitDef.canrepair ~= false
		and not unitDef.cancapture
	then
		unitDef.cancapture = true
		unitDef.capturespeed = (unitDef.workertime or 100) * 4
		unitDef.customparams = unitDef.customparams or {}
		unitDef.customparams.capture_neutral_only = "1"
	end
	return unitDef
end

return {
	Tweaks = builderClaimTweaks,
}
