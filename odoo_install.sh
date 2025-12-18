#!/bin/bash

# ==============================================================================
# Odoo Installation and Setup Script
#
# This script automates the full setup of a new Odoo instance for a
# specific user, including:
# - User creation
# - PostgreSQL user creation and check
# - Odoo cloning from GitHub
# - System and Python dependency installation
# - Python virtual environment creation
# - Odoo configuration file generation
# - Systemd service file creation
# - Correct directory ownership and permissions
# - Service enablement and start
#
# Created for a senior Odoo developer to streamline setup tasks.
# ==============================================================================

# ==============================================================================
# 1. Configuration & User Input
# ==============================================================================
read -p "Enter the new username for the Odoo instance: " OE_USER
read -p "Enter the Odoo version (e.g., 18.0, 17.0): " OE_VERSION
read -p "Enter the port for this Odoo instance (e.g., 8069): " OE_PORT
read -p "Enter the Git URL for your custom addons (e.g., https://github.com/myuser/my-custom-addons): " CUSTOM_ADDONS_GIT_URL

OE_HOME="/home/$OE_USER"
OE_HOME_EXT="$OE_HOME/odoo"
OE_CONFIG="$OE_USER-odoo.conf"
OE_SERVICE="$OE_USER-odoo.service"
CHECKPOINT_FILE="/tmp/odoo_setup_checkpoint_$OE_USER"

# Exit on any command failure
set -e

# ==============================================================================
# 2. Checkpoint System
# ==============================================================================
function save_checkpoint() {
    echo "$1" > "$CHECKPOINT_FILE"
}

function get_last_checkpoint() {
    if [ -f "$CHECKPOINT_FILE" ]; then
        cat "$CHECKPOINT_FILE"
    else
        echo "0"
    fi
}

LAST_CHECKPOINT=$(get_last_checkpoint)
CURRENT_STEP=0

function step() {
    CURRENT_STEP=$1
    if [ "$LAST_CHECKPOINT" -lt "$CURRENT_STEP" ]; then
        echo "--- Starting Step $CURRENT_STEP: $2 ---"
        return 0
    else
        echo "--- Skipping Step $CURRENT_STEP: $2 (Already completed) ---"
        return 1
    fi
}

# ==============================================================================
# 3. Installation Steps
# ==============================================================================

# Step 1: Check & Install PostgreSQL
if step 1 "Check & Install PostgreSQL"; then
    echo "Checking for PostgreSQL installation..."
    if ! command -v psql &> /dev/null; then
        echo "PostgreSQL not found. Installing now..."
        sudo apt-get update
        sudo apt-get install postgresql postgresql-contrib -y
    else
        echo "PostgreSQL is already installed. Skipping installation."
    fi
    save_checkpoint 1
fi

# Step 2: Set Timezone
if step 2 "Set Timezone"; then
    echo "Setting system timezone to Asia/Riyadh..."
    sudo timedatectl set-timezone Asia/Riyadh
    echo "System timezone set successfully."
    save_checkpoint 2
fi

# Step 3: Create System User and PostgreSQL User
if step 3 "Create System User and PostgreSQL User"; then
    echo "Creating system user '$OE_USER'..."
    # Check if the system group exists. If not, create it first.
    if ! getent group "$OE_USER" >/dev/null; then
        echo "Group '$OE_USER' does not exist. Creating it now..."
        sudo addgroup --system "$OE_USER"
    fi

    # Check if the user exists. If not, create them.
    if ! id -u "$OE_USER" >/dev/null 2>&1; then
        echo "User '$OE_USER' does not exist. Creating it now..."
        sudo adduser --system --shell=/bin/bash --gecos "Odoo user" --disabled-password --home "$OE_HOME" --ingroup "$OE_USER" "$OE_USER"
        sudo usermod -L "$OE_USER" # Lock the user account
        echo "User '$OE_USER' created successfully."
    else
        # If the user exists, ensure they are in the correct group.
        echo "User '$OE_USER' already exists. Ensuring they are in group '$OE_USER'..."
        sudo usermod -a -G "$OE_USER" "$OE_USER"
    fi

    echo "Creating PostgreSQL user '$OE_USER' with superuser rights..."
    # Check if the user already exists in PostgreSQL
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_user WHERE usename = '$OE_USER'" | grep -q 1; then
        echo "PostgreSQL user '$OE_USER' already exists. Skipping creation."
    else
        sudo -u postgres createuser --createdb --superuser --no-createrole "$OE_USER"
        echo "PostgreSQL user '$OE_USER' created successfully."
    fi

    # Set the timezone for the new PostgreSQL user
    echo "Setting PostgreSQL timezone for user '$OE_USER'..."
    sudo -u postgres psql -c "ALTER USER \"$OE_USER\" SET TIMEZONE = 'Asia/Riyadh';"
    echo "PostgreSQL timezone set."
    save_checkpoint 3
