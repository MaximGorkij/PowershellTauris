$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add("Content-Type", "application/json")
$headers.Add("Cookie", "TPLANV01=4f84661654ec0fdd2850b0a857e6391c")
$body = "{
`n    `"api_client_name`": `"tauris.tido.sk`",
`n    `"api_client_pass`": `"TiDo_Tauris_MIS_2022`"
`n}"
$response = Invoke-RestMethod 'https://api.tido.sk/api/api-client/login/' -Method 'POST' -Headers $headers -Body $body
$hash = $response.data.hash
#--------
$headers2 = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers2.Add("Content-Type", "UTF-8") #text/plain; 
$headers2.Add("Content-language", "sk")
$date1 = (Get-Date).AddDays(-1)
$datum = Get-Date -date $date1 -format 'yyyy-MM-dd'
$parameters = '?date='+$datum+'&hash='+$hash
$url = 'https://api.tido.sk/api/odpracovane/'+$parameters
$FileOut = '/mnt/tido-data/'+$datum+'_tido.csv'
$response2 = Invoke-RestMethod ($url) -Method 'GET' -Headers $headers2 #-Body $body
$response2.data | ConvertTo-csv -NoTypeInformation | Out-File -FilePath $FileOut -Encoding utf8
 