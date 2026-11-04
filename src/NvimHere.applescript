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
	set label to "nvim"
	if (count of paths) > 0 then
		set cmd to cmd & " --"
		repeat with p in paths
			set cmd to cmd & " " & quoted form of p
		end repeat
		-- Tab title. Nothing here runs a shell, so Ghostty's shell integration never
		-- reports one and the tab would sit on the 👻 placeholder forever.
		set label to my basename(item 1 of paths)
		if (count of paths) > 1 then
			set label to label & " +" & ((count of paths) - 1)
		end if
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
			set newTab to new tab in w with configuration cfg
			set name override of newTab to label
		end if
	end tell
end openInNvim

on basename(p)
	set AppleScript's text item delimiters to "/"
	set parts to text items of p
	set AppleScript's text item delimiters to ""
	if (count of parts) > 1 and last item of parts is "" then
		return item -2 of parts
	end if
	return last item of parts
end basename

on logError(msg)
	try
		do shell script "printf '%s\\n' " & quoted form of msg & " >> \"$HOME/Library/Logs/NvimHere.log\""
	end try
end logError
