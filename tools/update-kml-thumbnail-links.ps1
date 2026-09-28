param(
  [string[]]$KmlFiles = @('scenes-github-links.kml'),
  [string]$BaseUrl = 'https://glaciators.github.io/Oblazowa-Cave-Paleo-Landscape',
  [string]$KmzSource = 'scenes-github-links.kml',
  [string]$KmzOutput = 'scenes-github-links.kmz',
  [switch]$SkipKmz
)

$ErrorActionPreference = 'Stop'

$dataRaw = Get-Content -Raw -Encoding UTF8 -LiteralPath 'data.js'
$match = [regex]::Match($dataRaw, '(?s)var\s+APP_DATA\s*=\s*(\{.*\});\s*$')
if (-not $match.Success) {
  throw 'Could not read APP_DATA from data.js'
}

$appData = $match.Groups[1].Value | ConvertFrom-Json
$sceneNames = @{}
$openPanoramaLabel = 'Open 360 panorama'
$markerIconFiles = [ordered]@{
  'present-day' = 'kml-link-green.png'
  'ba-13-ka' = 'kml-link-yellow.png'
  'lgm-24-ka' = 'kml-link-purple.png'
  'mis-3-41-ka' = 'kml-link-orange.png'
}
foreach ($scene in $appData.scenes) {
  $sceneNames[$scene.id] = $scene.name
}

function ConvertTo-HtmlAttribute {
  param([string]$Value)

  return $Value.
    Replace('&', '&amp;').
    Replace('"', '&quot;').
    Replace('<', '&lt;').
    Replace('>', '&gt;')
}

function ConvertTo-XmlText {
  param([string]$Value)

  return [System.Security.SecurityElement]::Escape($Value)
}

function New-Description {
  param(
    [string]$SceneId,
    [string]$SceneUrl
  )

  $thumbUrl = "$BaseUrl/img/kml-thumbnails/$SceneId.jpg"
  $alt = ConvertTo-HtmlAttribute ($sceneNames[$SceneId])

  return '<description><![CDATA[' +
    '<img src="' + $thumbUrl + '" alt="' + $alt + '" width="320" height="180" />' +
    '<br/><a href="' + $SceneUrl + '"><b>' + $openPanoramaLabel + '</b></a>' +
    ']]></description>'
}

foreach ($file in $KmlFiles) {
  if (-not (Test-Path -LiteralPath $file)) {
    Write-Warning "Skipping missing KML file: $file"
    continue
  }

  $content = Get-Content -Raw -Encoding UTF8 -LiteralPath $file
  $updated = [regex]::Replace($content, '(?s)<Placemark>(.*?)</Placemark>', {
    param($placemarkMatch)

    $placemark = $placemarkMatch.Value
    $urlMatch = [regex]::Match($placemark, '[?&]scene=([^"&<\]\s]+)')
    if (-not $urlMatch.Success) {
      return $placemark
    }

    $sceneId = $urlMatch.Groups[1].Value
    $sceneUrl = "$BaseUrl/?scene=$sceneId"
    $description = New-Description -SceneId $sceneId -SceneUrl $sceneUrl

    $sceneName = ConvertTo-XmlText ([string]$sceneNames[$sceneId])
    $placemark = [regex]::Replace($placemark, '(?s)<name>.*?</name>', "<name>$sceneName</name>", 1)

    $placemark = [regex]::Replace($placemark, '(?s)<description>.*?</description>', $description, 1)
    $escapedSceneUrl = ConvertTo-XmlText $sceneUrl
    return [regex]::Replace(
      $placemark,
      '(<Data name="scene_url"><value>).*?(</value></Data>)',
      ('$1' + $escapedSceneUrl + '$2'),
      1
    )
  })

  foreach ($styleId in $markerIconFiles.Keys) {
    $markerIconUrl = "$BaseUrl/img/$($markerIconFiles[$styleId])"
    $stylePattern = '(?s)(<Style id="' + [regex]::Escape($styleId) + '-(?:normal|highlight)">.*?<IconStyle>)(.*?)(</IconStyle>)'
    $updated = [regex]::Replace($updated, $stylePattern, {
      param($styleMatch)

      $iconStyle = $styleMatch.Groups[2].Value
      $iconStyle = [regex]::Replace($iconStyle, '(?s)<color>.*?</color>', '<color>d9ffffff</color>', 1)
      $iconStyle = [regex]::Replace(
        $iconStyle,
        '(?s)<Icon><href>.*?</href></Icon>',
        "<Icon><href>$markerIconUrl</href></Icon>",
        1
      )
      $iconStyle = $iconStyle.
        Replace('<scale>0.45</scale>', '<scale>0.85</scale>').
        Replace('<scale>0.58</scale>', '<scale>1.05</scale>').
        Replace('<scale>1.1</scale>', '<scale>0.85</scale>').
        Replace('<scale>1.7</scale>', '<scale>0.85</scale>').
        Replace('<scale>2.0</scale>', '<scale>1.05</scale>')

      if (-not $iconStyle.Contains('<hotSpot ')) {
        $hotSpot = '<hotSpot x="0.5" y="0.5" xunits="fraction" yunits="fraction"/>'
        $iconStyle += $hotSpot
      }

      return $styleMatch.Groups[1].Value + $iconStyle + $styleMatch.Groups[3].Value
    })
  }

  $targetPath = (Resolve-Path -LiteralPath $file).Path
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($targetPath, $updated, $utf8NoBom)
  Write-Output "Updated $file"
}

