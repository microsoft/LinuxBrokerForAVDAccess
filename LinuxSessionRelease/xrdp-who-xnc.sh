#!/bin/bash
#
# Print info about xrdp Xvnc sessions
#

# Setting up color variables for output formatting using tput for portability and readability
RED=$(tput setaf 1; tput bold) # Set text color to bold red
GREEN=$(tput setaf 2; tput bold) # Set text color to bold green
YELLOW=$(tput setaf 3; tput bold) # Set text color to bold yellow
ENDCOLOR=$(tput sgr0) # Reset text formatting to default
BLINK=$(tput blink) # Unused in this script, would make text blink
REVERSE=$(tput smso) # Unused in this script, would reverse the background and foreground colors
UNDERLINE=$(tput smul) # Unused in this script, would underline text

# Format string for printf to maintain consistent column widths and alignments in the output
_printf="%7s %-20s %-19s %-10s %4s %-12s\n"

# Print header with specified column names, using the previously defined format
printf "\n${_printf}" PID USERNAME START_TIME GEOMETRY BITS STATUS

# Get a list of all Xvnc processes, parse their details, and process each line
ps h -C Xvnc -o user:20,pid,lstart,cmd | while read username pid dt1 dt2 dt3 dt4 dt5 xvnc_cmd; do
    # Combine date and time parts into a single string
    timestring="${dt1} ${dt2} ${dt3} ${dt4} ${dt5}";
    # Convert the start time of the session into a Unix timestamp for comparison
    start_time_s=$(date -d "${timestring}" +"%s");
    # Format the start time as YYYY-MM-DD HH:MM
    printf -v start_time "%(%Y-%m-%d %H:%M)T" ${start_time_s}
    # Highlight the start time in yellow if the session started more than 30 days ago
    [ ${start_time_s} -lt $(date -d "-30 days" +%s) ] && start_time="${YELLOW}${start_time}${ENDCOLOR}"
    # Parse the Xvnc command for geometry (resolution) and color depth (bits)
    read geometry colorbits <<< $(echo ${xvnc_cmd} | awk '{for(i=i;i<=NF;i++){if($i=="-geometry"){geom=$(++i)} if($i=="-depth"){bits=$(++i)}} print geom,bits}');
    # Check if the session is active by looking for its PID in the socket state (ss) command output
    ss -tep 2>/dev/null | grep -q pid\=${pid}, && status="${GREEN}active${ENDCOLOR}" || status="${RED}disconnected${ENDCOLOR}";
    # Print the session details using the format string defined earlier
    printf "${_printf}" ${pid} ${username} "${start_time}" ${geometry} ${colorbits} "${status}";
done
# Print an extra newline for clean output separation
echo ""
