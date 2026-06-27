<#
ComfyUI-PNG-Meta.ps1
v3.6
Extracts useful ComfyUI generation metadata from PNG tEXt/iTXt/zTXt chunks.
Outputs HTML with per-row copy buttons, plain text, JSON, or a single field for Directory Opus columns.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [ValidateSet('Html','Text','Json','Field','Dump')]
    [string]$Output = 'Html',

    [string]$Field = '',

    [switch]$Open,
    [switch]$Copy
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-PropValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function First-NotBlank {
    param([object[]]$Values)
    foreach ($v in $Values) {
        if ($null -ne $v) {
            $s = [string]$v
            if ($s.Trim().Length -gt 0) { return $s }
        }
    }
    return ''
}


function Display-Value {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'N/A' }
    return $Text
}

function To-CleanString {
    param($Value)
    if ($null -eq $Value) { return '' }
    if (Is-RefArray $Value) { return '' }
    if ($Value -is [System.Array]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Value) {
            if ($null -ne $item -and -not (Is-RefArray $item)) {
                $s = ([string]$item).Trim()
                if ($s.Length -gt 0) { [void]$parts.Add($s) }
            }
        }
        return ($parts.ToArray() -join ', ')
    }
    return ([string]$Value).Trim()
}

function Normalize-SeedString {
    param([string]$Seed)
    if ([string]::IsNullOrWhiteSpace($Seed)) { return '' }
    $s = $Seed.Trim()
    # If a ComfyUI linked input leaked through as something like "28 0", it is a node/output reference,
    # not the real seed. The resolver below should normally prevent this, but strip whitespace for true
    # numeric seeds just in case PowerShell has joined digits with spaces.
    if ($s -match '^\d[\d\s]*$') { return ($s -replace '\s+', '') }
    return $s
}

function Get-ResolvedValueFromInputs {
    param($Prompt, $Inputs, [string[]]$Names, [int]$Depth = 0)
    if ($null -eq $Inputs) { return '' }
    foreach ($name in $Names) {
        $v = Get-PropValue $Inputs $name
        $r = Resolve-ComfyValue $Prompt $v $Names ($Depth + 1)
        if (-not [string]::IsNullOrWhiteSpace($r)) { return $r }
    }
    return ''
}

function Resolve-ComfyValue {
    param($Prompt, $Value, [string[]]$PreferredKeys, [int]$Depth = 0)
    if ($Depth -gt 6) { return '' }
    if ($null -eq $Value) { return '' }

    if (-not (Is-RefArray $Value)) {
        return (To-CleanString $Value)
    }

    $nodeId = Get-RefId $Value
    $node = Get-NodeById $Prompt $nodeId
    if ($null -eq $node) { return '' }

    $inputs = Get-PropValue $node 'inputs'
    $genericKeys = @(
        'seed','noise_seed','rand_seed','value','int','integer','number','float','text','string',
        'ckpt_name','unet_name','model_name','diffusion_model','gguf_name','model',
        'clip_name','clip_name1','clip_name2','clip_name3','t5_name','bert_name','text_encoder_name',
        'sampler_name','sampler','samplername','scheduler','scheduler_name','steps','total_steps','cfg','cfg_scale','guidance'
    )
    $keys = @($PreferredKeys + $genericKeys) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    if ($null -ne $inputs) {
        foreach ($key in $keys) {
            $candidate = Get-PropValue $inputs $key
            if ($null -ne $candidate -and -not (Is-RefArray $candidate)) {
                $s = To-CleanString $candidate
                if ($s.Length -gt 0) { return $s }
            }
        }

        foreach ($prop in $inputs.PSObject.Properties) {
            if (Is-RefArray $prop.Value) {
                $r = Resolve-ComfyValue $Prompt $prop.Value $PreferredKeys ($Depth + 1)
                if (-not [string]::IsNullOrWhiteSpace($r)) { return $r }
            }
        }
    }

    $widgets = Get-PropValue $node 'widgets_values'
    if ($null -ne $widgets -and $widgets -is [System.Array]) {
        foreach ($w in $widgets) {
            if ($null -ne $w -and -not (Is-RefArray $w)) {
                $s = To-CleanString $w
                if ($s.Length -gt 0) { return $s }
            }
        }
    }

    return ''
}

function Convert-BEUInt32 {
    param([byte[]]$Bytes, [int]$Offset)
    return [uint32]((([uint32]$Bytes[$Offset]) -shl 24) -bor (([uint32]$Bytes[$Offset+1]) -shl 16) -bor (([uint32]$Bytes[$Offset+2]) -shl 8) -bor ([uint32]$Bytes[$Offset+3]))
}

function Get-NullIndex {
    param([byte[]]$Bytes, [int]$Start)
    for ($i = $Start; $i -lt $Bytes.Length; $i++) {
        if ($Bytes[$i] -eq 0) { return $i }
    }
    return -1
}

function Get-SubBytes {
    param([byte[]]$Bytes, [int]$Offset, [int]$Length)
    if ($Length -le 0) { return [byte[]]@() }
    $out = New-Object byte[] $Length
    [Array]::Copy($Bytes, $Offset, $out, 0, $Length)
    return $out
}

function Expand-ZlibBytes {
    param([byte[]]$Bytes)
    if ($Bytes.Length -lt 6) { return [byte[]]@() }

    # PNG zTXt/iTXt compression is zlib-wrapped deflate. Windows PowerShell 5's
    # DeflateStream expects raw deflate, so skip the common 2-byte zlib header and
    # 4-byte Adler checksum. Works for normal PNG text chunks.
    $ms = $null; $ds = $null; $out = $null
    try {
        $ms = New-Object System.IO.MemoryStream(,$Bytes)
        $ms.Position = 2
        $trimmedLen = [Math]::Max(0, $Bytes.Length - 6)
        $deflateData = Get-SubBytes $Bytes 2 $trimmedLen
        $deflateStream = New-Object System.IO.MemoryStream(,$deflateData)
        $ds = New-Object System.IO.Compression.DeflateStream($deflateStream, [System.IO.Compression.CompressionMode]::Decompress)
        $out = New-Object System.IO.MemoryStream
        $buffer = New-Object byte[] 8192
        while (($read = $ds.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $out.Write($buffer, 0, $read)
        }
        return $out.ToArray()
    }
    catch {
        return [byte[]]@()
    }
    finally {
        if ($null -ne $ds) { $ds.Dispose() }
        if ($null -ne $out) { $out.Dispose() }
        if ($null -ne $ms) { $ms.Dispose() }
    }
}

function Read-PngTextChunks {
    param([string]$FilePath)

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "File not found: $FilePath"
    }

    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    if ($bytes.Length -lt 12) { throw 'File is too small to be a PNG.' }

    $sig = @(137,80,78,71,13,10,26,10)
    for ($i = 0; $i -lt $sig.Count; $i++) {
        if ($bytes[$i] -ne $sig[$i]) { throw 'Not a PNG file.' }
    }

    $latin1 = [System.Text.Encoding]::GetEncoding('ISO-8859-1')
    $utf8 = [System.Text.Encoding]::UTF8
    $ascii = [System.Text.Encoding]::ASCII
    $chunks = [ordered]@{}
    $offset = 8

    # Read image dimensions from the IHDR chunk (always first in a valid PNG).
    # Signature (8) + chunk_length (4) + chunk_type (4) + width (4) + height (4) = 24 bytes minimum.
    if ($bytes.Length -ge 24 -and $ascii.GetString($bytes, 12, 4) -eq 'IHDR') {
        $chunks['_Width']  = Convert-BEUInt32 $bytes 16
        $chunks['_Height'] = Convert-BEUInt32 $bytes 20
    }

    while ($offset + 12 -le $bytes.Length) {
        $len = [int](Convert-BEUInt32 $bytes $offset)
        $offset += 4
        if ($offset + 4 + $len + 4 -gt $bytes.Length) { break }
        $type = $ascii.GetString($bytes, $offset, 4)
        $offset += 4
        $data = Get-SubBytes $bytes $offset $len
        $offset += $len
        $offset += 4 # CRC

        if ($type -eq 'IEND') { break }

        if ($type -eq 'tEXt') {
            $nul = Get-NullIndex $data 0
            if ($nul -gt 0) {
                $key = $latin1.GetString($data, 0, $nul)
                $val = $latin1.GetString($data, $nul + 1, $data.Length - $nul - 1)
                $chunks[$key] = $val
            }
        }
        elseif ($type -eq 'zTXt') {
            $nul = Get-NullIndex $data 0
            if ($nul -gt 0 -and $nul + 2 -lt $data.Length) {
                $key = $latin1.GetString($data, 0, $nul)
                $compressed = Get-SubBytes $data ($nul + 2) ($data.Length - $nul - 2)
                $plain = Expand-ZlibBytes $compressed
                if ($plain.Length -gt 0) { $chunks[$key] = $latin1.GetString($plain) }
            }
        }
        elseif ($type -eq 'iTXt') {
            # keyword\0 compression_flag compression_method language_tag\0 translated_keyword\0 text
            $p = 0
            $nul1 = Get-NullIndex $data $p
            if ($nul1 -lt 1) { continue }
            $key = $latin1.GetString($data, $p, $nul1 - $p)
            $p = $nul1 + 1
            if ($p + 2 -gt $data.Length) { continue }
            $compressedFlag = $data[$p]; $p++
            $compressionMethod = $data[$p]; $p++
            $nul2 = Get-NullIndex $data $p
            if ($nul2 -lt 0) { continue }
            $p = $nul2 + 1
            $nul3 = Get-NullIndex $data $p
            if ($nul3 -lt 0) { continue }
            $p = $nul3 + 1
            if ($p -gt $data.Length) { continue }
            $textBytes = Get-SubBytes $data $p ($data.Length - $p)
            if ($compressedFlag -eq 1 -and $compressionMethod -eq 0) {
                $textBytes = Expand-ZlibBytes $textBytes
            }
            if ($textBytes.Length -gt 0) { $chunks[$key] = $utf8.GetString($textBytes) }
        }
    }

    return $chunks
}

function Is-RefArray {
    param($Value)
    if ($null -eq $Value) { return $false }
    if (-not ($Value -is [System.Array])) { return $false }
    if ($Value.Length -lt 2) { return $false }
    if ($null -eq $Value[0] -or $null -eq $Value[1]) { return $false }
    # ComfyUI link references are [node_id, output_index]. Be stricter than older
    # versions so normal arrays do not get mistaken for node links.
    $outIndex = 0
    return [int]::TryParse(([string]$Value[1]), [ref]$outIndex)
}

function Get-RefId {
    param($Value)
    if (Is-RefArray $Value) { return [string]$Value[0] }
    return ''
}

