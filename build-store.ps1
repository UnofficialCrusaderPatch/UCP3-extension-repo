Param(
  [Parameter(Mandatory = $true, ValueFromPipeline = $false)][string]$Certificate,
  [Parameter(Mandatory = $false, ValueFromPipeline = $false)][string]$NugetToken
)

$REPO = "UnofficialCrusaderPatch/UCP3-extensions-store"
$UCP3_REPO = "UnofficialCrusaderPatch/UnofficialCrusaderPatch3"
$STORE_FILE_NAME = "store.yml"

# Stop this entire script in case of errors
$ErrorActionPreference = 'Stop'

# Install yaml library
if (!(Get-Module -ListAvailable -Name powershell-yaml)) {
  Install-Module powershell-yaml -Scope CurrentUser -Force  
}

Import-Module powershell-yaml

$recipe = Get-Content .\recipe.yml | ConvertFrom-Yaml

$releaseTags = gh --repo $REPO release list --json tagName | ConvertFrom-Json | ForEach-Object { $_.tagName }

# For testing only
$releaseTags = "['v3.0.0', 'v3.0.1', 'v3.0.2']" | ConvertFrom-Yaml

# Descending order
$sortedReleaseVersionsArray = @($releaseTags | Where-Object { $_.StartsWith("v") } | ForEach-Object { [semver]($_.Substring(1)) } | Sort-Object -Descending)

$extensions = $recipe.extensions.list

# Add the definition to each extension as pulled from the internet.
foreach ($extension in $extensions) {
  
  $source = $extension.contents.source
  $definition = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$($source.url)/$($source['github-sha'])/definition.yml" | 
  Select-Object -ExpandProperty Content | 
  ConvertFrom-Yaml

  if ($null -ne $source['extension-type']) {
    $definition.type = $source['extension-type']
  }

  if (($definition.type -ne "plugin") -and ($definition.type -ne "module")) {
    Write-Error "Aborting. Extension is of unknown type: $($definition.name)-$($definition.version)"

    return 1
  }

  if (($extension.definition -ne $null) -and ($extension.definition.version -ne $definition.version)) {
    Write-Error "Aborting. Extension version is different on remote: $($definition.name)-$($definition.version)"

    return 1
  }

  $extension.definition = $definition
}

$store = $recipe | ConvertTo-Yaml | ConvertFrom-Yaml

$resolvedExtensions = [System.Collections.ArrayList]::new()

$extensionsToBeBuilt = @($extensions | ForEach-Object { $_ }) # Array copy

foreach ($release in $sortedReleaseVersionsArray) {

  if (0 -eq $extensionsToBeBuilt.Count) {
    Write-Output "All extension were resolved"
    break
  }

  $tag = "v$release"

  Write-Output "Searching for binaries in release: $tag"

  $releaseStore = gh release download $tag --pattern $STORE_FILE_NAME --repo $REPO --output - | ConvertFrom-Json

  foreach ($extension in $extensions) {

    if (0 -eq $extensionsToBeBuilt.Count) {
      Write-Output "All extension were resolved"
      break
    }

    if ($resolvedExtensions.Contains($extension)) {
      continue
    }

    $name = $extension.definition.name
    $version = $extension.definition.version
    
    Write-Output "Looking for a binary for: $name@$version"

    $hit = $releaseStore | Where-Object { $_.definition.name -eq $name } | Where-Object { $_.definition.version -eq $version }

    if ($null -ne $hit) {
      Write-Output "Found a binary"
      # Copy over the contents
      $extension.contents = $hit.contents

      $store.extensions.list | 
      Where-Object { $_.definition.name -eq $extension.definition.name -and $_.definition.version -eq $extension.definition.version } |
      ForEach-Object { $_.contents = $hit.contents }

      $extensionsToBeBuilt.Remove($extension)
      $resolvedExtensions.Add($extension)

      continue
    }

  }

  Write-Output "Finished searching this release"
}

if ($extensionsToBeBuilt.Count -eq 0) {
  $store.timestamp = Get-Date -Format o
  $store | ConvertTo-Yaml | New-Item -Path "build\store.yml" | Out-Null

  # We are done!
  return 0
}

Write-Output "Compiling $($extensionsToBeBuilt.Count) extensions"

# Prepare the build directory
Remove-Item -Path "build" -Recurse -ErrorAction Ignore -Force | Out-Null
New-Item -Path "build" -ItemType "directory" -ErrorAction Ignore | Out-Null


$frameworkTag = $recipe.framework['github-tag']
$frameworkSha = $recipe.framework['github-sha']

# We just clone the UCP3 repo for the build scripts!
gh repo clone $UCP3_REPO "build\ucp3" -- --depth=1 --branch $frameworkTag | Out-Null

Push-Location ".\build\ucp3"
$localFrameworkSha = git rev-parse HEAD
Pop-Location

if ($localFrameworkSha -ne $frameworkSha) {
  Write-Error "Abort. GitHub SHA does not match for repo: $UCP3_REPO"
  return 1
}


