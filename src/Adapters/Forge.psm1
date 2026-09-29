function Test-MmtlForgeProject { param($Project) return $Project.Loader -eq 'Forge' }
Export-ModuleMember -Function Test-MmtlForgeProject