fi

# Step 4: Git Clone Odoo Source Code
if step 4 "Git Clone Odoo Source Code"; then
    # Check if the Odoo directory already exists
    if [ -d "$OE_HOME_EXT" ]; then
        echo "Odoo directory already exists. Skipping cloning."
    else
        echo "Cloning Odoo version $OE_VERSION to $OE_HOME_EXT..."
        sudo git clone --depth 1 --branch "$OE_VERSION" https://www.github.com/odoo/odoo "$OE_HOME_EXT"
        # --- NEW: Set ownership to the correct user
        sudo chown -R "$OE_USER:$OE_USER" "$OE_HOME_EXT"
        echo "Odoo cloned."
    fi
    save_checkpoint 4
fi

# Step 5: Install System Dependencies
if step 5 "Install System Dependencies"; then
    echo "Installing core system dependencies..."
    sudo apt-get update
    sudo apt-get upgrade -y
    sudo apt-get install -y git python3-cffi build-essential wget python3-dev python3-venv python3-wheel libxslt-dev libzip-dev libldap2-dev libsasl2-dev python3-setuptools node-less libpng-dev libjpeg-dev gdebi libpq-dev

    echo "Installing NodeJS and NPM..."
    sudo apt-get install -y nodejs npm
    sudo npm install -g rtlcss

    echo "Installing wkhtmltopdf..."
    sudo apt-get install -y wkhtmltopdf
    save_checkpoint 5
fi

# Step 6: Create Virtual Environment and Install Python Dependencies
if step 6 "Create Virtual Environment and Install Python Dependencies"; then
    # Create the virtual environment only if the directory does not exist.
    if [ ! -d "$OE_HOME_EXT/venv" ]; then
        echo "Creating Python virtual environment..."
        sudo su - "$OE_USER" -c "
            python3 -m venv \"$OE_HOME_EXT/venv\"
            echo \"Virtual environment created.\"
        "
    else
        echo "Virtual environment already exists. Skipping creation."
    fi

    # Install Python packages regardless of whether the venv was just created or already existed.
    sudo su - "$OE_USER" -c "
        source \"$OE_HOME_EXT/venv/bin/activate\"
        echo \"Installing Python packages from Odoo requirements.txt...\"
        pip3 install --no-cache-dir -r \"$OE_HOME_EXT/requirements.txt\"
        echo \"Installing additional Python packages...\"
        pip3 install --no-cache-dir num2words ofxparse dbfread ebaysdk firebase_admin pyOpenSSL
        echo \"Python virtual environment setup complete.\"
    "
    save_checkpoint 6
fi

# Step 7: Install LESS CSS dependencies
if step 7 "Install LESS CSS dependencies"; then
    echo "Installing LESS CSS dependencies..."
    sudo npm install -g less less-plugin-clean-css
    save_checkpoint 7
fi

# Step 8: Create Odoo Directories
if step 8 "Create Odoo Directories"; then
    echo "Creating Odoo data and custom addons directories..."
    OE_DATA_DIR="$OE_HOME/data"
    OE_CUSTOM_ADDONS_DIR="$OE_HOME/custom-addons"
    mkdir -p "$OE_DATA_DIR"
    mkdir -p "$OE_CUSTOM_ADDONS_DIR"
    save_checkpoint 8
fi

# Step 9: Generate SSH Key for User
if step 9 "Generate SSH Key for User"; then
    echo "Generating SSH key for user '$OE_USER'..."
    SSH_DIR="$OE_HOME/.ssh"
    # Check if .ssh directory and key already exist
    if [ ! -d "$SSH_DIR" ]; then
        sudo mkdir -p "$SSH_DIR"
        sudo chown -R "$OE_USER:$OE_USER" "$SSH_DIR"
        sudo chmod 700 "$SSH_DIR"
        sudo -u "$OE_USER" ssh-keygen -t rsa -b 4096 -f "$SSH_DIR/id_rsa" -N "" -q
        echo "SSH key generated and saved to $SSH_DIR/id_rsa"
    else
        echo ".ssh directory already exists. Skipping SSH key generation."
    fi
    save_checkpoint 9
