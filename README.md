# Odoo Installation Script

Automated Bash script for setting up complete Odoo instances on Ubuntu/Debian systems. Designed for senior Odoo developers to streamline deployment of multiple Odoo instances with custom configurations.

## Features

- **Automated Installation**: Complete Odoo setup with a single script execution
- **Multi-Instance Support**: Create multiple Odoo instances on the same server with different users and ports
- **Checkpoint System**: Resume installation from where it left off if interrupted
- **Custom Addons Support**: Automatically clone and configure custom addon repositories
- **PostgreSQL Integration**: Automated database user creation with proper permissions
- **Systemd Service**: Creates and enables systemd service for automatic startup
- **Virtual Environment**: Isolated Python environment for each Odoo instance

## Prerequisites

- Ubuntu 18.04+ or Debian 9+ (tested on Ubuntu)
- Root or sudo access
- Internet connection for downloading packages
- Git installed (or will be installed by the script)

## What Gets Installed

The script installs and configures the following components:

### System Packages
- PostgreSQL and postgresql-contrib
- Python 3 development tools (python3-dev, python3-venv, python3-wheel)
- Build tools (build-essential, git, wget)
- Required libraries (libxslt-dev, libzip-dev, libldap2-dev, libsasl2-dev, libpq-dev, libpng-dev, libjpeg-dev)
- Node.js and NPM
- wkhtmltopdf 0.12.6.1-2 (patched version for Qt - fixes header/footer rendering issues)
- LESS CSS compiler and plugins

### Python Packages (in virtual environment)
- All packages from Odoo's requirements.txt
- Additional packages: num2words, ofxparse, dbfread, ebaysdk, firebase_admin, pyOpenSSL

### Odoo Components
- Odoo source code (specified version)
- Custom addons repository (from provided Git URL)
- Configuration file
- Systemd service file

## Usage

### Run Directly from GitHub (Recommended)

You can run the script directly from GitHub without cloning the repository:

> **Note:** It's recommended to review the script content before running it directly.

#### Method 1: Using curl (one-liner)
```bash
curl -fsSL https://raw.githubusercontent.com/abdalmola-apps/OdooInstallScript/main/odoo_install.sh | sudo bash
```

#### Method 2: Using wget (one-liner)
```bash
wget -qO- https://raw.githubusercontent.com/abdalmola-apps/OdooInstallScript/main/odoo_install.sh | sudo bash
```

#### Method 3: Download first, then execute
```bash
# Download the script
wget https://raw.githubusercontent.com/abdalmola-apps/OdooInstallScript/main/odoo_install.sh

# Make it executable
chmod +x odoo_install.sh

# Run it
sudo ./odoo_install.sh
```

Or using curl:
```bash
# Download the script
curl -O https://raw.githubusercontent.com/abdalmola-apps/OdooInstallScript/main/odoo_install.sh

# Make it executable
chmod +x odoo_install.sh

# Run it
sudo ./odoo_install.sh
```

### Basic Usage (From Cloned Repository)

1. Clone the repository:
```bash
git clone https://github.com/abdalmola-apps/OdooInstallScript.git
cd OdooInstallScript
```

2. Make the script executable:
```bash
chmod +x odoo_install.sh
```

3. Run the script with sudo:
```bash
sudo ./odoo_install.sh
```

4. Provide the requested information:
   - **Username**: Name for the Odoo system user (e.g., `odoo18`, `client1`)
   - **Odoo Version**: Branch/version to install (e.g., `18.0`, `17.0`, `16.0`)
   - **Port**: Port number for this instance (e.g., `8069`, `8070`)
   - **Custom Addons Git URL**: Repository URL for custom addons

### Example Installation

```bash
sudo ./odoo_install.sh

Enter the new username for the Odoo instance: odoo18
Enter the Odoo version (e.g., 18.0, 17.0): 18.0
Enter the port for this Odoo instance (e.g., 8069): 8069
Enter the Git URL for your custom addons: https://github.com/mycompany/custom-addons
```

## Installation Steps

The script performs 14 automated steps:

1. **Check & Install PostgreSQL**: Verifies PostgreSQL installation or installs if missing
2. **Set Timezone**: Configures system timezone to Asia/Riyadh
3. **Create Users**: Creates system user and PostgreSQL user with superuser rights
4. **Clone Odoo**: Downloads Odoo source code from GitHub
5. **Install System Dependencies**: Installs all required system packages
6. **Setup Python Environment**: Creates virtual environment and installs Python packages
7. **Install LESS CSS**: Installs LESS compiler for frontend styling
8. **Create Directories**: Sets up data and custom addons directories
9. **Generate SSH Key**: Creates SSH key for the Odoo user
10. **Clone Custom Addons**: Downloads custom addons from provided repository
11. **Create Configuration**: Generates Odoo configuration file
12. **Create Service**: Sets up systemd service file
13. **Set Permissions**: Configures proper ownership and permissions
14. **Start Service**: Enables and starts the Odoo service

