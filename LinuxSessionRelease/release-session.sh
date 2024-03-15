#!/bin/bash

# Monitors the status of XRDP sessions and updates a database record when a user disconnects

# Azure Key Vault details
KEYVAULT_NAME="yourKeyVaultName"
DB_USER_SECRET_NAME="yourPasswordSecretName"
DB_HOST_SECRET_NAME="yourPasswordSecretName"
PASSWORD_SECRET_NAME="yourPasswordSecretName"
DB_NAME_SECRET_NAME="yourPasswordSecretName"
DB_TABLE_NAME_SECRET_NAME="yourPasswordSecretName"

# Crobjob parameters for xrdp
SCRIPT_PATH_TO_CHECK_XRDP_USERS_INFO="xrdp-who-xnc.sh"
CURRENT_USERS_DETAILS="xrdp-loggedin-users.txt"


# Function to check Azure login status
check_az_login() {
    # Attempt to get the current Azure account details
    az account show &> /dev/null

    # Check the command's exit status
    if [ $? -eq 0 ]; then
        echo "Already logged in to Azure."
        return 0
    else
        echo "Not logged in to Azure, attempting login..."
        az login --identity
        if [ $? -eq 0 ]; then
            echo "Logged in to Azure successfully."
            return 0
        else
            echo "Failed to log in to Azure."
            return 1
        fi
    fi
}

function update_db_username(){

    # MySQL/MariaDB connection parameters
    DB_USER=$(az keyvault secret show --name $DB_USER_SECRET_NAME --vault-name $KEYVAULT_NAME --query value -o tsv)
    DB_HOST=$(az keyvault secret show --name $DB_HOST_SECRET_NAME --vault-name $KEYVAULT_NAME --query value -o tsv)
    DB_PASSWORD=$(az keyvault secret show --name $PASSWORD_SECRET_NAME --vault-name $KEYVAULT_NAME --query value -o tsv)
    DB_NAME=$(az keyvault secret show --name $DB_NAME_SECRET_NAME --vault-name $KEYVAULT_NAME --query value -o tsv)
    DB_TABLE_NAME=$(az keyvault secret show --name $DB_TABLE_NAME_SECRET_NAME --vault-name $KEYVAULT_NAME --query value -o tsv)

    UPDATE_RECORD_QUERY="UPDATE  $DB_TABLE_NAME SET AvdHost = 'None' WHERE Hostname = '$HOSTNAME';"
    /opt/mssql-tools18/bin/sqlcmd -S "$DB_HOST" -U "$DB_USER" -P "$DB_PASSWORD" -d "$DB_NAME" -Q "$UPDATE_RECORD_QUERY"
}

if ! check_az_login; then
        echo "Azure login required."
        exit 1
    fi

while true; do
    # Execute the script to check xrdp logged-in users and redirect output
    . $SCRIPT_PATH_TO_CHECK_XRDP_USERS_INFO > $CURRENT_USERS_DETAILS

    # Read the output file line by line
    while IFS=, read -r pid username start_time status; do
        # Trim potential leading/trailing whitespace from status
        status=$(echo $status | xargs)

        # Check if the user is disconnected and take action
        if [[ "$status" == "disconnected" ]]; then
            # may need to change to include user name in the WHERE clause
            update_db_username
        fi
    done < "$CURRENT_USERS_DETAILS"

    sleep 5 # Check every 5 seconds
done

