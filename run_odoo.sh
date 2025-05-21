#!/bin/bash
set -e

if ! command -v fzf &> /dev/null
then
    echo "Error: fzf command could not be found. Please install fzf." >&2
    exit 1
fi

display_help() {
    echo "Usage: run_odoo.sh [options]"
    echo "A script to automate running Odoo with specific configurations."
    echo
    echo "Options:"
    echo "  -e <python_env_path>      Path to the Python executable in a virtual environment."
    echo "  -o <odoo_executable_path> Path to the Odoo executable (e.g., odoo-bin). Overrides PYTHONPATH lookup."
    echo "  -c <odoo_config_file_path> Path to the Odoo configuration file."
    echo "  -d <database_name>        Explicit database name."
    echo "  -i <addons_to_install>    Comma-separated list of addons to install."
    echo "  -u <addons_to_update>     Comma-separated list of addons to update."
    echo "  -t, --test-enable         Enable tests (--test-enable and --stop-after-init)."
    echo "  -h, --help                Display this help message and exit."
    echo
    echo "Environment Variables:"
    echo "  PYTHON_VENVS            Directory to search for Python virtual environments if -e is not used."
    echo "  PYTHONPATH              Directory containing odoo-bin."
    echo "  ODOO_CONFIG_FILES       Directory/pattern to search for Odoo config files if -c is not used."
    exit 0
}

python_env_path=""
odoo_executable_arg=""
odoo_config_file_path=""
database_name_arg=""
addons_to_install_cmd=""
addons_to_update_cmd=""
test_enable_flag=false

while getopts ":e:o:c:d:i:u:th" opt; do
  case \${opt} in
    e ) python_env_path="\${OPTARG}" ;;
    o ) odoo_executable_arg="\${OPTARG}" ;;
    c ) odoo_config_file_path="\${OPTARG}" ;;
    d ) database_name_arg="\${OPTARG}" ;;
    i ) addons_to_install_cmd="\${OPTARG}" ;;
    u ) addons_to_update_cmd="\${OPTARG}" ;;
    t ) test_enable_flag=true ;;
    h ) display_help; exit 0 ;;
    \? ) echo "Invalid option: -\${OPTARG}" >&2; display_help; exit 1 ;;
    : ) echo "Invalid option: -\${OPTARG} requires an argument" >&2; display_help; exit 1 ;;
  esac
done
shift \$((OPTIND -1)) # Remove parsed options and args from $@

# III. Interactive Prompts

# 1. Python Virtual Environment
if [ -z "\$python_env_path" ]; then
  if [ -n "\$PYTHON_VENVS" ] && [ -d "\$PYTHON_VENVS" ]; then
    selected_env_name=$(find "\$PYTHON_VENVS" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | fzf --prompt="Select Python Virtual Environment: ")
    if [ -n "\$selected_env_name" ]; then
      python_env_path="\$PYTHON_VENVS/\$selected_env_name/bin/python"
      if [ ! -x "\$python_env_path" ]; then
        echo "Error: Selected Python environment '\$python_env_path' does not contain an executable python." >&2
        # Try to find python3 as a fallback if python is not found
        python_env_path_alt="\$PYTHON_VENVS/\$selected_env_name/bin/python3"
        if [ -x "\$python_env_path_alt" ]; then
            python_env_path="\$python_env_path_alt"
            echo "Using python3 instead: '\$python_env_path'" >&2
        else
            echo "Error: Neither python nor python3 executable found in '\$PYTHON_VENVS/\$selected_env_name/bin'." >&2
            exit 1
        fi
      fi
    else
      echo "No virtual environment selected. Exiting." >&2
      exit 1 # Exit if fzf was cancelled or selection was empty
    fi
  else
    echo "PYTHON_VENVS not set or not a directory. Using system 'python'." >&2
    python_env_path="python"
  fi
fi

# 2. Odoo Executable Path
odoo_bin_path_final="" # Initialize

if [ -n "\$odoo_executable_arg" ]; then
  if [ ! -x "\$odoo_executable_arg" ]; then
    echo "Error: Odoo executable specified via -o is not found or not executable at '\$odoo_executable_arg'." >&2
    exit 1
  fi
  odoo_bin_path_final="\$odoo_executable_arg"
