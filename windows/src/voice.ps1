$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.Encoding]::UTF8
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
Add-Type -AssemblyName System.Speech
if ($request.action -eq 'voices') {
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    try {
        $voices = @($synth.GetInstalledVoices() | Where-Object { $_.Enabled } | ForEach-Object { @{id=$_.VoiceInfo.Name;name=$_.VoiceInfo.Name;language=$_.VoiceInfo.Culture.Name} })
        @{voices=$voices} | ConvertTo-Json -Depth 4 -Compress
    } finally { $synth.Dispose() }
} elseif ($request.action -eq 'speak') {
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    try { if ($request.voice) { $synth.SelectVoice([string]$request.voice) } else { $synth.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::NotSet,[System.Speech.Synthesis.VoiceAge]::NotSet,0,[Globalization.CultureInfo]::GetCultureInfo($request.language)) }; $synth.Speak([string]$request.text); '{"ok":true}' } finally { $synth.Dispose() }
} elseif ($request.action -eq 'listen') {
    $engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine([Globalization.CultureInfo]::GetCultureInfo($request.language))
    try {
        $engine.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
        $engine.SetInputToDefaultAudioDevice()
        $result = $engine.Recognize([TimeSpan]::FromSeconds(30))
        if ($null -eq $result) { '{"text":""}' } else { @{text=$result.Text} | ConvertTo-Json -Compress }
    } finally { $engine.Dispose() }
} else { throw 'Unknown speech action' }
