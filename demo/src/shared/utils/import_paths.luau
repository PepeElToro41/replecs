function import_paths(container: Instance, deep: boolean?)
	local children = container:GetChildren()
	for _, child in children do
		if child.ClassName == "ModuleScript" then
			(require)(child)
		end
		if deep then
			import_paths(child, deep)
		end
	end
end

return import_paths
