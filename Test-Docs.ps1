Param(
    [switch]$cleanUp,
    [string]$file
)

$useNuGetPackage = $env:USE_NUGET_PACKAGE
$apiDoctorNuGetVersion = $env:API_DOCTOR_NUGET_VERSION
$apiDoctorGitRepoUrl = $env:API_DOCTOR_GIT_REPO_URL
$apiDoctorGitBranch = $env:API_DOCTOR_GIT_BRANCH
$docsRepoPath = (Get-Location).Path
$docsSubPath = $env:APIDOCTOR_DOCSUBPATH
$downloadedApiDoctor = $false
$downloadedNuGet = $false

Write-Host "Repository location: ", $docsRepoPath

# Check if API Doctor source has been set
if ($useNuGetPackage -and [string]::IsNullOrWhiteSpace($apiDoctorNuGetVersion)) {
	Write-Host "API Doctor NuGet package version has not been set. Aborting..."
	exit 1
}
elseif (!$useNuGetPackage -and [string]::IsNullOrWhiteSpace($apiDoctorGitRepoUrl)) {
	Write-Host "API Doctor Git Repo URL has not been set. Aborting..."
	exit 1
}

# Check if docs subpath has been set
if ([string]::IsNullOrWhiteSpace($docsSubPath)) {
	Write-Host "API Doctor subpath has not been set. Aborting..."
	exit 1
}

# Get NuGet
$nugetPath = $null
if (Get-Command "nuget.exe" -ErrorAction SilentlyContinue) {
	# Use the existing nuget.exe from the path
	$nugetPath = (Get-Command "nuget.exe").Source
}
else {
	# Download nuget.exe from the nuget server if required
	$nugetPath = Join-Path $docsRepoPath -ChildPath "nuget.exe"
	$nugetExists = Test-Path $nugetPath
	if ($nugetExists -eq $false) {
		Write-Host "nuget.exe not found. Downloading from dist.nuget.org"
		Invoke-WebRequest -Uri "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe" -OutFile $nugetPath
	}
	$downloadedNuGet = $true
}

# Check for API Doctor executable in path
$apidoc = $null
if (Get-Command "apidoc.exe" -ErrorAction SilentlyContinue) {
    $apidoc = (Get-Command "apidoc.exe").Source
}
else {
	$apidocPath = Join-Path $docsRepoPath -ChildPath "apidoctor"
	New-Item -ItemType Directory -Force -Path $apidocPath
	
	if ($useNuGetPackage) {		
		# Install API Doctor from NuGet
		Write-Host "Running nuget.exe from ", $nugetPath
		$nugetParams = "install", "ApiDoctor", "-Version", $apiDoctorNuGetVersion, "-OutputDirectory", $apidocPath, "-NonInteractive", "-DisableParallelProcessing"
		& $nugetPath $nugetParams

		if ($LastExitCode -ne 0) { 
			# NuGet error, so we can't proceed
			Write-Host "Error installing API Doctor from NuGet. Aborting."
			Remove-Item $nugetPath
			exit $LastExitCode
		}
	}
	else {
		# Default to 'master' branch of API Doctor if not set
		if([string]::IsNullOrWhiteSpace($apiDoctorGitBranch)){
			$apiDoctorGitBranch = "master"
            Write-Host "API Doctor branch has not been set, defaulting to 'master' branch."
		}
		
		# Download API Doctor from GitHub	
		Write-Host "Cloning API Doctor repository from GitHub"
		Write-Host "`tRemote URL: $apiDoctorGitRepoUrl"
		Write-Host "`tBranch: $apiDoctorGitBranch"
		& git clone -b $apiDoctorGitBranch $apiDoctorGitRepoUrl --recurse-submodules "$apidocPath\SourceCode"
		$downloadedApiDoctor = $true
		
		$nugetParams = "restore", "$apidocPath\SourceCode"
		& $nugetPath $nugetParams
			
		# Build API Doctor
		Install-Module -Name Invoke-MsBuild -Scope CurrentUser -Force 
		Write-Host "`r`nBuilding API Doctor..."
		Invoke-MsBuild -Path "$apidocPath\SourceCode\ApiDoctor.sln" -MsBuildParameters "/t:Rebuild /p:Configuration=Release /p:OutputPath=$apidocPath\ApiDoctor\tools"

        # Delete existing API Doctor source code     
        Remove-Item $apidocPath\SourceCode -Force  -Recurse -ErrorAction SilentlyContinue
	}
	
	# Get the path to the API Doctor exe
	$pkgfolder = Get-ChildItem -LiteralPath $apidocPath -Directory | Where-Object {$_.name -match "ApiDoctor"}
	$apidoc = [System.IO.Path]::Combine($apidocPath, $pkgfolder.Name, "tools\apidoc.exe")
	$downloadedApiDoctor = $true
}

# Check if the autogenerated folders still exist and raise an error if they do
if(( Test-Path '.\doc-stubs\' -PathType Container) -or ( Test-Path '.\changelog-stubs\' -PathType Container)){
    Write-Host "Ensure that the doc-stubs and changelog-stubs folders have been deleted. Aborting..."
    exit 1
}

$lastResultCode = 0

# Run validation at the root of the repository
$appVeyorUrl = $env:APPVEYOR_API_URL 

$fullPath = Join-Path $docsRepoPath -ChildPath $docsSubPath
$params = "check-all", "--path", $fullPath, "--ignore-warnings"
if ($appVeyorUrl -ne $null)
{
    $params = $params += "--appveyor-url", $appVeyorUrl
}

& $apidoc $params

if ($LastExitCode -ne 0) { 
    $lastResultCode = $LastExitCode
}

# Clean up the stuff we downloaded
if ($cleanUp -eq $true) {
    if ($downloadedNuGet -eq $true) {
        Remove-Item $nugetPath 
    }
    if ($downloadedApiDoctor -eq $true) {
        Remove-Item $apidocPath -Recurse -Force
    }
}

if ($lastResultCode -ne 0) {
    Write-Host "Errors were detected. This build failed."
    exit $lastResultCode
}