###############################################################################################
       # Set to $true for Failback Configuration, $false for Failover operation

       $Failback = $false

       ##############################################################################################
       
       ################################################################################################
                                      # Configuration Section
       ################################################################################################
       
       # Paths Configuration
       $scanDirsFilePath = "C:\Testing\path.txt"                                             # Path to file containing directories or file paths to scan
       $csvFilePath = "C:\Testing\replacements.csv"                                          # Path to replacements CSV file
       $backupDir = if ($Failback) { "C:\DR_Files\DR" } else { "C:\DR_Files\Prod" }          # Backup directory based on Failback
       $logDir = "C:\DR_Logs"                                                                # Log directory
       $logFileName = "script_log_" + (Get-Date -Format "yyyyMMdd") + ".log"                 # Log file name
       $logFilePath = Join-Path -Path $logDir -ChildPath $logFileName                        # Full log file path
       
       ################################################################################################
                                         # Initialization Section
       ################################################################################################
       
       # Initialize the scanDirs array by reading paths from the external file
       $scanDirs = @()
       if (Test-Path $scanDirsFilePath) {
           $scanDirs = Get-Content -Path $scanDirsFilePath | Where-Object { $_ -ne "" }      # Exclude empty lines
       } else {
           Write-Host "Scan directories file not found: $scanDirsFilePath" -ForegroundColor Red
           exit 1  # Exit if scan directories file is not found
       }
       
       # Import data from CSV into the hashtable for replacements
       $replacements = @{}
       if (Test-Path $csvFilePath) {
           $csvData = Import-Csv -Path $csvFilePath
           foreach ($row in $csvData) {
               $replacements[$row.prd] = $row.dr  # Use 'prd' and 'dr' as keys
           }
       } else {
           Write-Host "Replacements CSV file not found: $csvFilePath" -ForegroundColor Red
           exit 1  # Exit if replacements file is not found
       }
       
       # Create necessary directories once at the start
       $dirsToCreate = @($backupDir, $logDir)
       foreach ($dir in $dirsToCreate) {
           if (-not (Test-Path $dir)) {
               New-Item -Path $dir -ItemType Directory | Out-Null
           }
       }
       
       # Initialize log file and message based on the operation mode
       Add-Content -Path $logFilePath -Value "`n---------------------------------$(if ($Failback) {'Failback'} else {'Failover'})--------------------------------`n"
       
       ################################################################################################
                                         # Log Function Section
       ################################################################################################
       
       function Log-Message {
           param (
               [string]$message,
               [string]$level = "INFO"
           )
           $actionType = if ($Failback) { "Failback" } else { "Fail-over" }
           return "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) [$level] [$actionType] - $message"
       }
       
       ################################################################################################
                                       # Replacement Functions Section
       ################################################################################################
       
       function Perform-Replacements {
           param (
               [string]$filePath,
               [hashtable]$replacements,
               [bool]$reverse
           )
       
           # Read the content of the file once and prepare for replacements
           $content = Get-Content -Path $filePath -Raw
       
           # Prepare a list to track changes made
           $changeLog = @()
       
           foreach ($oldText in $replacements.Keys) {
               # Determine the replacement text based on reverse flag
               if ($reverse) {
                   if ($content -match [regex]::Escape($replacements[$oldText])) {
                       $content = $content -replace [regex]::Escape($replacements[$oldText]), $oldText
                       $changeLog += "$($replacements[$oldText]) -> $oldText"
                   }
               } else {
                   if ($content -match [regex]::Escape($oldText)) {
                       $content = $content -replace [regex]::Escape($oldText), $replacements[$oldText]
                       $changeLog += "$oldText -> $($replacements[$oldText])"
                   }
               }
           }
       
           # Only write back to file if changes were made
           if ($changeLog.Count -gt 0) {
               # Backup the original file before replacing content, only if changes occurred
               Copy-Item -Path $filePath -Destination (Join-Path -Path $backupDir -ChildPath (Split-Path -Leaf $filePath)) -Force
               
               # Write updated content back to the file in one go
               Set-Content -Path $filePath -Value $content
               
               # Log the update action with changes made in a single write operation.
               Add-Content -Path $logFilePath -Value (Log-Message "Updated file: $filePath || Changes: $(($changeLog -join ' & '))")
               Write-Host "Updated file: $filePath || Changes: $(($changeLog -join ' & '))" -ForegroundColor Green
           }
       }
       
       function Process-FilesInDirectory {
           param (
               [string]$directory,
               [hashtable]$replacements,
               [bool]$Failback
           )
       
           # Get all files once, process them in memory, and group by name for efficiency.
           Get-ChildItem -Path $directory -Recurse -File | 
           Group-Object Name | 
           ForEach-Object {
               # Find and process the most recently modified file in each group of files with the same name.
               $_.Group | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | 
               ForEach-Object {
                   Perform-Replacements -filePath $_.FullName -replacements $replacements -reverse $Failback
               }
           }
       }
       
       ################################################################################################
                                      # Main Execution Block Section
       ################################################################################################
       
       foreach ($scanDir in $scanDirs) {
           if (Test-Path $scanDir) {
               $item = Get-Item $scanDir
               if ($item.PSIsContainer) {
                   # Process all files in the directory recursively
                   Write-Host "Processing directory: $scanDir" -ForegroundColor Yellow
                   Process-FilesInDirectory -directory $scanDir -replacements $replacements -Failback $Failback
               } elseif (-not $item.PSIsContainer) {
                   # Process a single file
                   Write-Host "Processing file: $scanDir" -ForegroundColor Yellow
                   Perform-Replacements -filePath $scanDir -replacements $replacements -reverse $Failback
               } else {
                   Write-Host "Unknown item type: $scanDir" -ForegroundColor Red
               }
           } else {
               # Log and notify for invalid paths
               $errorMsg = "Path not found or invalid: $scanDir"
               Add-Content -Path $logFilePath -Value (Log-Message $errorMsg "ERROR")
               Write-Host $errorMsg -ForegroundColor Red
           }
       }
       