function Get-NodeById {
    param($Prompt, [string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    $p = $Prompt.PSObject.Properties[$Id]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Collect-TextsFromNode {
    param($Prompt, [string]$Id, [hashtable]$Seen)

    if ([string]::IsNullOrWhiteSpace($Id)) { return @() }
    if ($Seen.ContainsKey($Id)) { return @() }
    $Seen[$Id] = $true

    $node = Get-NodeById $Prompt $Id
    if ($null -eq $node) { return @() }
    $inputs = Get-PropValue $node 'inputs'
    if ($null -eq $inputs) { return @() }

    $texts = New-Object System.Collections.Generic.List[string]
    foreach ($key in @('text','text_g','text_l','prompt','positive','negative')) {
        $v = Get-PropValue $inputs $key
        if ($null -ne $v -and -not (Is-RefArray $v)) {
            $s = [string]$v
            if ($s.Trim().Length -gt 0 -and $texts.Contains($s) -eq $false) { [void]$texts.Add($s) }
        }
    }

    if ($texts.Count -gt 0) { return @($texts.ToArray()) }

    foreach ($prop in $inputs.PSObject.Properties) {
        $v = $prop.Value
        if (Is-RefArray $v) {
            $child = Get-RefId $v
            foreach ($t in (Collect-TextsFromNode $Prompt $child $Seen)) {
                if ($t.Trim().Length -gt 0 -and $texts.Contains($t) -eq $false) { [void]$texts.Add($t) }
            }
        }
    }
    return @($texts.ToArray())
}

function Join-Unique {
    param([object[]]$Values, [string]$Separator = ', ')
    $seen = @{}
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($v in $Values) {
        if ($null -eq $v) { continue }
        $s = ([string]$v).Trim()
        if ($s.Length -eq 0) { continue }
        $k = $s.ToLowerInvariant()
        if (-not $seen.ContainsKey($k)) {
            $seen[$k] = $true
            [void]$out.Add($s)
        }
    }
    return ($out.ToArray() -join $Separator)
}


function Is-KnownNonLoraToken {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $s = $Text.Trim().ToLowerInvariant()
    if ($s -match '^#[0-9a-f]{3,8}$') { return $true }
    if ($s -match '^(none|n/a|na|null|false|true|on|off|enabled|disabled|enable|disable|bypass|mute|yes|no|randomize|fixed|increment|decrement)$') { return $true }
    if ($s -match '^(model|clip|vae|positive|negative|image|latent|conditioning|sampler|scheduler|seed|steps|cfg|denoise)$') { return $true }
    if ($s -match '^(simple|normal|karras|exponential|sgm_uniform|beta|linear_quadratic|ddim_uniform|ays|align_your_steps)$') { return $true }
    if ($s -match '^(euler|euler_ancestral|euler a|heun|heunpp2|lms|ddim|uni_pc|uni_pc_bh2|dpm_fast|dpm_adaptive|dpm_2|dpm_2_ancestral|dpmpp_2s_ancestral|dpmpp_sde|dpmpp_sde_gpu|dpmpp_2m|dpmpp_2m_sde|dpmpp_2m_sde_gpu|dpmpp_3m_sde|dpmpp_3m_sde_gpu)$') { return $true }
    return $false
}

function Is-LoraNameCandidate {
    param([string]$Text, [string]$Context = '')
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $s = $Text.Trim()
    $lower = $s.ToLowerInvariant()
    if (Is-KnownNonLoraToken $s) { return $false }
    if (Is-NumericLike $s) { return $false }

    # Real LoRA files are overwhelmingly safetensors/pt/pth. Do not accept gguf/ckpt/bin here;
    # those are usually diffusion models or text encoders and caused false LoRA rows.
    if ($s -match '(?i)\.(safetensors|pt|pth)$') { return $true }

    if ($Context -match '(?i)(lora|lyco|lycoris)') {
        # Custom LoRA loaders sometimes store display names without an extension.
        # Keep this deliberately tight so sampler names, prompt chunks, models and colours do not get swallowed.
        if ($s.Length -ge 3 -and $s.Length -le 120 -and $s -notmatch '[{}<>,;|]' -and $s -notmatch '\s' -and $s -notmatch '^[A-Za-z_]+\s*:$') { return $true }
    }
    return $false
}

function Get-LoraSuffixFromKey {
    param([string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return '' }
    $m = [regex]::Match($Key, '(?:_|-)?(?<suffix>\d+)$')
    if ($m.Success) { return $m.Groups['suffix'].Value }
    return ''
}

function Get-ResolvedInputString {
    param($Prompt, $Inputs, [string]$Key, [string[]]$PreferredKeys = @())
    if ($null -eq $Inputs -or [string]::IsNullOrWhiteSpace($Key)) { return '' }
    $v = Get-PropValue $Inputs $Key
    if ($null -eq $v) { return '' }
    $keys = @($Key) + $PreferredKeys
    return (Resolve-ComfyValue $Prompt $v $keys 0)
}

function Get-LoraStrengthsFromInputs {
    param($Prompt, $Inputs, [string]$Suffix = '')

    $modelKeys = New-Object System.Collections.Generic.List[string]
    $clipKeys = New-Object System.Collections.Generic.List[string]
    $singleKeys = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($Suffix)) {
        foreach ($k in @("strength_model_$Suffix", "model_strength_$Suffix", "model_weight_$Suffix", "lora_model_strength_$Suffix", "lora_model_weight_$Suffix")) { [void]$modelKeys.Add($k) }
        foreach ($k in @("strength_clip_$Suffix", "clip_strength_$Suffix", "clip_weight_$Suffix", "lora_clip_strength_$Suffix", "lora_clip_weight_$Suffix")) { [void]$clipKeys.Add($k) }
        foreach ($k in @("strength_$Suffix", "lora_strength_$Suffix", "weight_$Suffix", "lora_weight_$Suffix")) { [void]$singleKeys.Add($k) }
    }

    foreach ($k in @('strength_model','model_strength','model_weight','lora_model_strength','lora_model_weight','model_str')) { [void]$modelKeys.Add($k) }
    foreach ($k in @('strength_clip','clip_strength','clip_weight','lora_clip_strength','lora_clip_weight','clip_str')) { [void]$clipKeys.Add($k) }
    foreach ($k in @('strength','lora_strength','weight','lora_weight','strength_text_encoder','te_strength')) { [void]$singleKeys.Add($k) }

    $sm = ''
    foreach ($k in $modelKeys) {
        $sm = Get-ResolvedInputString $Prompt $Inputs $k @('strength_model','model_strength','model_weight','strength','weight','value')
        if (-not [string]::IsNullOrWhiteSpace($sm)) { break }
    }

    $sc = ''
    foreach ($k in $clipKeys) {
        $sc = Get-ResolvedInputString $Prompt $Inputs $k @('strength_clip','clip_strength','clip_weight','strength','weight','value')
        if (-not [string]::IsNullOrWhiteSpace($sc)) { break }
    }

    $single = ''
    foreach ($k in $singleKeys) {
        $single = Get-ResolvedInputString $Prompt $Inputs $k @('strength','weight','value')
        if (-not [string]::IsNullOrWhiteSpace($single)) { break }
    }

    if ([string]::IsNullOrWhiteSpace($sm) -and -not [string]::IsNullOrWhiteSpace($single)) { $sm = $single }
    return [pscustomobject]@{ Model = $sm; Clip = $sc; Single = $single }
}

function Format-LoraRow {
    param([string]$Name, [string]$ModelStrength = '', [string]$ClipStrength = '')
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $n = $Name.Trim()
    $sm = ([string]$ModelStrength).Trim()
    $sc = ([string]$ClipStrength).Trim()
    if ($sm.Length -gt 0 -and $sc.Length -gt 0) { return "$n (model $sm, clip $sc)" }
    if ($sm.Length -gt 0) { return "$n ($sm)" }
    if ($sc.Length -gt 0) { return "$n (clip $sc)" }
    return $n
}

function Add-LoraRow {
    param($Rows, [string]$Name, [string]$ModelStrength = '', [string]$ClipStrength = '')
    if ([string]::IsNullOrWhiteSpace($Name)) { return }

    # Last-ditch guardrail: never let sampler/scheduler/UI tokens leak into the LoRA field.
    # This is deliberately placed at the final add point so every parser path gets protected,
    # including weird custom nodes that flatten their widgets into anonymous arrays.
    $cleanName = $Name.Trim()
    if (Is-KnownNonLoraToken $cleanName) { return }
    if ($cleanName -match '(?i)\.(gguf|ckpt|bin)$') { return }
    if ($cleanName -match '^#[0-9a-fA-F]{3,8}$') { return }

    $row = Format-LoraRow $cleanName $ModelStrength $ClipStrength
    if (-not [string]::IsNullOrWhiteSpace($row)) { [void]$Rows.Add($row) }
}


function Test-No8dLoraClass {
    param([string]$Class)
    if ([string]::IsNullOrWhiteSpace($Class)) { return $false }
    return ($Class -match '(?i)(NO8D.*Slider.*LoRA|NO8D\s*-\s*Slider\s+LoRA?\s+Stack|NO8D[-_\s]*LoRA?[-_\s]*Stack|NO8DLoraStack|Slider\s*LoRA?\s*Stack|SliderLoraStack)')
}

function Test-RgthreePowerLoraClass {
    param([string]$Class)
    if ([string]::IsNullOrWhiteSpace($Class)) { return $false }
    return ($Class -match '(?i)(Power\s+LoRA?\s+Loader.*rgthree|Power\s+Lora\s+Loader.*rgthree)')
}

function Test-TargetCustomLoraClass {
    param([string]$Class)
    if ([string]::IsNullOrWhiteSpace($Class)) { return $false }
    return ((Test-RgthreePowerLoraClass $Class) -or (Test-No8dLoraClass $Class))
}

function Test-NonLoraSamplerLikeClass {
    param([string]$Class)
    if ([string]::IsNullOrWhiteSpace($Class)) { return $false }
    # Angelo/NO8D Lite sampler panels include "Lora" in the class name because they can accept
    # a LoRA-stacked model input, but they do not themselves define LoRA rows. Do not let
    # their widget values (euler/simple/randomize/etc.) leak into LoRA detection.
    if ($Class -match '(?i)(AngeloSliderLoraLite|SliderLoraLite|SliderLoRALite|NO8D.*Lite.*Sampler|.*Sampler.*Lite.*LoRA)') { return $true }
    return $false
}

function Convert-ToNullableBool {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return [bool]$Value }
    if (Is-NumericLike (As-StringInvariant $Value)) {
        $d = As-DoubleInvariant (As-StringInvariant $Value)
        if ($d -eq 0) { return $false }
        if ($d -eq 1) { return $true }
    }
    $s = (As-StringInvariant $Value).Trim().ToLowerInvariant()
    if ($s -match '^(true|on|yes|y|enabled|enable|active|visible|checked)$') { return $true }
    if ($s -match '^(false|off|no|n|disabled|disable|inactive|hidden|unchecked|muted|mute|bypassed|bypass)$') { return $false }
    return $null
}

function Get-CustomLoraEnabledState {
    param($Object)
    if ($null -eq $Object) { return $null }

    foreach ($key in @('on','enabled','enable','active','is_enabled','selected','visible','checked','isOn','is_on')) {
        $v = Get-PropValue $Object $key
        $b = Convert-ToNullableBool $v
        if ($null -ne $b) { return [bool]$b }
    }

    foreach ($key in @('off','disabled','disable','muted','mute','bypassed','bypass','hidden')) {
        $v = Get-PropValue $Object $key
        $b = Convert-ToNullableBool $v
        if ($null -ne $b) { return (-not [bool]$b) }
    }

    # ComfyUI workflow node mode is usually 0 for active. If a custom node exposes a row mode,
    # treat common non-zero disabled modes as disabled, but avoid over-reading unrelated numbers.
    $mode = Get-PropValue $Object 'mode'
    if ($null -ne $mode -and (Is-NumericLike (As-StringInvariant $mode))) {
        $m = [int](As-DoubleInvariant (As-StringInvariant $mode))
        if ($m -eq 0) { return $true }
        if ($m -eq 2 -or $m -eq 4) { return $false }
    }

    return $null
}

function Get-CustomLoraNameFromObject {
    param($Object, [string]$Context = '')
    if ($null -eq $Object) { return '' }
    if ($Object -is [string]) {
        $s = $Object.Trim()
        if (Is-LoraNameCandidate $s $Context) { return $s }
        return ''
    }

    foreach ($key in @('lora','lora_name','loraName','lora_file','loraFile','filename','file_name','file','name','value','text')) {
        $v = Get-PropValue $Object $key
        if ($null -eq $v -or (Is-RefArray $v)) { continue }
        $s = (To-CleanString $v).Trim()
        if (Is-LoraNameCandidate $s ($Context + ' ' + $key)) { return $s }
    }
    return ''
}

function Get-CustomLoraStrengthsFromObject {
    param($Object)
    $sm = ''
    $sc = ''
    if ($null -eq $Object) { return [pscustomobject]@{ Model = ''; Clip = '' } }

    foreach ($key in @('strength_model','model_strength','modelWeight','model_weight','strength','weight','lora_strength','lora_weight')) {
        $v = Get-PropValue $Object $key
        if ($null -ne $v -and -not (Is-RefArray $v)) {
            $s = (As-StringInvariant $v).Trim()
            if ($s.Length -gt 0 -and (Is-NumericLike $s)) { $sm = $s; break }
        }
    }

    foreach ($key in @('strength_clip','clip_strength','clipWeight','clip_weight','te_strength','text_encoder_strength')) {
        $v = Get-PropValue $Object $key
        if ($null -ne $v -and -not (Is-RefArray $v)) {
            $s = (As-StringInvariant $v).Trim()
            if ($s.Length -gt 0 -and (Is-NumericLike $s)) { $sc = $s; break }
        }
    }

    return [pscustomobject]@{ Model = $sm; Clip = $sc }
}

function Add-CustomLoraObjectRow {
    param($Rows, $Object, [string]$Context = '', [bool]$DefaultEnabledIfMissing = $true)
    $name = Get-CustomLoraNameFromObject $Object $Context
    if ([string]::IsNullOrWhiteSpace($name)) { return }

    $enabled = Get-CustomLoraEnabledState $Object
    if ($null -eq $enabled) { $enabled = $DefaultEnabledIfMissing }
    if (-not [bool]$enabled) { return }

    $strengths = Get-CustomLoraStrengthsFromObject $Object
    # Zero strength is effectively off for these stacker-style controls.
    if ((-not [string]::IsNullOrWhiteSpace([string]$strengths.Model)) -and (Is-NumericLike ([string]$strengths.Model))) {
        if ((As-DoubleInvariant ([string]$strengths.Model)) -eq 0) { return }
    }
    Add-LoraRow $Rows $name $strengths.Model $strengths.Clip
}

function Add-CustomLoraRowsFromObjectTree {
    param($Rows, $Value, [string]$Context = '', [bool]$DefaultEnabledIfMissing = $true, [hashtable]$Seen = $null)
    if ($null -eq $Value) { return }
    if ($null -eq $Seen) { $Seen = @{} }

    # Avoid trying to recursively explode very long prompt strings or primitive blobs.
    if ($Value -is [string]) { return }

    if ($Value -is [System.Array]) {
        foreach ($item in $Value) { Add-CustomLoraRowsFromObjectTree $Rows $item $Context $DefaultEnabledIfMissing $Seen }
        return
    }

    if ($Value -is [System.Collections.IDictionary]) {
        # Dictionaries can represent a single LoRA row, or a container of rows.
        Add-CustomLoraObjectRow $Rows ([pscustomobject]$Value) $Context $DefaultEnabledIfMissing
        foreach ($k in $Value.Keys) { Add-CustomLoraRowsFromObjectTree $Rows $Value[$k] ($Context + ' ' + [string]$k) $DefaultEnabledIfMissing $Seen }
        return
    }

    if ($Value -is [pscustomobject]) {
        Add-CustomLoraObjectRow $Rows $Value $Context $DefaultEnabledIfMissing
        foreach ($p in $Value.PSObject.Properties) {
            # Skip ordinary scalar fields already considered as a row; recurse only into child containers.
            if ($p.Value -is [System.Array] -or $p.Value -is [System.Collections.IDictionary] -or $p.Value -is [pscustomobject]) {
                Add-CustomLoraRowsFromObjectTree $Rows $p.Value ($Context + ' ' + [string]$p.Name) $DefaultEnabledIfMissing $Seen
            }
        }
        return
    }
}


function Convert-ToStrictBool {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return [bool]$Value }
    $s = (As-StringInvariant $Value).Trim().ToLowerInvariant()
    if ($s -match '^(true|on|yes|y|enabled|enable|active|visible|checked|shown|show)$') { return $true }
    if ($s -match '^(false|off|no|n|disabled|disable|inactive|hidden|unchecked|muted|mute|bypassed|bypass|hide)$') { return $false }
    return $null
}

function Get-No8dEnabledNearIndex {
    param($FlatValues, [int]$Index)
    if ($null -eq $FlatValues -or $FlatValues.Count -eq 0) { return $null }

    $lo = [Math]::Max(0, $Index - 5)
    $hi = [Math]::Min($FlatValues.Count - 1, $Index + 8)

    for ($i = $lo; $i -le $hi; $i++) {
        if ($i -eq $Index) { continue }
        $key = ([string]$FlatValues[$i].Key).ToLowerInvariant()
        $txt = ([string]$FlatValues[$i].Text).Trim().ToLowerInvariant()
        if ($txt.Length -eq 0) { continue }
        if ($i -ne $Index -and (Is-LoraNameCandidate $txt 'lora')) { break }

        $b = Convert-ToStrictBool $FlatValues[$i].Value
        if ($null -eq $b) { $b = Convert-ToStrictBool $txt }

        # Explicit enable/toggle/eye keys may store 1/0 rather than true/false. Only treat
        # numeric 1/0 as boolean when the key says it is a state flag, otherwise a LoRA strength
        # of 1.0 gets mistaken for enabled. Ask me how I know. Bloody UI gremlins.
        if ($null -eq $b -and $key -match '(enable|enabled|active|visible|checked|eye|show|shown|toggle|switch|on|bypass|mute|disabled|disable|hidden)' -and (Is-NumericLike $txt)) {
            $num = As-DoubleInvariant $txt
            if ($num -eq 0) { $b = $false }
            elseif ($num -eq 1) { $b = $true }
        }
        if ($null -eq $b) { continue }

        # Prefer explicit on/enabled/visible/eye keys, but also allow nearby raw booleans because
        # NO8D dynamic rows often flatten as anonymous widgets_values[n] items.
        if ($key -match '(enable|enabled|active|visible|checked|eye|show|shown|toggle|switch|on|bypass|mute|disabled|disable|hidden)' -or $FlatValues[$i].Value -is [bool] -or $txt -match '^(true|false|on|off|enabled|disabled|show|hide)$') {
            if ($key -match '(bypass|mute|disabled|disable|hidden)' -and [bool]$b) { return $false }
            return [bool]$b
        }
    }
    return $null
}

function Get-No8dStrengthNearIndex {
    param($FlatValues, [int]$Index)
    $sm = ''
    if ($null -eq $FlatValues -or $FlatValues.Count -eq 0) { return '' }
    $hi = [Math]::Min($FlatValues.Count - 1, $Index + 8)
    for ($i = $Index + 1; $i -le $hi; $i++) {
        $key = ([string]$FlatValues[$i].Key).ToLowerInvariant()
        $txt = ([string]$FlatValues[$i].Text).Trim()
        if ($txt.Length -eq 0) { continue }
        if ($i -ne $Index -and (Is-LoraNameCandidate $txt 'lora')) { break }
        if ($key -match '(enable|enabled|active|visible|checked|eye|show|shown|toggle|switch|on|bypass|mute|disabled|disable|hidden)') { continue }
        if ($txt -match '^(?i:true|false|on|off|enabled|disabled|show|hide)$') { continue }
        if (Is-NumericLike $txt) {
            $num = As-DoubleInvariant $txt
            if ($num -ge -100 -and $num -le 100) { $sm = $txt; break }
        }
    }
    return $sm
}


function Add-No8dRowsFromStackJsonString {
    param($Rows, [string]$JsonText, [string]$Context = 'NO8D stack_json')

    if ([string]::IsNullOrWhiteSpace($JsonText)) { return }

    $s = $JsonText.Trim()
    # NO8D - Slider LoRA Stack stores its rows as a JSON string like:
    # [{"name":"Flux2-9B\\person-height.safetensors","weight":-1,"enabled":true}, ...]
    # Do not use the generic widget scanner for this because it sees sampler widgets from the
    # connected Lite node and starts hallucinating "euler" as a LoRA. Bloody gremlin.
    if ($s -notmatch '^\s*\[' -or $s -notmatch '(?i)"name"\s*:') { return }

    $items = $null
    try {
        $items = $s | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return
    }

    if ($null -eq $items) { return }
    if (-not ($items -is [System.Array])) { $items = @($items) }

    foreach ($item in $items) {
        if ($null -eq $item) { continue }

        $name = First-NotBlank @(
            (Get-PropValue $item 'name'),
            (Get-PropValue $item 'lora'),
            (Get-PropValue $item 'lora_name'),
            (Get-PropValue $item 'filename'),
            (Get-PropValue $item 'file_name')
        )
        if (-not (Is-LoraNameCandidate $name ($Context + ' stack_json name'))) { continue }

        $enabled = Get-CustomLoraEnabledState $item
        # For NO8D stack_json, absence of enabled is suspicious because disabled rows are kept
        # in the same list. Include only explicit enabled/on rows.
        if ($null -eq $enabled -or -not [bool]$enabled) { continue }

        $weight = First-NotBlank @(
            (Get-PropValue $item 'weight'),
            (Get-PropValue $item 'strength'),
            (Get-PropValue $item 'model_weight'),
            (Get-PropValue $item 'modelStrength'),
            (Get-PropValue $item 'model_strength')
        )
        $weightText = (As-StringInvariant $weight).Trim()
        if (-not [string]::IsNullOrWhiteSpace($weightText) -and (Is-NumericLike $weightText)) {
            if ([Math]::Abs((As-DoubleInvariant $weightText)) -lt 0.000001) { continue }
        }

        Add-LoraRow $Rows $name $weightText ''
    }
}

function Add-No8dSliderLoraRowsFromWorkflowNode {
    param($Rows, $Node, [string]$Class)

    # First handle the exact NO8D stack_json format. This is the authoritative source
    # for which slider rows are enabled. It avoids the older generic flattening path
    # that could pick up sampler controls such as "euler".
    foreach ($propName in @('widgets_values','inputs','properties')) {
        $v0 = Get-PropValue $Node $propName
        if ($null -ne $v0) {
            $tmpFlat = New-Object System.Collections.Generic.List[object]
            Add-FlattenedPrimitiveValues $v0 $propName $tmpFlat
            foreach ($fv in $tmpFlat) {
                $k0 = ([string]$fv.Key).ToLowerInvariant()
                $t0 = ([string]$fv.Text).Trim()
                if ($k0 -match 'stack_json|stackjson' -or ($t0 -match '^\s*\[' -and $t0 -match '(?i)"enabled"\s*:' -and $t0 -match '(?i)"name"\s*:')) {
                    Add-No8dRowsFromStackJsonString $Rows $t0 ($Class + ' ' + $propName)
                }
            }
        }
    }

    $flat = New-Object System.Collections.Generic.List[object]
    Add-FlattenedPrimitiveValues (Get-PropValue $Node 'widgets_values') 'widgets_values' $flat
    Add-FlattenedPrimitiveValues (Get-PropValue $Node 'inputs') 'inputs' $flat
    Add-FlattenedPrimitiveValues (Get-PropValue $Node 'properties') 'properties' $flat
    if ($flat.Count -eq 0) { return }

    for ($i = 0; $i -lt $flat.Count; $i++) {
        $key = ([string]$flat[$i].Key).Trim()
        $txt = ([string]$flat[$i].Text).Trim()
        if ([string]::IsNullOrWhiteSpace($txt)) { continue }
        if (Is-KnownNonLoraToken $txt) { continue }

        $ctx = $Class + ' ' + $key + ' lora'
        if (-not (Is-LoraNameCandidate $txt $ctx)) { continue }

        # For NO8D, disabled rows are commonly still stored in the workflow. Only include rows
        # that have a nearby explicit on/enabled/eye state. This is intentionally stricter than
        # generic LoRA parsing so we do not list the whole slider catalogue.
        $enabled = Get-No8dEnabledNearIndex $flat $i
        if ($null -ne $enabled -and -not [bool]$enabled) { continue }
        if ($null -eq $enabled) { continue }

        $strength = Get-No8dStrengthNearIndex $flat $i
        if (-not [string]::IsNullOrWhiteSpace($strength) -and (Is-NumericLike $strength)) {
            if ([Math]::Abs((As-DoubleInvariant $strength)) -lt 0.000001) { continue }
        }
        Add-LoraRow $Rows $txt $strength ''
    }
}


function Get-No8dInputStateForSuffix {
    param($Inputs, [string]$Suffix = '', [string]$NameKey = '')
    if ($null -eq $Inputs) { return $null }

    $stateKeys = @('on','enabled','enable','active','is_enabled','visible','checked','eye','show','shown','toggle','switch')
    $negativeStateKeys = @('off','disabled','disable','muted','mute','bypassed','bypass','hidden')

    foreach ($prop in $Inputs.PSObject.Properties) {
        $k = ([string]$prop.Name).ToLowerInvariant()
        $suffixOk = $true
        if (-not [string]::IsNullOrWhiteSpace($Suffix)) {
            $suffixOk = ($k -match ([regex]::Escape($Suffix) + '$'))
        }
        if (-not $suffixOk) { continue }

        $looksState = $false
        foreach ($sk in $stateKeys) { if ($k -match [regex]::Escape($sk)) { $looksState = $true; break } }
        foreach ($sk in $negativeStateKeys) { if ($k -match [regex]::Escape($sk)) { $looksState = $true; break } }
        if (-not $looksState) { continue }

        $b = Convert-ToNullableBool $prop.Value
        if ($null -eq $b) { $b = Convert-ToNullableBool (As-StringInvariant $prop.Value) }
        if ($null -eq $b) { continue }
        foreach ($sk in $negativeStateKeys) {
            if ($k -match [regex]::Escape($sk)) { return (-not [bool]$b) }
        }
        return [bool]$b
    }

    return $null
}

function Get-No8dInputStrengthForSuffix {
    param($Inputs, [string]$Suffix = '')
    if ($null -eq $Inputs) { return '' }

    foreach ($prop in $Inputs.PSObject.Properties) {
        $k = ([string]$prop.Name).ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($Suffix) -and $k -notmatch ([regex]::Escape($Suffix) + '$')) { continue }
        if ($k -notmatch '(strength|weight|wt|slider|scale)') { continue }
        if ($k -match '(clip|text|te)') { continue }
        $txt = (As-StringInvariant $prop.Value).Trim()
        if ($txt.Length -gt 0 -and (Is-NumericLike $txt)) { return $txt }
    }
    return ''
}

