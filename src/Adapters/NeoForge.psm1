function Test-MmtlNeoForgeProject { param($Project) return $Project.Loader -eq 'NeoForge' }
Export-ModuleMember -Function Test-MmtlNeoForgeProject
