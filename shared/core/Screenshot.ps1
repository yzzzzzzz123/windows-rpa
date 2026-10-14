function Save-TargetImage([IntPtr]$handle,[string]$filename) {
    if([DingRpa]::GetForegroundWindow() -ne $handle){throw '目标窗口失去焦点，停止截图和后续输入。'}
    $bounds=New-Object DingRpa+Rect
    if(-not [DingRpa]::GetWindowRect($handle,[ref]$bounds)){throw '不能读取窗口位置。'}
    $imageWidth=$bounds.Right-$bounds.Left; $imageHeight=$bounds.Bottom-$bounds.Top
    if($imageWidth -le 0 -or $imageHeight -le 0 -or $imageWidth -gt 20000 -or $imageHeight -gt 20000){throw '窗口尺寸异常。'}
    $image=New-Object System.Drawing.Bitmap($imageWidth,$imageHeight)
    $canvas=[System.Drawing.Graphics]::FromImage($image)
    try{$canvas.CopyFromScreen($bounds.Left,$bounds.Top,0,0,$image.Size); $image.Save((Join-Path $resultDir $filename),[System.Drawing.Imaging.ImageFormat]::Png)}
    finally{$canvas.Dispose();$image.Dispose()}
}