function Add-No8dScalarInputRowsFromPromptNode {
    param($Rows, $Prompt, $Node, [string]$Class)
    $inp = $Node.Inputs
    if ($null -eq $inp) { return }

    # Exact NO8D stack format from prompt chunks.
    foreach ($p0 in $inp.PSObject.Properties) {
        $k0 = ([string]$p0.Name).ToLowerInvariant()
        $t0 = (To-CleanString $p0.Value).Trim()
        if ($k0 -match 'stack_json|stackjson' -or ($t0 -match '^\s*\[' -and $t0 -match '(?i)"enabled"\s*:' -and $t0 -match '(?i)"name"\s*:')) {
            Add-No8dRowsFromStackJsonString $Rows $t0 ($Class + ' prompt')
        }
    }

    foreach ($prop in $inp.PSObject.Properties) {
        $key = [string]$prop.Name
        $ctx = $Class + ' ' + $key + ' lora'
        # Only scalar-style fields here; containers are handled by Add-CustomLoraRowsFromObjectTree.
        if ($prop.Value -is [System.Array] -or $prop.Value -is [System.Collections.IDictionary] -or $prop.Value -is [pscustomobject]) { continue }

        $keyLooksName = ($key -match '(?i)(lora|lyco|lycoris|name|file|model)')
        if (-not $keyLooksName) { continue }

        $name = Resolve-ComfyValue $Prompt $prop.Value @($key,'lora','lora_name','name','value','text') 0
        if (-not (Is-LoraNameCandidate $name $ctx)) { continue }
        if (Is-KnownNonLoraToken $name) { continue }

        $suffix = Get-LoraSuffixFromKey $key
        $enabled = Get-No8dInputStateForSuffix $inp $suffix $key
        # NO8D stores disabled catalogue rows too. If there is no explicit enable/on/eye state,
        # do not guess. Better N/A than a filthy list of disabled sliders.
        if ($null -eq $enabled) { continue }
        if (-not [bool]$enabled) { continue }

        $strength = Get-No8dInputStrengthForSuffix $inp $suffix
        if (-not [string]::IsNullOrWhiteSpace($strength) -and (Is-NumericLike $strength)) {
            if ([Math]::Abs((As-DoubleInvariant $strength)) -lt 0.000001) { continue }
        }
        Add-LoraRow $Rows $name $strength ''
    }
}

