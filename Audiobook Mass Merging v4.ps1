Clear-Host
$Root = "C:\Users\Danny\Desktop\Books\Audiobooks\"

$StartTime = Get-Date
$Results = @()

$Temp = "$env:TEMP\ffmpeg_audiobook"
New-Item -ItemType Directory -Force -Path $Temp | Out-Null


# Patterns for detecting "disc" subfolders within a book folder.
$DiscFolderPatterns = @(
    '^CD[\s_\-]?0*(\d+)$',
    '^Disc[\s_\-]?0*(\d+)$',
    '^Part[\s_\-]?0*(\d+)$'
)


function Sort-Naturally {
    param([Parameter(ValueFromPipeline)]$InputObject)

    begin { $items = @() }

    process { $items += $InputObject }

    end {
        $items | Sort-Object {
            [regex]::Replace($_.Name, '\d+', {
                param($match)
                $match.Value.PadLeft(20, '0')
            })
        }
    }
}





function Get-DiscNumber {
    param($Name)
    foreach ($pattern in $DiscFolderPatterns) {
        if ($Name -match $pattern) {
            return [int]$Matches[1]
        }
    }
    return $null
}


$folders = Get-ChildItem $Root -Directory
#$folders = Get-ChildItem $Root -Recurse -Directory


foreach ($folder in $folders) {

    $status = ""
    $book = $folder.Name
    $totalBitrate = 0
    $audioCount = 0

    try {

        Write-Host ""
        Write-Host "Scanning:" $folder.FullName -ForegroundColor Cyan

        Get-ChildItem $folder.FullName -File | Rename-Item -NewName {
            $_.Name -replace "[’']", ""
        }



        $discFolders = Get-ChildItem $folder.FullName -Directory -ErrorAction SilentlyContinue |
            Where-Object { (Get-DiscNumber $_.Name) -ne $null } |
            Sort-Object { Get-DiscNumber $_.Name }

        if ($discFolders.Count -gt 0) {
            Write-Host "  Found $($discFolders.Count) disc folder(s): $($discFolders.Name -join ', ')" -ForegroundColor DarkGray

            $audio = foreach ($disc in $discFolders) {
                Get-ChildItem $disc.FullName -File | Where-Object {
                    $_.Extension -match "\.(mp3|m4a|aac|wav)$"
                } | Sort-Naturally
            }
            $m4b = @()
        }
        else {
            $m4b = Get-ChildItem $folder.FullName -File -Filter *.m4b
            $audio = Get-ChildItem $folder.FullName -File | Where-Object {
                $_.Extension -match "\.(mp3|m4a|aac|wav)$"
            } | Sort-Naturally
        }



        <#
        $m4b = Get-ChildItem $folder.FullName -File -Filter *.m4b
        $audio = Get-ChildItem $folder.FullName -File | Where-Object {
            $_.Extension -match "\.(mp3|m4a|aac|wav)$"
        } | Sort-Object Name
        #>


        
        # CASE — multiple existing M4B files (ex: Part 1 / Part 2)
        if ($m4b.Count -gt 1) {
            Write-Host $m4b.Count " M4B Files to Process"

            $files = "$Temp\files.txt"

            $m4b | Sort-Object Name | ForEach-Object {
                "file '$($_.FullName)'"
            } | Set-Content $files -Encoding ASCII

            $output = Join-Path $Root ($folder.Name + ".m4b")

            ffmpeg -loglevel error -y -f concat -safe 0 -i $files -c copy "$output" | Out-Null

            Write-Host "Merged multi-part M4B"
        }
        elseif ($m4b.Count -eq 1 -and $audio.Count -eq 0) {

            $dest = Join-Path $Root $m4b[0].Name
            Move-Item $m4b[0].FullName $dest -Force

            Write-Host "Moved existing M4B"
        }

        elseif ($audio.Count -eq 1) {

            Write-Host "Skipped (only one audio file)"
        }

        elseif ($audio.Count -gt 1) {

            Write-Host $audio.Count " Audio Files to Process"

            $files = "$Temp\files.txt"
            $chapters = "$Temp\chapters.txt"

            $audio | ForEach-Object {
                "file '" + ($_.FullName -replace "'", "'\''") + "'"
            } | Set-Content $files -Encoding ASCII

            $start = 0
            $lines = @(";FFMETADATA1")

            foreach ($a in $audio) {

                $duration = & ffprobe -v error -show_entries format=duration `
                -of default=noprint_wrappers=1:nokey=1 "$($a.FullName)"

                $duration = [double]$duration
                $end = $start + $duration

                $lines += "[CHAPTER]"
                $lines += "TIMEBASE=1/1000"
                $lines += "START=$([math]::Round($start*1000))"
                $lines += "END=$([math]::Round($end*1000))"
                $lines += "title=$($a.BaseName)"

                $start = $end

                $br = & ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$($a.FullName)"

                if ($br) {
                    $totalBitrate += [int]$br
                    $count++
                }

            }

            $avgBitrate = ($totalBitrate / $count) / 1000
            $lines | Set-Content $chapters -Encoding ASCII

            $output = Join-Path $Root ($folder.Name + ".m4b")

            #ffmpeg -loglevel error -y -f concat -safe 0 -i $files -i $chapters -map_metadata 1 -c:a aac -q:a 0.35 -ac 1 -movflags +faststart "$output" | Out-Null
            #ffmpeg -loglevel error -y -f concat -safe 0 -i $files -i $chapters -map_metadata 1 -c:a aac -b:a 64k -ac 1 -movflags +faststart "$output" | Out-Null

            if ($encodeMode -eq "copy") {
#                ffmpeg -loglevel error -y -f concat -safe 0 -i $files -i $chapters -map_metadata 1 -c:a copy -movflags +faststart "$output" | Out-Null
                ffmpeg -loglevel error -y -f concat -safe 0 -i $files -i $chapters -map 0:a -map_metadata 1 -c:a copy -movflags +faststart "$output" | Out-Null
            }
            else {
#                ffmpeg -loglevel error -y -f concat -safe 0 -i $files -i $chapters -map_metadata 1 -c:a aac -b:a 64k -ac 1 -movflags +faststart "$output" | Out-Null
                ffmpeg -loglevel error -y -f concat -safe 0 -i $files -i $chapters -map 0:a -map_metadata 1 -c:a aac -b:a 64k -ac 1 -movflags +faststart "$output" | Out-Null
            }


            if (Test-Path $output) {
                $status = "Created audiobook"
            }
            else {
                $status = "ERROR during encoding"
            }
        }
        else {

            $status = "No audio found"
        }

    }
    catch {

        $status = "ERROR: $($_.Exception.Message)"
    }

    $Results += [PSCustomObject]@{
        Book = $book
        Status = $status
    }

}


#####################################################################################################################
## Single Loose Mp3 or similar files

$looseFiles = Get-ChildItem $Root -File | Where-Object {
    $_.Extension -match "\.(mp3|m4a|aac|wav)$"
}

foreach ($file in $looseFiles) {

    $status = ""
    $book = $file.BaseName

    try {
        Write-Host ""
        Write-Host "Scanning (loose file):" $file.FullName -ForegroundColor Cyan

        $output = Join-Path $Root ($file.BaseName + ".m4b")

        if ($encodeMode -eq "copy") {
#            ffmpeg -loglevel error -y -i "$($file.FullName)" -c:a copy -movflags +faststart "$output" | Out-Null
            ffmpeg -loglevel error -y -i "$($file.FullName)" -map 0:a -c:a copy -movflags +faststart "$output" | Out-Null
        }
        else {
#            ffmpeg -loglevel error -y -i "$($file.FullName)" -c:a aac -b:a 64k -ac 1 -movflags +faststart "$output" | Out-Null
            ffmpeg -loglevel error -y -i "$($file.FullName)" -map 0:a -c:a aac -b:a 64k -ac 1 -movflags +faststart "$output" | Out-Null
        }

        if (Test-Path $output) {
            $status = "Converted single file to audiobook"
        }
        else {
            $status = "ERROR during encoding"
        }
    }
    catch {
        $status = "ERROR: $($_.Exception.Message)"
    }

    $Results += [PSCustomObject]@{
        Book = $book
        Status = $status
    }
}

#####################################################################################################################

$EndTime = Get-Date
$Duration = $EndTime - $StartTime

Write-Host ""
Write-Host "===== Audiobook Batch Report =====" -ForegroundColor Cyan

$Results | Format-Table -AutoSize

$created = ($Results | Where-Object {$_.Status -eq "Created audiobook"}).Count
$moved = ($Results | Where-Object {$_.Status -eq "Moved existing M4B"}).Count
$skipped = ($Results | Where-Object {$_.Status -like "Skipped*"}).Count
$errors = ($Results | Where-Object {$_.Status -like "ERROR*"}).Count
$converted = ($Results | Where-Object {$_.Status -eq "Converted single file to audiobook"}).Count

Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "Books created: $created"
Write-Host "Books converted: $converted"
Write-Host "Existing M4B moved: $moved"
Write-Host "Skipped: $skipped"
Write-Host "Errors: $errors"
Write-Host "Total folders processed: $($Results.Count)"
Write-Host "Total runtime: $($Duration.ToString())"