## Checkpoint System

The script includes a checkpoint system that saves progress after each step. If the installation is interrupted:

- The script can be re-run with the same username
- Previously completed steps will be skipped automatically
- Installation resumes from the last incomplete step

Checkpoint files are stored in `/tmp/odoo_setup_checkpoint_<username>`

## Directory Structure

After installation, the following structure is created:

```
/home/<username>/
├── odoo/                    # Odoo source code
│   ├── addons/             # Standard Odoo addons
│   ├── odoo-bin            # Odoo executable
│   ├── venv/               # Python virtual environment
│   └── requirements.txt    # Python dependencies
├── data/                    # Odoo data directory
│   └── odoo-server.log     # Log file
├── custom-addons/           # Custom addons repository
│   └── <addon-repo>/       # Cloned custom addons
├── .ssh/                    # SSH keys for git operations
│   └── id_rsa              # Generated SSH key
└── <username>-odoo.conf    # Odoo configuration file
```

## Configuration File

The script generates a configuration file at `/home/<username>/<username>-odoo.conf` with:

- Admin password: `admin_password` (change this after installation!)
- Database user: matches the system username
- HTTP port: as specified during installation
- XML-RPC port: same as HTTP port
- Addons path: includes both standard and custom addons
- Log file location
- Data directory location

## Service Configuration

The systemd service includes the following optimizations:
- **XDG_RUNTIME_DIR**: Set to `/tmp/runtime-<username>` to prevent Qt warnings
- **Auto-start**: Enabled by default on system boot
- **PostgreSQL dependency**: Ensures database is ready before Odoo starts

## Service Management

After installation, manage the Odoo service with systemctl:

```bash
# Check service status
sudo systemctl status <username>-odoo.service

# Stop service
sudo systemctl stop <username>-odoo.service

# Start service
sudo systemctl start <username>-odoo.service

# Restart service
sudo systemctl restart <username>-odoo.service

# View logs
sudo journalctl -u <username>-odoo.service -f
```

## Accessing Odoo

After successful installation:

1. Open your web browser
2. Navigate to: `http://localhost:<port>` or `http://your-server-ip:<port>`
3. Create your first database using the Odoo database manager

## Security Considerations

After installation, you should:

1. **Change admin password**: Edit the configuration file and update `admin_passwd`
2. **Configure firewall**: Restrict access to Odoo ports
3. **Setup NGINX/Apache**: Use a reverse proxy for production
4. **Enable SSL**: Configure HTTPS for secure connections
5. **Update SSH keys**: Add the generated SSH key to your Git provider for custom addons access

## Troubleshooting

### Service won't start
```bash
# Check service logs
sudo journalctl -u <username>-odoo.service -n 50

# Check Odoo log file
sudo tail -f /home/<username>/data/odoo-server.log

# Verify Python dependencies
sudo su - <username>
source odoo/venv/bin/activate
pip list
```

### Port already in use
- Choose a different port during installation
- Check running services: `sudo netstat -tulpn | grep :<port>`

### PostgreSQL connection issues
```bash
# Verify PostgreSQL user
sudo -u postgres psql -c "\du"

# Test connection
sudo -u <username> psql -l
```

### Permission errors
```bash
# Reset permissions
sudo chown -R <username>:<username> /home/<username>/
```

## Multiple Instances

To install multiple Odoo instances:

1. Run the script again with a different username
2. Specify a different port number
3. Each instance will have its own:
   - System user
   - PostgreSQL user
   - Odoo installation
   - Configuration file
   - Systemd service

## Requirements File

If you need to install additional Python packages:

```bash
sudo su - <username>
source odoo/venv/bin/activate
pip install <package-name>
```

## Uninstalling

To remove an Odoo instance:

```bash
# Stop and disable service
sudo systemctl stop <username>-odoo.service
sudo systemctl disable <username>-odoo.service
sudo rm /etc/systemd/system/<username>-odoo.service

# Remove PostgreSQL user
sudo -u postgres dropuser <username>

# Remove system user and home directory
sudo userdel -r <username>

# Reload systemd
sudo systemctl daemon-reload
```

## Contributing

Feel free to submit issues, fork the repository, and create pull requests for improvements.

## License

This script is provided as-is for use by Odoo developers and system administrators.

## Author

**abdalmola**

Created for senior Odoo developers to streamline instance deployment and management.