function Find-TargetCustomLorasFromPrompt {
    param($Prompt, $Nodes)

    $rows = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Nodes) { return @() }

    foreach ($n in $Nodes) {
        $class = [string]$n.Class
        if (-not (Test-TargetCustomLoraClass $class)) { continue }
        $inp = $n.Inputs
        if ($null -eq $inp) { continue }

        if (Test-No8dLoraClass $class) {
            Add-No8dScalarInputRowsFromPromptNode $rows $Prompt $n $class
        }

        foreach ($prop in $inp.PSObject.Properties) {
            $ctx = $class + ' ' + [string]$prop.Name
            $val = $prop.Value
            $isNo8d = Test-No8dLoraClass $class

            # rgthree Power LoRA Loader stores rows as objects with fields like .lora and .on.
            # For NO8D, prompt inputs also contain sampler controls, so only trust structured rows
            # with explicit state; otherwise 'euler' gets mistaken for a LoRA because the class name contains LoRA.
            if ($val -is [pscustomobject] -or $val -is [System.Collections.IDictionary] -or $val -is [System.Array]) {
                Add-CustomLoraRowsFromObjectTree $rows $val $ctx (-not $isNo8d)
                continue
            }

            if ($isNo8d) { continue }

            $name = Resolve-ComfyValue $Prompt $val @([string]$prop.Name,'lora','lora_name','name','value','text') 0
            if (-not (Is-LoraNameCandidate $name $ctx)) { continue }
            $enabled = $true
            $suffix = Get-LoraSuffixFromKey ([string]$prop.Name)
            $strengths = Get-LoraStrengthsFromInputs $Prompt $inp $suffix
            if (-not [string]::IsNullOrWhiteSpace([string]$strengths.Model) -and (Is-NumericLike ([string]$strengths.Model))) {
                if ((As-DoubleInvariant ([string]$strengths.Model)) -eq 0) { $enabled = $false }
            }
            if ($enabled) { Add-LoraRow $rows $name $strengths.Model $strengths.Clip }
        }
    }

    return @($rows.ToArray())
}

