-- NvimHere: a LaunchServices shim that opens files in Neovim
-- inside a new tab of the frontmost Ghostty window.
--
-- __NVIM__ is replaced with an absolute path at install time,
-- because LaunchServices launches us with a minimal PATH.

on run
	try
		openInNvim({})
	on error errMsg number errNum
		logError("run: " & errNum & " " & errMsg)
	end try
end run

on open theFiles
	set paths to {}
	repeat with f in theFiles
		set end of paths to POSIX path of f
	end repeat
	try
		openInNvim(paths)
	on error errMsg number errNum
		logError("open: " & errNum & " " & errMsg)
	end try
end open

on openInNvim(paths)
	set cmd to "__NVIM__"
	if (count of paths) > 0 then
		set cmd to cmd & " --"
		repeat with p in paths
			set cmd to cmd & " " & quoted form of p
		end repeat
	end if

	tell application "Ghostty"
		activate
		set cfg to new surface configuration
		set command of cfg to cmd
		try
			set w to front window
		on error
			set w to missing value
		end try
		if w is missing value then
			new window with configuration cfg
		else
			new tab in w with configuration cfg
		end if
	end tell
end openInNvim

on logError(msg)
	try
		do shell script "printf '%s\\n' " & quoted form of msg & " >> \"$HOME/Library/Logs/NvimHere.log\""
	end try
end logError
