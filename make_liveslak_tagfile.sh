#!/bin/bash

# Directory where packages are located (passed as argument or current directory)
PACKAGE_DIR="${1:-.}"

# Loop through each file in the specified directory
for file in "${PACKAGE_DIR}"/*; do
    # Check if it is a file
    if [[ -f "$file" ]]; then
        # Extract the base name of the file
        BASENAME=$(basename "$file")
        
        # Remove the extension from the file name
        NO_EXT="${BASENAME%.*}"
        
        # Extract the package name (up to the first occurrence of digits or known separators)
        PRGNAM=$(echo "$NO_EXT" | sed -E 's/[_.-][0-9].*$//' | sed -E 's/[_.-]+$//')
        
        # Append to the tagfile
        echo "${PRGNAM}:ADD" >> tagfile
    fi
done