function Find-TargetCustomLorasFromWorkflow {
    param($Workflow)

    $rows = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Workflow) { return @() }
    $workflowNodes = Get-PropValue $Workflow 'nodes'
    if ($null -eq $workflowNodes -or -not ($workflowNodes -is [System.Array])) { return @() }

    foreach ($node in $workflowNodes) {
        $class = First-NotBlank @((Get-PropValue $node 'type'), (Get-PropValue $node 'class_type'), (Get-PropValue $node 'title'))
        if (-not (Test-TargetCustomLoraClass $class)) { continue }

        $nodeMode = Get-PropValue $node 'mode'
        if ($null -ne $nodeMode -and (Is-NumericLike (As-StringInvariant $nodeMode))) {
            $m = [int](As-DoubleInvariant (As-StringInvariant $nodeMode))
            if ($m -eq 2 -or $m -eq 4) { continue }
        }

        if (Test-No8dLoraClass $class) {
            Add-No8dSliderLoraRowsFromWorkflowNode $rows $node $class
            continue
        }

        # In workflow chunks, disabled slots are often still present. Only include a row by default if
        # the slot object explicitly says it is enabled/on/active. This prevents the old v2.11 goblin buffet.
        foreach ($propName in @('widgets_values','inputs','properties')) {
            $v = Get-PropValue $node $propName
            if ($null -ne $v) { Add-CustomLoraRowsFromObjectTree $rows $v ($class + ' ' + $propName) $false }
        }
    }

    return @($rows.ToArray())
}

function Find-LorasFromPrompt {
    param($Prompt, $Nodes)

    $rows = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Nodes) { return @() }

    foreach ($n in $Nodes) {
        $inp = $n.Inputs
        if ($null -eq $inp) { continue }
        $class = [string]$n.Class
        if (Test-TargetCustomLoraClass $class) { continue }
        if (Test-NonLoraSamplerLikeClass $class) { continue }
        $classLooksLora = ($class -match '(?i)(lora|lyco|lycoris|stacker|power.*loader|loader.*power|rgthree|efficiency|easy|impact)')

        foreach ($prop in $inp.PSObject.Properties) {
            $key = [string]$prop.Name
            $keyLooksLora = ($key -match '(?i)(lora|lyco|lycoris)')
            $keyLooksName = ($key -match '(?i)(name|file|ckpt)')
            if (-not ($keyLooksLora -or ($classLooksLora -and $keyLooksName))) { continue }

            $name = Resolve-ComfyValue $Prompt $prop.Value @($key,'lora_name','lora','lyco_name','lycoris_name','name','value','text') 0
            if (-not (Is-LoraNameCandidate $name ($class + ' ' + $key))) { continue }

            $suffix = Get-LoraSuffixFromKey $key
            $strengths = Get-LoraStrengthsFromInputs $Prompt $inp $suffix
            Add-LoraRow $rows $name $strengths.Model $strengths.Clip
        }
    }

    return @($rows.ToArray())
}

function Add-FlattenedPrimitiveValues {
    param($Value, [string]$Key, $List)
    if ($null -eq $Value) { return }

    if ($Value -is [System.Array]) {
        for ($i = 0; $i -lt $Value.Length; $i++) {
            Add-FlattenedPrimitiveValues $Value[$i] ($Key + '[' + $i + ']') $List
        }
        return
    }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in $Value.Keys) {
            Add-FlattenedPrimitiveValues $Value[$k] ([string]$k) $List
        }
        return
    }

    if ($Value -is [pscustomobject]) {
        foreach ($p in $Value.PSObject.Properties) {
            Add-FlattenedPrimitiveValues $p.Value ([string]$p.Name) $List
        }
        return
    }

    [void]$List.Add([pscustomobject]@{ Key = $Key; Value = $Value; Text = (As-StringInvariant $Value) })
}

function Find-NextNumericWidgetValues {
    param($FlatValues, [int]$StartIndex, [int]$MaxLookAhead = 8)
    $nums = New-Object System.Collections.Generic.List[string]
    if ($null -eq $FlatValues) { return @() }
    $end = [Math]::Min($FlatValues.Count - 1, $StartIndex + $MaxLookAhead)
    for ($i = $StartIndex + 1; $i -le $end; $i++) {
        $txt = ([string]$FlatValues[$i].Text).Trim()
        $key = ([string]$FlatValues[$i].Key).ToLowerInvariant()
        if ($txt.Length -eq 0) { continue }
        if (Is-NumericLike $txt) {
            $num = As-DoubleInvariant $txt
            if ($num -ge -10 -and $num -le 10) { [void]$nums.Add($txt) }
        }
        elseif ($key -match '(?i)(lora|name|file)') {
            break
        }
    }
    return @($nums.ToArray())
}

function Find-LorasFromWorkflow {
    param($Workflow)

    $rows = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Workflow) { return @() }
    $workflowNodes = Get-PropValue $Workflow 'nodes'
    if ($null -eq $workflowNodes -or -not ($workflowNodes -is [System.Array])) { return @() }

    foreach ($node in $workflowNodes) {
        $class = First-NotBlank @((Get-PropValue $node 'type'), (Get-PropValue $node 'class_type'), (Get-PropValue $node 'title'))
        if (Test-TargetCustomLoraClass $class) { continue }
        if (Test-NonLoraSamplerLikeClass $class) { continue }
        $classLooksLora = ($class -match '(?i)(lora|lyco|lycoris|stacker|power.*loader|loader.*power)')

        $flat = New-Object System.Collections.Generic.List[object]
        Add-FlattenedPrimitiveValues (Get-PropValue $node 'widgets_values') 'widgets_values' $flat
        Add-FlattenedPrimitiveValues (Get-PropValue $node 'inputs') 'inputs' $flat
        if ($flat.Count -eq 0) { continue }

        for ($i = 0; $i -lt $flat.Count; $i++) {
            $key = ([string]$flat[$i].Key).Trim()
            $txt = ([string]$flat[$i].Text).Trim()
            $ctx = $class + ' ' + $key
            $keyLooksLora = ($key -match '(?i)(lora|lyco|lycoris)')
            if (-not ($classLooksLora -or $keyLooksLora)) { continue }
            if (-not (Is-LoraNameCandidate $txt $ctx)) { continue }

            $sm = ''
            $sc = ''

            # Prefer explicit strength keys in the same flattened node/object area.
            $suffix = Get-LoraSuffixFromKey $key
            for ($j = 0; $j -lt $flat.Count; $j++) {
                $k2 = ([string]$flat[$j].Key).ToLowerInvariant()
                $t2 = ([string]$flat[$j].Text).Trim()
                if ($t2.Length -eq 0 -or -not (Is-NumericLike $t2)) { continue }
                $suffixOk = $true
                if (-not [string]::IsNullOrWhiteSpace($suffix)) {
                    $suffixOk = ($k2 -match ([regex]::Escape($suffix) + '$'))
                }
                if (-not $suffixOk) { continue }
                if ($sm.Length -eq 0 -and $k2 -match '(model.*strength|strength.*model|model.*weight|weight.*model|lora.*strength|strength|weight)') { $sm = $t2; continue }
                if ($sc.Length -eq 0 -and $k2 -match '(clip.*strength|strength.*clip|clip.*weight|weight.*clip|te.*strength)') { $sc = $t2; continue }
            }

            # Custom widget arrays often store filename, model strength, clip strength in order.
            if ($sm.Length -eq 0 -and $sc.Length -eq 0) {
                $near = @(Find-NextNumericWidgetValues $flat $i 8)
                if ($near.Count -ge 1) { $sm = [string]$near[0] }
                if ($near.Count -ge 2) { $sc = [string]$near[1] }
            }

            Add-LoraRow $rows $txt $sm $sc
        }
    }

    return @($rows.ToArray())
}


function Find-FirstNodeInputValue {
    param($Prompt, $Nodes, [string[]]$Keys, [string]$ClassRegex = '')
    foreach ($n in $Nodes) {
        if ($ClassRegex.Length -gt 0 -and ([string]$n.Class) -notmatch $ClassRegex) { continue }
        $inp = $n.Inputs
        if ($null -eq $inp) { continue }
        foreach ($key in $Keys) {
            $v = Get-PropValue $inp $key
            if ($null -eq $v) { continue }
            $r = Resolve-ComfyValue $Prompt $v $Keys 0
            if (-not [string]::IsNullOrWhiteSpace($r)) { return $r }
        }
    }
    return ''
}

function Infer-SchedulerFallback {
    param($Prompt, $Nodes)
    $schedulerKeys = @('scheduler','scheduler_name','schedule','schedule_type','scheduler_type','sched')

    # First try actual scheduler/sigma-ish nodes with explicit scheduler inputs.
    $v = Find-FirstNodeInputValue $Prompt $Nodes $schedulerKeys '(?i)(scheduler|schedule|sigma|sigmas|sampler)'
    if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }

    # Then try all nodes. This catches custom wrappers that hide the scheduler under
    # non-obvious class names but still keep a scheduler input.
    $v = Find-FirstNodeInputValue $Prompt $Nodes $schedulerKeys ''
    if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }

    # Last ditch: infer from scheduler/sigmas node class so the panel does not show N/A.
    foreach ($n in $Nodes) {
        $class = [string]$n.Class
        if ($class -match '(?i)(scheduler|schedule|sigmas|sigma|karras|exponential|polyexponential|alignyoursteps|ays|turbo)') {
            return $class
        }
    }
    return ''
}


function Is-BlankField {
    param($Value)
    return [string]::IsNullOrWhiteSpace([string]$Value)
}

function Set-IfBlank {
    param($Result, [string]$Key, $Value)
    if ($Result.Contains($Key) -and [string]::IsNullOrWhiteSpace([string]$Result[$Key])) {
        $s = To-CleanString $Value
        if (-not [string]::IsNullOrWhiteSpace($s)) { $Result[$Key] = $s }
    }
}

function Find-CoreValueFallback {
    param($Prompt, $Nodes, [string[]]$Keys, [string]$PreferredClassRegex = '')

    if (-not [string]::IsNullOrWhiteSpace($PreferredClassRegex)) {
        $v = Find-FirstNodeInputValue $Prompt $Nodes $Keys $PreferredClassRegex
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }

    $v = Find-FirstNodeInputValue $Prompt $Nodes $Keys '(?i)(sampler|sampling|ksampler|seed|noise|scheduler|schedule|slider|pipe|efficiency|easy|rgthree|no8d)'
    if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }

    return (Find-FirstNodeInputValue $Prompt $Nodes $Keys '')
}

