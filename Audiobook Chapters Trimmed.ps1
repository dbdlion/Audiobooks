clear-host
# Trim-Audiobook-Chapters.ps1
# Removes 5 seconds from the end of every chapter.
# Rebuilds chapter markers and preserves audiobook metadata.

$InputFile = "C:\Users\Danny\Desktop\Books\Fixing\Tennis Shoes Among the Nephites 12 - Drums of desolation.m4b"
$OutputFile = "C:\Users\Danny\Desktop\Books\Fixing\Tennis Shoes Among the Nephites 12 - Drums of desolation - Trimmed.m4b"

$RemoveSeconds = 5
$AudioBitrate = "64k"
$SampleRate = 44100
$Channels = 1

$ErrorActionPreference = "Stop"
$culture = [Globalization.CultureInfo]::InvariantCulture

# Check the input.
if (-not (Test-Path -LiteralPath $InputFile)) {
    throw "Input file not found: $InputFile"
}

if ([IO.Path]::GetFullPath($InputFile) -eq
    [IO.Path]::GetFullPath($OutputFile)) {
    throw "Input and output files must be different."
}

# Read chapter timestamps and titles.
$probe = & ffprobe -v error -show_chapters -of json "$InputFile" |
    ConvertFrom-Json

if ($LASTEXITCODE -ne 0 -or -not $probe.chapters) {
    throw "Could not read chapter metadata."
}

$chapters = @($probe.chapters)

# Build the audio filter and output chapter metadata.
$filters = [System.Collections.Generic.List[string]]::new()
$labels = [System.Collections.Generic.List[string]]::new()
$metadata = [System.Collections.Generic.List[string]]::new()

$metadata.Add(";FFMETADATA1")
$offset = 0.0

function Escape-MetadataTitle([string]$Title) {
    $Title = $Title -replace '\\', '\\'
    $Title = $Title -replace '=', '\='
    $Title = $Title -replace ';', '\;'
    $Title = $Title -replace '#', '\#'
    $Title = $Title -replace '%', '\%'
    $Title = $Title -replace '[\r\n]', ' '
    return $Title
}

for ($i = 0; $i -lt $chapters.Count; $i++) {
    $chapter = $chapters[$i]
    $start = [double]$chapter.start_time
    $end = [double]$chapter.end_time
    $cutEnd = $end - $RemoveSeconds

    if (($cutEnd - $start) -lt 1) {
        throw "Chapter $($i + 1) is too short to trim safely."
    }

    $s = $start.ToString("0.#########", $culture)
    $e = $cutEnd.ToString("0.#########", $culture)

    $filters.Add(
        "[0:a:0]atrim=start=${s}:end=${e},asetpts=PTS-STARTPTS[a$i]"
    )
    $labels.Add("[a$i]")

    # Calculate new chapter positions in the shortened audiobook.
    $newStart = [long][Math]::Round($offset * 1000)
    $offset += ($cutEnd - $start)
    $newEnd = [long][Math]::Round($offset * 1000)

    $title = $chapter.tags.title
    if (-not $title) {
        $title = "Chapter $($i + 1)"
    }

    $metadata.Add("")
    $metadata.Add("[CHAPTER]")
    $metadata.Add("TIMEBASE=1/1000")
    $metadata.Add("START=$newStart")
    $metadata.Add("END=$newEnd")
    $metadata.Add("title=$(Escape-MetadataTitle $title)")
}

# Join all retained chapter audio into one continuous track.
$concat = ($labels -join "") +
    "concat=n=$($labels.Count):v=0:a=1[outa]"

$filter = ($filters -join ";") + ";" + $concat

$metaFile = Join-Path $env:TEMP (
    "AudiobookMetadata-" + [guid]::NewGuid().ToString() + ".txt"
)

try {
    [IO.File]::WriteAllLines(
        $metaFile,
        $metadata,
        [Text.UTF8Encoding]::new($false)
    )

    Write-Host "Chapters: $($chapters.Count)"
    Write-Host "Removing approximately $($chapters.Count * $RemoveSeconds) seconds."
    Write-Host "Expected duration: $([TimeSpan]::FromSeconds($offset))"
    Write-Host "Encoding once at 64 kbps AAC..."

    # Encode audio only once. Retain global metadata and chapter titles.
    & ffmpeg -hide_banner -y `
        -i "$InputFile" `
        -f ffmetadata -i "$metaFile" `
        -filter_complex "$filter" `
        -map "[outa]" `
        -map_metadata 0 `
        -map_chapters 1 `
        -c:a aac -b:a $AudioBitrate `
        -ar $SampleRate -ac $Channels `
        -movflags +faststart `
        "$OutputFile"

    if ($LASTEXITCODE -ne 0) {
        throw "FFmpeg failed to create the trimmed audiobook."
    }

    Write-Host "`nChecking output duration and chapters..."

    & ffprobe -v error `
        -show_entries format=duration,size `
        -show_entries chapter=start_time,end_time:chapter_tags=title `
        -of default=noprint_wrappers=1 `
        "$OutputFile"

    if ($LASTEXITCODE -ne 0) {
        throw "Output was created, but verification failed."
    }

    Write-Host "`nFinished: $OutputFile"
}
finally {
    Remove-Item $metaFile -Force -ErrorAction SilentlyContinue
}
