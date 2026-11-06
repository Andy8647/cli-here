-- NvimHere: a LaunchServices shim that hands files to cli-here.
--
-- Everything that decides what happens lives in bin/cli-here, so changing the
-- rules never means rebuilding this bundle. A LaunchServices launch has no
-- usable PATH, no EDITOR and a working directory of /, so install.sh bakes all
-- four values in at compile time:
--
--   __CLI_HERE__   absolute path of bin/cli-here
--   __NVIM_HERE__  absolute path of bin/nvim-here (the config-free entry point)
--   __PATH__       the PATH to give the CLI, and the surfaces it opens
--   __EDITOR__     the same for EDITOR

on run
	-- Double-clicking the app opens nvim with an empty buffer, as it always did.
	forward("__NVIM_HERE__ --", {})
end run

on open theFiles
	set paths to {}
	repeat with f in theFiles
		set end of paths to POSIX path of f
	end repeat
	forward("__CLI_HERE__ --from-ls --", paths)
end open

on forward(program, paths)
	set cmd to "PATH=" & quoted form of "__PATH__" & " EDITOR=" & quoted form of "__EDITOR__" & " " & program
	repeat with p in paths
		set cmd to cmd & " " & quoted form of p
	end repeat
	try
		do shell script cmd
	on error errMsg number errNum
		reportFailure(errMsg, errNum)
	end try
end forward

on reportFailure(errMsg, errNum)
	-- `do shell script` puts the command's stderr in errMsg, so the alert shows
	-- exactly what the CLI would have printed in a terminal.
	try
		do shell script "printf '%s %s\\n' " & quoted form of (errNum as text) & " " & quoted form of errMsg & " >> \"$HOME/Library/Logs/NvimHere.log\""
	end try
	try
		tell application "Ghostty"
			activate
			display alert "NvimHere" message errMsg as warning
		end tell
	end try
end reportFailure