function Fill-CoreFieldsFromAnyPromptNode {
    param($Result, $Prompt, $Nodes)

    if (Is-BlankField $Result.Seed) {
        $Result.Seed = Normalize-SeedString (Find-CoreValueFallback $Prompt $Nodes @('seed','noise_seed','rand_seed','random_seed') '(?i)(sampler|sampling|ksampler|seed|noise|slider|pipe|efficiency|easy|no8d)')
    }
    if (Is-BlankField $Result.Steps) {
        $Result.Steps = Find-CoreValueFallback $Prompt $Nodes @('steps','step','total_steps','sample_steps','num_steps') '(?i)(sampler|sampling|ksampler|steps|slider|pipe|efficiency|easy|no8d)'
    }
    if (Is-BlankField $Result.CFG) {
        $Result.CFG = Find-CoreValueFallback $Prompt $Nodes @('cfg','cfg_scale','cfgscale','guidance','guidance_scale') '(?i)(sampler|sampling|ksampler|cfg|guidance|slider|pipe|efficiency|easy|no8d)'
    }
    if (Is-BlankField $Result.Sampler) {
        $Result.Sampler = Find-CoreValueFallback $Prompt $Nodes @('sampler_name','sampler','samplername') '(?i)(sampler|sampling|ksampler|slider|pipe|efficiency|easy|no8d)'
    }
    if (Is-BlankField $Result.Scheduler) {
        $Result.Scheduler = Find-CoreValueFallback $Prompt $Nodes @('scheduler','scheduler_name','schedule','schedule_type','scheduler_type','sched') '(?i)(sampler|sampling|ksampler|scheduler|schedule|sigma|sigmas|slider|pipe|efficiency|easy|no8d)'
    }
}

function Is-KnownSamplerName {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text -match '(?i)^(euler|euler_ancestral|euler_a|heun|dpm|dpm_|dpmpp|dpm\+\+|lms|ddim|uni_pc|uni_pc_bh2|lcm|ipndm|deis|ddpm|restart|res_multistep|sa_solver|gradient_estimation).*$')
}

function Is-KnownSchedulerName {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text -match '(?i)^(normal|karras|exponential|sgm_uniform|simple|ddim_uniform|beta|linear_quadratic|kl_optimal|turbo|ays|align.*steps|gits|polyexponential|vp|linear|cosine).*$')
}

function Is-NumericLike {
    param($Value)
    if ($null -eq $Value) { return $false }
    $tmp = 0.0
    return [double]::TryParse(([string]$Value), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$tmp)
}

function As-DoubleInvariant {
    param($Value)
    $tmp = 0.0
    [void][double]::TryParse(([string]$Value), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$tmp)
    return $tmp
}