else
  # Fallback to PYTHONPATH if -o is not used
  if [ -z "\$PYTHONPATH" ]; then
    echo "Error: PYTHONPATH environment variable is not set, and -o <odoo_executable_path> was not provided." >&2
    echo "Please set PYTHONPATH to your Odoo source directory or use the -o option." >&2
    exit 1
  fi

  if [ ! -d "\$PYTHONPATH" ]; then
    echo "Error: PYTHONPATH directory '\$PYTHONPATH' does not exist." >&2
    exit 1
  fi

  odoo_bin_path_on_pythonpath="\$PYTHONPATH/odoo-bin"
  if [ ! -x "\$odoo_bin_path_on_pythonpath" ]; then
    echo "Error: odoo-bin not found or not executable at '\$odoo_bin_path_on_pythonpath' (derived from PYTHONPATH)." >&2
    echo "Consider using the -o option to specify the path directly." >&2
    exit 1
  fi
  odoo_bin_path_final="\$odoo_bin_path_on_pythonpath"
fi

# Final check, though individual paths are checked above
if [ -z "\$odoo_bin_path_final" ] || [ ! -x "\$odoo_bin_path_final" ]; then
  echo "Error: Odoo executable could not be determined or is not executable." >&2
  exit 1
fi

# 3. Database Name
final_database_name="" # Initialize

if [ -n "\$database_name_arg" ]; then # Check if -d option was used
  final_database_name="\$database_name_arg"