fi

# Step 10: Clone Custom Odoo Addons
if step 10 "Clone Custom Odoo Addons"; then
    echo "Cloning custom Odoo addons from $CUSTOM_ADDONS_GIT_URL..."
    CUSTOM_ADDONS_DIR_NAME=$(basename "$CUSTOM_ADDONS_GIT_URL" .git)
    CUSTOM_ADDONS_PATH="$OE_CUSTOM_ADDONS_DIR/$CUSTOM_ADDONS_DIR_NAME"
    if [ -d "$CUSTOM_ADDONS_PATH" ]; then
        echo "Custom addons directory '$CUSTOM_ADDONS_DIR_NAME' already exists. Skipping cloning."
    else
        sudo git clone "$CUSTOM_ADDONS_GIT_URL" "$CUSTOM_ADDONS_PATH"
        sudo chown -R "$OE_USER:$OE_USER" "$CUSTOM_ADDONS_PATH"
        echo "Custom addons cloned successfully to $CUSTOM_ADDONS_PATH"
    fi
    save_checkpoint 10
fi

# Step 11: Create Odoo Configuration File
if step 11 "Create Odoo Configuration File"; then
    echo "Creating Odoo configuration file at $OE_HOME/$OE_CONFIG..."
    sudo touch "$OE_HOME/$OE_CONFIG"
    sudo chown "$OE_USER:$OE_USER" "$OE_HOME/$OE_CONFIG"
    cat << EOF | sudo tee "$OE_HOME/$OE_CONFIG" > /dev/null
[options]
; This is the password that allows database operations:
admin_passwd = admin_password
db_host = False
db_port = False
db_user = $OE_USER
db_password = False
xmlrpc_port = $OE_PORT
; Specify the addons path. Add your custom addons here.
addons_path = $OE_HOME_EXT/addons,$OE_CUSTOM_ADDONS_DIR
logfile = $OE_DATA_DIR/odoo-server.log
data_dir = $OE_DATA_DIR
EOF
    echo "Configuration file created successfully."
    save_checkpoint 11
fi

# Step 12: Create Systemd Service File
if step 12 "Create Systemd Service File"; then
    echo "Creating systemd service file at /etc/systemd/system/$OE_SERVICE..."
    cat << EOF | sudo tee "/etc/systemd/system/$OE_SERVICE" > /dev/null
[Unit]
Description=Odoo Server
Requires=postgresql.service
After=network.target postgresql.service

[Service]
Type=simple
SyslogIdentifier=$OE_USER-odoo
PermissionsStartOnly=true
User=$OE_USER
Group=$OE_USER
ExecStart="$OE_HOME_EXT/venv/bin/python3" "$OE_HOME_EXT/odoo-bin" -c "$OE_HOME/$OE_CONFIG"
WorkingDirectory=$OE_HOME_EXT
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
EOF
    echo "Systemd service file created."
    save_checkpoint 12
fi

# Step 13: Set Ownership and Permissions
if step 13 "Set Ownership and Permissions"; then
    echo "Setting ownership and permissions for Odoo directories..."
    sudo chown -R "$OE_USER:$OE_USER" "$OE_HOME_EXT"
    sudo chown -R "$OE_USER:$OE_USER" "$OE_DATA_DIR"
    sudo chown -R "$OE_USER:$OE_USER" "$OE_CUSTOM_ADDONS_DIR"

    # Secure the service file
    sudo chmod 755 "/etc/systemd/system/$OE_SERVICE"
    sudo chown root: "/etc/systemd/system/$OE_SERVICE"
    save_checkpoint 13
fi

# Step 14: Start and Enable Odoo Service
if step 14 "Start and Enable Odoo Service"; then
    echo "Reloading systemd daemon and starting service..."
    sudo systemctl daemon-reload
    sudo systemctl enable "$OE_SERVICE"
    sudo systemctl start "$OE_SERVICE"
    save_checkpoint 14
fi

echo "Setup is complete!"
echo "You can check the service status with: sudo systemctl status $OE_SERVICE"
echo "The Odoo server should be accessible on port $OE_PORT."
# Remove checkpoint file upon successful completion
rm "$CHECKPOINT_FILE"