function As-StringInvariant {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [double] -or $Value -is [float] -or $Value -is [decimal]) {
        return ([double]$Value).ToString('G17', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return ([string]$Value).Trim()
}

function Get-WorkflowWidgetNameMapValue {
    param($Node, [string[]]$Names)
    $widgets = Get-PropValue $Node 'widgets_values'
    if ($null -eq $widgets -or -not ($widgets -is [System.Array])) { return '' }

    $nameCandidates = New-Object System.Collections.Generic.List[string]

    foreach ($propName in @('widgets','widget_defs')) {
        $defs = Get-PropValue $Node $propName
        if ($null -ne $defs -and $defs -is [System.Array]) {
            foreach ($d in $defs) {
                $nm = First-NotBlank @((Get-PropValue $d 'name'), (Get-PropValue $d 'label'))
                [void]$nameCandidates.Add($nm)
            }
        }
    }

    # Some workflow exports store named widget metadata under properties.
    $props = Get-PropValue $Node 'properties'
    if ($null -ne $props) {
        foreach ($propName in @('widgets','widget_names','widgetNames')) {
            $defs = Get-PropValue $props $propName
            if ($null -ne $defs -and $defs -is [System.Array]) {
                foreach ($d in $defs) {
                    if ($d -is [string]) { [void]$nameCandidates.Add($d) }
                    else { [void]$nameCandidates.Add((First-NotBlank @((Get-PropValue $d 'name'), (Get-PropValue $d 'label')))) }
                }
            }
        }
    }

    if ($nameCandidates.Count -eq 0) { return '' }
    $limit = [Math]::Min($nameCandidates.Count, $widgets.Length)
    for ($i = 0; $i -lt $limit; $i++) {
        $nm = ([string]$nameCandidates[$i]).Trim().ToLowerInvariant()
        if ($nm.Length -eq 0) { continue }
        foreach ($target in $Names) {
            $t = $target.ToLowerInvariant()
            if ($nm -eq $t -or $nm -replace '[^a-z0-9]', '' -eq ($t -replace '[^a-z0-9]', '')) {
                return (As-StringInvariant $widgets[$i])
            }
        }
    }
    return ''
}

function Fill-CoreFieldsFromWorkflowWidgets {
    param($Result, $Workflow)
    if ($null -eq $Workflow) { return }

    $workflowNodes = Get-PropValue $Workflow 'nodes'
    if ($null -eq $workflowNodes -or -not ($workflowNodes -is [System.Array])) { return }

    foreach ($node in $workflowNodes) {
        $class = First-NotBlank @((Get-PropValue $node 'type'), (Get-PropValue $node 'class_type'), (Get-PropValue $node 'title'))
        $widgets = Get-PropValue $node 'widgets_values'
        if ($null -eq $widgets -or -not ($widgets -is [System.Array]) -or $widgets.Length -eq 0) { continue }

        if (Is-BlankField $Result.Seed) { Set-IfBlank $Result 'Seed' (Get-WorkflowWidgetNameMapValue $node @('seed','noise_seed','rand_seed','random_seed')) }
        if (Is-BlankField $Result.Steps) { Set-IfBlank $Result 'Steps' (Get-WorkflowWidgetNameMapValue $node @('steps','step','total_steps','sample_steps','num_steps')) }
        if (Is-BlankField $Result.CFG) { Set-IfBlank $Result 'CFG' (Get-WorkflowWidgetNameMapValue $node @('cfg','cfg_scale','cfgscale','guidance','guidance_scale')) }
        if (Is-BlankField $Result.Sampler) { Set-IfBlank $Result 'Sampler' (Get-WorkflowWidgetNameMapValue $node @('sampler_name','sampler','samplername')) }
        if (Is-BlankField $Result.Scheduler) { Set-IfBlank $Result 'Scheduler' (Get-WorkflowWidgetNameMapValue $node @('scheduler','scheduler_name','schedule','schedule_type','scheduler_type','sched','sched')) }

        # Standard ComfyUI KSampler workflow widget order:
        # seed, control_after_generate, steps, cfg, sampler_name, scheduler, denoise
        if ($class -match '(?i)^KSampler$|KSampler') {
            if ($widgets.Length -ge 6) {
                if (Is-BlankField $Result.Seed) { Set-IfBlank $Result 'Seed' (Normalize-SeedString (As-StringInvariant $widgets[0])) }
                if (Is-BlankField $Result.Steps) { Set-IfBlank $Result 'Steps' (As-StringInvariant $widgets[2]) }
                if (Is-BlankField $Result.CFG) { Set-IfBlank $Result 'CFG' (As-StringInvariant $widgets[3]) }
                if (Is-BlankField $Result.Sampler) { Set-IfBlank $Result 'Sampler' (As-StringInvariant $widgets[4]) }
                if (Is-BlankField $Result.Scheduler) { Set-IfBlank $Result 'Scheduler' (As-StringInvariant $widgets[5]) }
            }
        }

        # Generic/custom sampler node heuristic. This catches compact nodes like
        # NO8D Slider LoRA Lite where the UI order is sampler, scheduler, denoise, steps, cfg, seed.
        $widgetStrings = @()
        foreach ($w in $widgets) { $widgetStrings += (As-StringInvariant $w) }
        $samplerIndex = -1
        $schedulerIndex = -1
        for ($i = 0; $i -lt $widgetStrings.Count; $i++) {
            if ($samplerIndex -lt 0 -and (Is-KnownSamplerName $widgetStrings[$i])) { $samplerIndex = $i }
            if ($schedulerIndex -lt 0 -and (Is-KnownSchedulerName $widgetStrings[$i])) { $schedulerIndex = $i }
        }

        $looksSamplerish = ($class -match '(?i)(sampler|sampling|ksampler|slider|pipe|efficiency|easy|no8d|xtra|lora)' -or $samplerIndex -ge 0 -or $schedulerIndex -ge 0)
        if (-not $looksSamplerish) { continue }

        if (Is-BlankField $Result.Sampler -and $samplerIndex -ge 0) { Set-IfBlank $Result 'Sampler' $widgetStrings[$samplerIndex] }
        if (Is-BlankField $Result.Scheduler -and $schedulerIndex -ge 0) { Set-IfBlank $Result 'Scheduler' $widgetStrings[$schedulerIndex] }

        if (Is-BlankField $Result.Seed) {
            foreach ($w in $widgetStrings) {
                if ($w -match '^\d{6,}$') { $Result.Seed = (Normalize-SeedString $w); break }
            }
        }

        if ((Is-BlankField $Result.Steps) -or (Is-BlankField $Result.CFG)) {
            # Prefer numeric values after the scheduler, because many compact sampler nodes show:
            # sampler, scheduler, denoise, steps, cfg, seed, control_after_generate
            $smallNums = New-Object System.Collections.Generic.List[object]
            $start = if ($schedulerIndex -ge 0) { $schedulerIndex + 1 } elseif ($samplerIndex -ge 0) { $samplerIndex + 1 } else { 0 }
            for ($i = $start; $i -lt $widgetStrings.Count; $i++) {
                $w = $widgetStrings[$i]
                if ($w -match '^\d{6,}$') { continue }
                if (Is-NumericLike $w) {
                    $num = As-DoubleInvariant $w
                    if ($num -ge 0 -and $num -le 250) {
                        [void]$smallNums.Add([pscustomobject]@{ Index = $i; Text = $w; Number = $num })
                    }
                }
            }

            # Skip denoise when it is the first value after scheduler and between 0 and 1.
            if ($smallNums.Count -gt 0 -and $smallNums[0].Number -ge 0 -and $smallNums[0].Number -le 1 -and $smallNums[0].Index -eq $start) {
                $smallNums.RemoveAt(0)
            }

            if (Is-BlankField $Result.Steps) {
                foreach ($n in $smallNums) {
                    if ($n.Number -ge 1 -and [Math]::Abs($n.Number - [Math]::Round($n.Number)) -lt 0.000001) {
                        $Result.Steps = $n.Text
                        break
                    }
                }
            }
            if (Is-BlankField $Result.CFG -and -not [string]::IsNullOrWhiteSpace([string]$Result.Steps)) {
                $stepSeen = $false
                foreach ($n in $smallNums) {
                    if (-not $stepSeen) {
                        if ($n.Text -eq [string]$Result.Steps) { $stepSeen = $true }
                        continue
                    }
                    if ($n.Number -ge 0 -and $n.Number -le 50) {
                        $Result.CFG = $n.Text
                        break
                    }
                }
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Result.Seed)) {
        $Result.Seed = Normalize-SeedString ([string]$Result.Seed)
    }
}

function Parse-ComfyWorkflow {
    param($Workflow)

    $result = [ordered]@{
        PositivePrompt = ''
        NegativePrompt = ''
        Seed = ''
        Resolution = ''
        LoRAs = ''
        Model = ''
        TextEncoder = ''
        Steps = ''
        CFG = ''
        Sampler = ''
        Scheduler = ''
        Source = 'ComfyUI workflow chunk'
    }

    if ($null -eq $Workflow) { return $result }
    Fill-CoreFieldsFromWorkflowWidgets $result $Workflow
    $loraRows = @()
    $loraRows += @(Find-TargetCustomLorasFromWorkflow $Workflow)
    $loraRows += @(Find-LorasFromWorkflow $Workflow)
    $result.LoRAs = Join-Unique $loraRows "`r`n"
    return $result
}

function Parse-A1111Parameters {
    param([string]$Parameters)

    $result = [ordered]@{
        PositivePrompt = ''
        NegativePrompt = ''
        Seed = ''
        Resolution = ''
        LoRAs = ''
        Model = ''
        TextEncoder = ''
        Steps = ''
        CFG = ''
        Sampler = ''
        Scheduler = ''
        Source = 'parameters chunk'
    }

    if ([string]::IsNullOrWhiteSpace($Parameters)) { return $result }

    $metaMatch = [regex]::Match($Parameters, '(?ms)^Steps:\s*(?<rest>.+)$')
    $promptBlock = $Parameters
    $metaLine = ''
    if ($metaMatch.Success) {
        $promptBlock = $Parameters.Substring(0, $metaMatch.Index).Trim()
        $metaLine = $metaMatch.Value.Trim()
    }

    $negMarker = 'Negative prompt:'
    $negIndex = $promptBlock.IndexOf($negMarker)
    if ($negIndex -ge 0) {
        $result.PositivePrompt = $promptBlock.Substring(0, $negIndex).Trim()
        $result.NegativePrompt = $promptBlock.Substring($negIndex + $negMarker.Length).Trim()
    } else {
        $result.PositivePrompt = $promptBlock.Trim()
    }

    if ($metaLine.Length -gt 0) {
        $kvMatches = [regex]::Matches($metaLine, '(?:^|,\s*)(?<key>[A-Za-z0-9 _/-]+):\s*(?<val>.*?)(?=,\s*[A-Za-z0-9 _/-]+:\s*|$)')
        foreach ($m in $kvMatches) {
            $key = $m.Groups['key'].Value.Trim().ToLowerInvariant()
            $val = $m.Groups['val'].Value.Trim()
            switch -Regex ($key) {
                '^steps$' { $result.Steps = $val; break }
                '^seed$' { $result.Seed = $val; break }
                '^(cfg scale|cfg)$' { $result.CFG = $val; break }
                '^sampler$' { $result.Sampler = $val; break }
                '^(schedule type|scheduler|scheduler name|scheduler_name|schedule)$' { $result.Scheduler = $val; break }
                '^model$|^model name$' { $result.Model = $val; break }
                '^clip skip$|^text encoder$' { if ($result.TextEncoder.Length -eq 0) { $result.TextEncoder = $val }; break }
            }
        }
    }

    $loras = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($Parameters, '<lora:(?<name>[^:>]+):(?<strength>[^>]+)>')) {
        [void]$loras.Add(($m.Groups['name'].Value + ' (' + $m.Groups['strength'].Value + ')'))
    }
    $result.LoRAs = Join-Unique $loras.ToArray() "`r`n"
    return $result
}

function Parse-ComfyPrompt {
    param($Prompt)

    $result = [ordered]@{
        PositivePrompt = ''
        NegativePrompt = ''
        Seed = ''
        Resolution = ''
        LoRAs = ''
        Model = ''
        TextEncoder = ''
        Steps = ''
        CFG = ''
        Sampler = ''
        Scheduler = ''
        Source = 'ComfyUI prompt chunk'
    }

    if ($null -eq $Prompt) { return $result }

    $nodes = @()
    foreach ($p in $Prompt.PSObject.Properties) {
        $node = $p.Value
        $class = [string](Get-PropValue $node 'class_type')
        $inputs = Get-PropValue $node 'inputs'
        if ($class.Length -gt 0) {
            $nodes += [pscustomobject]@{ Id = [string]$p.Name; Class = $class; Inputs = $inputs; Node = $node }
        }
    }

    $sampler = $nodes | Where-Object { $_.Class -match '(?i)(KSampler|SamplerCustom|SamplerAdvanced)' } | Select-Object -First 1
    if ($null -ne $sampler -and $null -ne $sampler.Inputs) {
        $i = $sampler.Inputs
        $result.Seed = Normalize-SeedString (Get-ResolvedValueFromInputs $Prompt $i @('seed','noise_seed','rand_seed'))
        $result.Steps = Get-ResolvedValueFromInputs $Prompt $i @('steps','total_steps')
        $result.CFG = Get-ResolvedValueFromInputs $Prompt $i @('cfg','cfg_scale','guidance')
        $result.Sampler = Get-ResolvedValueFromInputs $Prompt $i @('sampler_name','sampler','samplername')
        $result.Scheduler = Get-ResolvedValueFromInputs $Prompt $i @('scheduler','scheduler_name','schedule','schedule_type','scheduler_type','sched','sigmas','sigma','sigmas_out')
        if ([string]::IsNullOrWhiteSpace($result.Scheduler)) {
            foreach ($sigmaKey in @('sigmas','sigma','sigmas_out')) {
                $sigmaRef = Get-PropValue $i $sigmaKey
                if ($null -ne $sigmaRef) {
                    $r = Resolve-ComfyValue $Prompt $sigmaRef @('scheduler','scheduler_name','schedule','schedule_type','scheduler_type','sched') 0
                    if (-not [string]::IsNullOrWhiteSpace($r)) { $result.Scheduler = $r; break }
                }
            }
        }

        $posRef = Get-RefId (Get-PropValue $i 'positive')
        $negRef = Get-RefId (Get-PropValue $i 'negative')
        $posTexts = Collect-TextsFromNode $Prompt $posRef @{}
        $negTexts = Collect-TextsFromNode $Prompt $negRef @{}
        $result.PositivePrompt = Join-Unique $posTexts "`r`n---`r`n"
        $result.NegativePrompt = Join-Unique $negTexts "`r`n---`r`n"
    }

    # Some custom sampler panels do not use a class name containing KSampler/SamplerCustom.
    # Do a broader pass across all prompt nodes before falling back to N/A.
    Fill-CoreFieldsFromAnyPromptNode $result $Prompt $nodes

    if ([string]::IsNullOrWhiteSpace($result.Scheduler)) {
        $result.Scheduler = Infer-SchedulerFallback $Prompt $nodes
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$result.Seed)) {
        $result.Seed = Normalize-SeedString ([string]$result.Seed)
    }

    if ($result.PositivePrompt.Length -eq 0) {
        $textNodes = $nodes | Where-Object { $_.Class -match '(?i)CLIPTextEncode' }
        $texts = @()
        foreach ($n in $textNodes) {
            $txt = First-NotBlank @((Get-PropValue $n.Inputs 'text'), (Get-PropValue $n.Inputs 'text_g'), (Get-PropValue $n.Inputs 'text_l'))
            if ($txt.Length -gt 0) { $texts += $txt }
        }
        $result.PositivePrompt = Join-Unique $texts "`r`n---`r`n"
    }

    # LoRA detection: start with exact custom multi-LoRA nodes that expose enabled/on state,
    # then fall back to standard LoRA loader inputs and conservative generic stackers.
    $loraRows = @()
    $loraRows += @(Find-TargetCustomLorasFromPrompt $Prompt $nodes)
    $loraRows += @(Find-LorasFromPrompt $Prompt $nodes)
    $result.LoRAs = Join-Unique $loraRows "`r`n"

    $modelNames = New-Object System.Collections.Generic.List[string]
    foreach ($n in ($nodes | Where-Object { $_.Class -match '(?i)(CheckpointLoader|UNETLoader|UnetLoader|DiffusionModelLoader|ModelLoader|Nunchaku|GGUF)' })) {
        $inp = $n.Inputs
        if ($null -eq $inp) { continue }
        foreach ($key in @('ckpt_name','unet_name','model_name','diffusion_model','gguf_name','model','vae_name')) {
            $val = Get-PropValue $inp $key
            if ($null -ne $val -and -not (Is-RefArray $val)) {
                $s = ([string]$val).Trim()
                if ($s.Length -gt 0) { [void]$modelNames.Add($s) }
            }
        }
    }
    $result.Model = Join-Unique $modelNames.ToArray()

    $encNames = New-Object System.Collections.Generic.List[string]
    foreach ($n in ($nodes | Where-Object { $_.Class -match '(?i)(CLIPLoader|DualCLIPLoader|TripleCLIPLoader|TextEncoder|T5|UMT5|BERT)' })) {
        $inp = $n.Inputs
        if ($null -eq $inp) { continue }
        foreach ($key in @('clip_name','clip_name1','clip_name2','clip_name3','t5_name','bert_name','text_encoder_name','tokenizer_name')) {
            $val = Get-PropValue $inp $key
            if ($null -ne $val -and -not (Is-RefArray $val)) {
                $s = ([string]$val).Trim()
                if ($s.Length -gt 0) { [void]$encNames.Add($s) }
            }
        }
    }
    $result.TextEncoder = Join-Unique $encNames.ToArray()

    return $result
}