else
  # -d was not used, so start interactive prompting
  read -r -p "Enter GitLab issue identifier (e.g., group/project#iid) (leave blank to enter DB name directly): " gitlab_issue_input

  if [ -n "\$gitlab_issue_input" ]; then
    # GitLab issue ID was provided
    if ! echo "\$gitlab_issue_input" | grep -qE ".+/.+#.+"; then
      echo "Error: Invalid GitLab issue identifier format: '\$gitlab_issue_input'. Expected format: group/project#iid" >&2
      exit 1
    fi

    group=\${gitlab_issue_input%%/*}
    temp_after_group=\${gitlab_issue_input#*/}
    project=\${temp_after_group%%#*}
    issue_iid=\${temp_after_group#*#}

    if [ -z "\$group" ] || [ -z "\$project" ] || [ -z "\$issue_iid" ]; then
      echo "Error: Could not parse group, project, or iid from '\$gitlab_issue_input'." >&2
      exit 1
    fi
    
    # Sanitize parts
    group=$(echo "\$group" | sed 's/[^a-zA-Z0-9_]/_/g')
    project=$(echo "\$project" | sed 's/[^a-zA-Z0-9_]/_/g')
    issue_iid=$(echo "\$issue_iid" | sed 's/[^a-zA-Z0-9_]/_/g')

    final_database_name="\${group}_\${project}_\${issue_iid}"
  else
    # GitLab issue ID was left blank, so prompt for DB name directly
    read -r -p "Enter database name: " direct_db_name_input
    if [ -z "\$direct_db_name_input" ]; then
      echo "Error: No database name provided. Exiting." >&2
      exit 1
    fi
    final_database_name="\$direct_db_name_input"
  fi
fi

# Final check if database name was determined
if [ -z "\$final_database_name" ]; then
  echo "Error: Database name could not be determined. Exiting." >&2
  exit 1
fi

# 4. Odoo Config File
if [ -z "\$odoo_config_file_path" ]; then
  if [ -z "\$ODOO_CONFIG_FILES" ]; then
    echo "Error: ODOO_CONFIG_FILES environment variable is not set. It should point to a directory or file pattern for config files." >&2
    exit 1
  fi

  # Check if ODOO_CONFIG_FILES resolves to any actual files
  # Using a subshell to avoid exiting the main script if find returns no results before fzf
  config_file_list=$(find "\$ODOO_CONFIG_FILES" -type f -print0)

  if [ -z "\$config_file_list" ]; then
    echo "Error: No files found matching ODOO_CONFIG_FILES pattern: '\$ODOO_CONFIG_FILES'." >&2
    exit 1
  fi
  
  selected_config=$(echo "\$config_file_list" | fzf --read0 --prompt="Select Odoo Config File: ")

  if [ -z "\$selected_config" ]; then
    echo "No Odoo config file selected. Exiting." >&2
    exit 1
  fi
  odoo_config_file_path="\$selected_config"
fi

# Final check if a config file path is determined and if it exists
if [ -z "\$odoo_config_file_path" ]; then
    echo "Error: Odoo configuration file path could not be determined." >&2
    exit 1
elif [ ! -f "\$odoo_config_file_path" ]; then
    echo "Error: Selected Odoo configuration file does not exist: '\$odoo_config_file_path'." >&2
    exit 1
fi

# 5. Addons to Install
final_addons_to_install="" # Initialize

if [ -n "\$addons_to_install_cmd" ]; then # Check if -i option was used
  final_addons_to_install="\$addons_to_install_cmd"
else
  # -i was not used, so start interactive prompting for install addons
  echo "Enter addons to INSTALL (one per line, press Enter on an empty line to finish):"
  addons_install_array=()
  while true; do
    read -r addon_name
    if [ -z "\$addon_name" ]; then
      break # Exit loop on empty line
    fi
    addons_install_array+=("\$addon_name")
  done

  if [ \${#addons_install_array[@]} -gt 0 ]; then
    # Join array elements with a comma
    final_addons_to_install=$(IFS=,; echo "\${addons_install_array[*]}")
  fi
fi

# 6. Addons to Update
final_addons_to_update="" # Initialize

if [ -n "\$addons_to_update_cmd" ]; then # Check if -u option was used
  final_addons_to_update="\$addons_to_update_cmd"
elif [ -z "\$final_addons_to_install" ]; then # Only ask for update if no install addons were given
  # -u was not used AND no install addons were specified, so start interactive prompting for update addons
  echo "Enter addons to UPDATE (one per line, press Enter on an empty line to finish):"
  addons_update_array=()
  while true; do
    read -r addon_name
    if [ -z "\$addon_name" ]; then
      break # Exit loop on empty line
    fi
    addons_update_array+=("\$addon_name")
  done

  if [ \${#addons_update_array[@]} -gt 0 ]; then
    # Join array elements with a comma
    final_addons_to_update=$(IFS=,; echo "\${addons_update_array[*]}")
  fi
fi

# 7. Enable Tests
if [ "\$test_enable_flag" = false ]; then # Check if -t flag was not used
  read -r -p "Enable tests? (y/N): " enable_tests_input
  if [[ "\$enable_tests_input" == "y" || "\$enable_tests_input" == "Y" ]]; then
    test_enable_flag=true
  fi
fi

# IV. Construct and Execute Odoo Command

# 1. Odoo Executable Path (odoo_bin_path_final was determined in III.2)

# 2. Command Array Initialization
cmd_array=()
if [ -n "\$python_env_path" ] && [ "\$python_env_path" != "python" ]; then
  # If a virtual env python is specified, use it
  cmd_array+=("\$python_env_path" "\$odoo_bin_path_final")
else
  # Otherwise, use 'python' (system python) and odoo_bin_path_final
  # (This assumes odoo_bin_path_final is either absolute or findable in PATH if python_env_path is just 'python')
  cmd_array+=("python" "\$odoo_bin_path_final")
fi

# 3. Append Arguments
if [ -n "\$final_database_name" ]; then
  cmd_array+=("-d" "\$final_database_name")
fi

if [ -n "\$odoo_config_file_path" ]; then
  cmd_array+=("-c" "\$odoo_config_file_path")
fi

if [ -n "\$final_addons_to_install" ]; then
  cmd_array+=("-i" "\$final_addons_to_install")
elif [ -n "\$final_addons_to_update" ]; then # Only use -u if -i is not used
  cmd_array+=("-u" "\$final_addons_to_update")
fi

if [ "\$test_enable_flag" = true ]; then
  cmd_array+=("--test-enable" "--stop-after-init")
fi

# 4. Logging
echo # Add a newline for better readability before the command
echo "----------------------------------------------------------------------"
echo "Running Odoo with the following command:"
echo "\${cmd_array[*]}"
echo "----------------------------------------------------------------------"
echo # Add a newline for better readability after the command

# 5. Execution
exec "\${cmd_array[@]}"