# Fetch nuget package if it exists
if ($releaseTags.Contains($frameworkTag)) {
  gh release download --dir ".\build\" --pattern "*nupkg[.]zip" --repo $UCP3_REPO $frameworkTag
  Expand-Archive -Path ".\build\*.zip" -DestinationPath ".\build\"
  $NUPKG_DIRECTORY = (Get-Item -Path ".\build\").FullName
} else {
  # Build everything given
  Push-Location "build\ucp3"

  if ($NugetToken -ne $null -and $NugetToken -ne "") {
    & ".\scripts\build.ps1" -What setup -NugetToken $NugetToken
  }
  & ".\scripts\build.ps1" -What nuget

  $NUPKG_DIRECTORY = (Get-Item -Path ".\dll\").FullName
  
  Pop-Location
}



# Clear pre shipped stuff, we don't need it anymore in this store, or maybe we do, but only a subset...
# Remove-Item -Recurse -Path ".\build\ucp3\content\ucp\modules\*" -Force | Out-Null
# Remove-Item -Recurse -Path ".\build\ucp3\content\ucp\plugins\*" -Force | Out-Null

New-Item -Path "build\extensions" -ItemType "directory" -ErrorAction Ignore | Out-Null
New-Item -Path "build\extensions\source" -ItemType "directory" -ErrorAction Ignore | Out-Null
New-Item -Path "build\extensions\binary" -ItemType "directory" -ErrorAction Ignore | Out-Null

foreach ($extension in $extensionsToBeBuilt) {
  $source = $extension.contents.source

  if ($source.method.Contains("github") -ne $true) {
    Write-Warning "Skipping unsupported extension because of its source method: $($extension.definition.name)-$($extension.definition.version)"
    continue
  }
  if ($null -eq $source['github-tag']) {
    Write-Warning "Skipping unsupported extension because its source is missing 'github-tag': $($extension.definition.name)-$($extension.definition.version)"
    continue
  }
  if ($null -eq $source['github-sha']) {
    Write-Warning "Skipping unsupported extension because its source is missing 'github-sha': $($extension.definition.name)-$($extension.definition.version)"
    continue
  }

  $destination = "build\extensions\source\$($extension.definition.name)-$($extension.definition.version)"
  $binaryDestination = "build\extensions\binary\"
  
  if ($source['github-tag'] -eq "main") {
    gh repo clone "$($source.url)" $destination -- --recurse-submodules --branch main | Out-Null
    Push-Location $destination
    git checkout $source['github-sha'] | Out-Null
    Pop-Location
  }
  else {
    gh repo clone "$($source.url)" $destination -- --recurse-submodules --depth=1 --branch $source['github-tag'] | Out-Null
  }
  
  

  Push-Location $destination
  $localSha = git rev-parse HEAD 
  Pop-Location

  if ($localSha -ne $source['github-sha']) {
    Write-Error "Aborting. GitHub SHA does not match between specified and local repo, is the branch or sha up to date?"

    return 1
  }

  if ($extension.definition.type -eq "module") {
    & ".\build\ucp3\scripts\build-module.ps1" -Path $destination -Destination "$binaryDestination\" -BUILD_CONFIGURATION "ReleaseSecure" -UCPNuPkgPath "$NUPKG_DIRECTORY" -RemoveZippedFolders
  } else {
    & ".\build\ucp3\scripts\build-plugin.ps1" -Path $destination -Destination "$binaryDestination" -RemoveZippedFolders
  }
}


foreach ($extension in $extensionsToBeBuilt) {
  $filename = "$($extension.definition.name)-$($extension.definition.version).zip"
  Move-Item -Path ".\build\extensions\binary\$filename" -Destination "build\extensions\"

  if ( $extension.definition.type -eq "module" ) {
    # Modules

    

    $path = ".\build\extensions\$filename"

    $hash = (Get-FileHash -Algorithm SHA256 -Path $path | Select-Object -ExpandProperty Hash).ToLower()
  
    & ".\build\ucp3\scripts\sign-file.ps1" -Path $path -Certificate $Certificate
  
    $sig = Get-Content -Path "$path.sig" | ForEach-Object { $_.Split(" ")[0] }
  
    $item = Get-Item -Path $path
    
    Remove-Item -Path "$path.sig"
  
    $package = @(
      @{
        method    = "github-binary";
        size      = $item.length;
        url       = "https://github.com/$REPO/releases/download/$($frameworkTag)/$filename";
        signer    = "default";
        hash      = $hash;
        signature = $sig;
      }
    )
  
  }
  else {
    # Plugins
    $path = ".\build\extensions\$filename"
  
    $item = Get-Item -Path $path
  
    $package = @(
      @{
        method = "github-binary";
        size   = $item.length;
        url    = "https://github.com/$REPO/releases/download/$($frameworkTag)/$filename";
        signer = "default";
      }
    )

  }

  $store.extensions.list | 
  Where-Object { $_.definition.name -eq $extension.definition.name -and $_.definition.version -eq $extension.definition.version } |
  ForEach-Object { $_.contents.package = $package }

  $description = [System.Collections.ArrayList]::new()
  foreach ($lang in $recipe['supported-languages']) {
    $uri = "https://raw.githubusercontent.com/$($extension.contents.source.url)/$($extension.contents.source['github-sha'])/locale/description-$lang.md"
    $response = Invoke-WebRequest -Uri $uri -SkipHttpErrorCheck
    if ($response.StatusCode -eq 200) {
      $description.Add(
        @{
          language = $lang;
          method   = 'online';
          type     = "markdown";
          url      = "$uri";
        }
      )

      if ($lang -eq "en") {
        $description.Add(
          @{
            language = "default";
            method   = 'online';
            type     = "markdown";
            url      = "$uri";
          }
        ) | Out-Null
      }
    }
  }

  $store.extensions.list | 
  Where-Object { $_.definition.name -eq $extension.definition.name -and $_.definition.version -eq $extension.definition.version } |
  ForEach-Object { $_.contents.description = $description }

}

$store.timestamp = Get-Date -Format o
$store | ConvertTo-Yaml | New-Item -Path "build\store.yml" | Out-Null