function Merge-Metadata {
    param($Chunks)

    $fromPrompt = $null
    if ($Chunks.Contains('prompt') -and -not [string]::IsNullOrWhiteSpace([string]$Chunks['prompt'])) {
        try {
            $json = $Chunks['prompt'] | ConvertFrom-Json -ErrorAction Stop
            $fromPrompt = Parse-ComfyPrompt $json
        } catch {
            $fromPrompt = $null
        }
    }

    $fromParams = $null
    foreach ($key in @('parameters','Parameters','Description','Comment')) {
        if ($Chunks.Contains($key) -and ([string]$Chunks[$key]).Contains('Steps:')) {
            $fromParams = Parse-A1111Parameters ([string]$Chunks[$key])
            break
        }
    }

    $fromWorkflow = $null
    if ($Chunks.Contains('workflow') -and -not [string]::IsNullOrWhiteSpace([string]$Chunks['workflow'])) {
        try {
            $workflowJson = $Chunks['workflow'] | ConvertFrom-Json -ErrorAction Stop
            $fromWorkflow = Parse-ComfyWorkflow $workflowJson
        } catch {
            $fromWorkflow = $null
        }
    }

    $out = [ordered]@{
        PositivePrompt = ''
        NegativePrompt = ''
        Seed = ''
        Resolution = ''
        LoRAs = ''
        Model = ''
        TextEncoder = ''
        Steps = ''
        CFG = ''
        Sampler = ''
        Scheduler = ''
        Source = ''
    }

    foreach ($key in @($out.Keys)) {
        $v = ''
        if ($null -ne $fromPrompt) { $v = [string]$fromPrompt[$key] }
        if ([string]::IsNullOrWhiteSpace($v) -and $null -ne $fromParams) { $v = [string]$fromParams[$key] }
        if ([string]::IsNullOrWhiteSpace($v) -and $null -ne $fromWorkflow) { $v = [string]$fromWorkflow[$key] }
        $out[$key] = $v
    }

    # Resolution always comes from the PNG IHDR chunk — not from prompt/workflow JSON.
    $iw = if ($Chunks.Contains('_Width'))  { [string]$Chunks['_Width']  } else { '' }
    $ih = if ($Chunks.Contains('_Height')) { [string]$Chunks['_Height'] } else { '' }
    if ($iw.Length -gt 0 -and $ih.Length -gt 0) { $out['Resolution'] = "$iw x $ih" }

    if ($out.Source.Length -eq 0) {
        if ($Chunks.Contains('prompt') -or $Chunks.Contains('workflow')) { $out.Source = 'ComfyUI chunks found, but recognised fields were limited' }
        else { $out.Source = 'No ComfyUI prompt/workflow metadata found' }
    }

    $out['File'] = (Resolve-Path -LiteralPath $Path).Path
    $out['ChunkKeys'] = (Join-Unique @($Chunks.Keys))
    return [pscustomobject]$out
}

function Format-TextRows {
    param($Meta)
    $labels = [ordered]@{
        PositivePrompt = 'Positive Prompt'
        NegativePrompt = 'Negative Prompt'
        Seed = 'Seed'
        Resolution = 'Resolution'
        LoRAs = "LoRA's"
        Model = 'Model'
        TextEncoder = 'Text Encoder'
        Sampler = 'Sampler'
        Scheduler = 'Scheduler'
        Steps = 'Steps'
        CFG = 'CFG'
    }
    $optional = @('NegativePrompt', 'LoRAs', 'TextEncoder')
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($k in $labels.Keys) {
        $v = [string](Get-PropValue $Meta $k)
        if ($optional -contains $k -and [string]::IsNullOrWhiteSpace($v)) { continue }
        if ([string]::IsNullOrWhiteSpace($v)) { $v = 'N/A' }
        [void]$lines.Add($labels[$k] + ': ' + $v)
    }
    return ($lines.ToArray() -join "`r`n")
}

function Html-Encode {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Write-HtmlReport {
    param($Meta)

    $labels = [ordered]@{
        PositivePrompt = 'Positive Prompt'
        NegativePrompt = 'Negative Prompt'
        Seed = 'Seed'
        Resolution = 'Resolution'
        LoRAs = "LoRA's"
        Model = 'Model'
        TextEncoder = 'Text Encoder'
        Sampler = 'Sampler'
        Scheduler = 'Scheduler'
        Steps = 'Steps'
        CFG = 'CFG'
    }
    $optional = @('NegativePrompt', 'LoRAs', 'TextEncoder')

    $rows = New-Object System.Collections.Generic.List[string]
    $idx = 0
    foreach ($k in $labels.Keys) {
        $raw = [string](Get-PropValue $Meta $k)
        if ($optional -contains $k -and [string]::IsNullOrWhiteSpace($raw)) { continue }
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = 'N/A' }
        $label = Html-Encode $labels[$k]
        $val = Html-Encode $raw
        $id = 'v' + $idx
        $largeClass = if ($k -eq 'PositivePrompt' -or $k -eq 'NegativePrompt') { ' large' } else { '' }
        [void]$rows.Add("<section class=`"row$largeClass`"><div class=`"rowhead`"><strong>$label</strong><button onclick=`"copyValue('$id')`" title=`"Copy this row`">Copy</button></div><pre id=`"$id`">$val</pre></section>")
        $idx++
    }

    $title = 'ComfyUI PNG metadata - ' + [System.IO.Path]::GetFileName($Path)
    $titleHtml = Html-Encode $title
    $allText = Html-Encode (Format-TextRows $Meta)
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $imageUri = ([System.Uri]$resolvedPath).AbsoluteUri
    $imageUriHtml = Html-Encode $imageUri
    $fileNameHtml = Html-Encode ([System.IO.Path]::GetFileName($Path))

    $html = @"
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>$titleHtml</title>
<style>
:root { color-scheme: dark; }
* { box-sizing: border-box; }
html, body { height: 100%; }
body { margin: 0; font-family: Segoe UI, Arial, sans-serif; background: #111; color: #eee; overflow: hidden; }
.wrap { height: 100vh; display: block; }
.meta { height: 100vh; overflow-y: auto; background: #111; padding: 5px; }
.titlebar { position: sticky; top: 0; z-index: 2; display: flex; gap: 8px; align-items: center; background: #191919; border: 1px solid #333; padding: 5px 6px; margin-bottom: 5px; }
.titlebar h1 { font-size: 12px; line-height: 1.2; margin: 0; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.row { border: 1px solid #2b2b2b; background: #0e0e0e; margin-bottom: 4px; }
.rowhead { display: flex; align-items: center; gap: 8px; border-bottom: 1px solid #262626; background: #181818; min-height: 25px; padding: 3px 5px; }
.rowhead strong { flex: 1; font-size: 12px; color: #fff; }
.rowhead button, .titlebar button { border: 1px solid #444; background: #252525; color: #eee; border-radius: 3px; cursor: pointer; min-height: 21px; padding: 2px 8px; }
.rowhead button:hover, .titlebar button:hover { background: #333; }
pre { margin: 0; padding: 5px 6px; white-space: pre-wrap; overflow-wrap: anywhere; font-family: Consolas, 'Cascadia Mono', monospace; font-size: 11px; line-height: 1.32; max-height: 80px; overflow-y: auto; }
.row.large pre { max-height: 145px; }
#notice { font-size: 11px; color: #aaa; min-width: 70px; text-align: right; }
</style>
<script>
function copyText(t, msg) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(t).then(() => flash(msg)).catch(() => fallbackCopy(t, msg));
  } else {
    fallbackCopy(t, msg);
  }
}
function fallbackCopy(t, msg) {
  const ta = document.createElement('textarea');
  ta.value = t;
  ta.style.position = 'fixed';
  ta.style.left = '-9999px';
  document.body.appendChild(ta);
  ta.focus();
  ta.select();
  try { document.execCommand('copy'); flash(msg); }
  catch(e) { flash('Copy failed'); }
  document.body.removeChild(ta);
}
function copyValue(id) {
  const t = document.getElementById(id).innerText;
  copyText(t, 'Copied');
}
function copyAll() {
  const t = document.getElementById('alltext').innerText;
  copyText(t, 'Copied all');
}
function flash(msg) {
  const n = document.getElementById('notice');
  n.innerText = msg;
  setTimeout(() => n.innerText = '', 1400);
}
</script>
</head>
<body>
<div class="wrap">
  <div class="meta">
    <div class="titlebar"><h1>$fileNameHtml</h1><button onclick="copyAll()">Copy all</button><span id="notice"></span></div>
    $($rows.ToArray() -join "`r`n")
    <pre id="alltext" style="display:none">$allText</pre>
  </div>
</div>
</body>
</html>
"@
    $safeBase = [System.IO.Path]::GetFileNameWithoutExtension($Path) -replace '[^A-Za-z0-9_.-]', '_'
    $outDir = Join-Path $env:TEMP 'ComfyUI-Opus-Metadata'
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $outPath = Join-Path $outDir ($safeBase + '.comfyui-meta.html')
    Set-Content -LiteralPath $outPath -Value $html -Encoding UTF8
    return $outPath
}

try {
    $chunks = Read-PngTextChunks -FilePath $Path
    $meta = Merge-Metadata $chunks

    if ($Output -eq 'Dump') {
        $promptRaw = ''
        $workflowRaw = ''
        $parametersRaw = ''
        if ($chunks.ContainsKey('prompt')) { $promptRaw = [string]$chunks['prompt'] }
        if ($chunks.ContainsKey('workflow')) { $workflowRaw = [string]$chunks['workflow'] }
        if ($chunks.ContainsKey('parameters')) { $parametersRaw = [string]$chunks['parameters'] }
        $dump = [ordered]@{
            File = $Path
            ChunkKeys = @($chunks.Keys)
            Prompt = $promptRaw
            Workflow = $workflowRaw
            Parameters = $parametersRaw
            Parsed = $meta
        }
        $json = $dump | ConvertTo-Json -Depth 60
        if ($Copy) { Set-Clipboard -Value $json }
        Write-Output $json
        return
    }

    if ($Output -eq 'Json') {
        $json = $meta | ConvertTo-Json -Depth 8
        if ($Copy) { Set-Clipboard -Value $json }
        Write-Output $json
        return
    }

    if ($Output -eq 'Field') {
        $map = @{
            'positive' = 'PositivePrompt'; 'positiveprompt' = 'PositivePrompt'; 'prompt' = 'PositivePrompt'
            'negative' = 'NegativePrompt'; 'negativeprompt' = 'NegativePrompt'
            'seed' = 'Seed'; 'resolution' = 'Resolution'; 'loras' = 'LoRAs'; 'lora' = 'LoRAs'
            'model' = 'Model'; 'textencoder' = 'TextEncoder'; 'clip' = 'TextEncoder'
            'steps' = 'Steps'; 'cfg' = 'CFG'; 'sampler' = 'Sampler'; 'scheduler' = 'Scheduler'
            'source' = 'Source'; 'file' = 'File'
        }
        $key = ($Field -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
        if ($map.ContainsKey($key)) { $propName = $map[$key] } else { $propName = $Field }
        $val = [string](Get-PropValue $meta $propName)
        # LoRAs are stored newline-separated for display; flatten to comma for single-line column values.
        if ($propName -eq 'LoRAs') { $val = $val -replace '[\r\n]+', ', ' }
        Write-Output $val
        return
    }

    if ($Output -eq 'Text') {
        $txt = Format-TextRows $meta
        if ($Copy) { Set-Clipboard -Value $txt }
        Write-Output $txt
        return
    }

    $htmlPath = Write-HtmlReport $meta
    if ($Copy) { Set-Clipboard -Value (Format-TextRows $meta) }
    if ($Open) { Invoke-Item -LiteralPath $htmlPath }
    Write-Output $htmlPath
}
catch {
    if ($Output -eq 'Field') { Write-Output '' }
    else {
        Write-Error $_.Exception.Message
    }
}