if (-not $SkipKmz) {
  if (-not (Test-Path -LiteralPath $KmzSource)) {
    throw "Could not create KMZ because the source KML is missing: $KmzSource"
  }

  $thumbnailDirectory = Join-Path (Get-Location) 'img\kml-thumbnails'
  $thumbnailFiles = @(Get-ChildItem -LiteralPath $thumbnailDirectory -File -Filter '*.jpg')
  if ($thumbnailFiles.Count -eq 0) {
    throw "Could not create KMZ because no thumbnails were found in: $thumbnailDirectory"
  }

  $markerIconPaths = @($markerIconFiles.Values | ForEach-Object { Join-Path (Get-Location) "img\$_" })
  $missingMarkerIcons = @($markerIconPaths | Where-Object { -not (Test-Path -LiteralPath $_) })
  if ($missingMarkerIcons.Count -gt 0) {
    throw "Could not create KMZ because KML marker icons are missing: $($missingMarkerIcons -join ', ')"
  }

  $buildDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("kml-thumbnails-" + [guid]::NewGuid().ToString('N'))
  $archivePath = Join-Path ([System.IO.Path]::GetTempPath()) ("kml-thumbnails-" + [guid]::NewGuid().ToString('N') + '.zip')

  try {
    $embeddedThumbnailDirectory = Join-Path $buildDirectory 'img\kml-thumbnails'
    New-Item -ItemType Directory -Path $embeddedThumbnailDirectory -Force | Out-Null

    $docKml = Get-Content -Raw -Encoding UTF8 -LiteralPath $KmzSource
    [System.IO.File]::WriteAllText((Join-Path $buildDirectory 'doc.kml'), $docKml, $utf8NoBom)

    Copy-Item -LiteralPath $thumbnailFiles.FullName -Destination $embeddedThumbnailDirectory
    Copy-Item -LiteralPath $markerIconPaths -Destination (Join-Path $buildDirectory 'img')
    Compress-Archive -Path (Join-Path $buildDirectory '*') -DestinationPath $archivePath -CompressionLevel Optimal

    $kmzTarget = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $KmzOutput))
    Move-Item -LiteralPath $archivePath -Destination $kmzTarget -Force
    Write-Output "Created $KmzOutput with $($markerIconPaths.Count) marker icons and $($thumbnailFiles.Count) embedded thumbnails"
  }
  finally {
    if (Test-Path -LiteralPath $buildDirectory) {
      Remove-Item -LiteralPath $buildDirectory -Recurse -Force
    }
    if (Test-Path -LiteralPath $archivePath) {
      Remove-Item -LiteralPath $archivePath -Force
    }
  }
}
