function Test-MmtlFabricProject { param($Project) return $Project.Loader -eq 'Fabric' }
Export-ModuleMember -Function Test-MmtlFabricProject
