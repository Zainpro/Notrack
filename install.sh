#!/usr/bin/env bash
#Title : NoTrack Installer
#Description : This script will install NoTrack and then configure dnsmasq and lighttpd
#Authors : QuidsUp, floturcocantsee, rchard2scout, fernfrost
#Usage : bash install.sh


#######################################
# User Configerable Settings
#######################################
INSTALL_LOCATION=""                         #define custom installation path


#######################################
# Constants
#######################################
readonly IP_V4="IPv4"
readonly IP_V6="IPv6"

readonly DHCPCD_CONF_PATH="/etc/dhcpcd.conf"
readonly DHCPCD_CONF_OLD_PATH="/etc/dhcpcd.conf.old"
readonly NETWORK_INTERFACES_PATH="/etc/network/interfaces"
readonly NETWORK_INTERFACES_OLD_PATH="/etc/network/interfaces.old"
readonly DNSMASQ_CONF_PATH="/etc/dnsmasq.conf"

readonly VERSION="0.9.5"

#######################################
# Global Variables
#######################################
DBUSER="ntrk"
DBPASSWORD="ntrkpass"
DBNAME="ntrkdb"

SUDO_REQUIRED=false                              #true if installing to /opt
REBOOT_REQUIRED=false
SETUP_STATIC_IP_ADDRESS=false
GATEWAY_ADDRESS=""
IP_ADDRESS=""
NETWORK_DEVICE=""
IP_VERSION=""
DNS_SERVER_1=""
DNS_SERVER_2=""
BROADCAST_ADDRESS=""
NETMASK_ADDRESS=""
NETWORK_START_ADDRESS=""
hostname="notrack.local"


#######################################
# Exit script with exit code
# Globals:
#   None
# Arguments:
#   $1 Error Message
#   $2 Exit Code
# Returns:
#   Exit Code
#######################################
error_exit() {
  echo "Error :-( $1"
  echo "Aborting"
  exit "$2"
}


#######################################
# Start service
#   Start and Enable systemd based services
#   TODO complete for sv and sysvinit
#
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
service_start() {
  if [[ -n $1 ]]; then
    echo "Starting $1"
    if [ "$(command -v systemctl)" ]; then                 #systemd
      sudo systemctl enable "$1"
      sudo systemctl start "$1"
    fi
  fi
}

#######################################
# Restart service
#    with either systemd or sysvinit or runit
#
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
service_restart() {
  if [[ -n $1 ]]; then
    echo "Restarting $1"
    if [ "$(command -v systemctl)" ]; then       #systemd
      sudo systemctl restart "$1"
    elif [ "$(command -v service)" ]; then       #sysvinit
      sudo service "$1" restart
    elif [ "$(command -v sv)" ]; then            #runit
      sudo sv restart "$1"
    else
      error_exit "Unable to restart services. Unknown service supervisor" "21"
    fi
  fi
}


#######################################
# Draw prompt menu
#   1. Clear Screen
#   2. Draw menu
#   3. Read single character of user input
#   4. Evaluate user input
#   4a. Check if value is between 0-9
#   4b. Check if value is between 1 and menu size. Return out of function if sucessful
#   4c. Check if user pressed the up key (ending A), Move highlighted point
#   4d. Check if user pressed the up key (ending B), Move highlighted point
#   4e. Check if user pressed Enter key, Return out of function
#   4f. Check if user pressed Q or q, Exit out with error code 1
#   5. User failed to input valid selection. Loop back to #2
#
# Globals:
#   None
# Arguments:
#   $1 = Title, $2, $3... Option 1, 2
# Returns:
#   $? = Choice user made
#######################################
menu() {
  local choice
  local highlight
  local menu_size

  highlight=1
  menu_size=0
  clear
  while true; do
    for i in "$@"; do
      if [ $menu_size == 0 ]; then                #$1 Is Title
        echo -e "$1"
        echo
      else
        if [ $highlight == $menu_size ]; then
          echo " * $menu_size: $i"
        else
          echo "   $menu_size: $i"
        fi
      fi
      ((menu_size++))
    done

    read -r -sn1 choice;
    echo "$choice"
    if [[ $choice =~ ^[0-9]+$ ]]; then           #Has the user chosen 0-9
      if [[ $choice -ge 1 ]] && [[ $choice -lt $menu_size ]]; then
        return "$choice"
      fi
    elif [[ $choice ==  "A" ]]; then             #Up
      if [ $highlight -le 1 ]; then              #Loop around list
        highlight=$((menu_size-1))
        echo
      else
        ((highlight--))
      fi
    elif [[ $choice ==  "B" ]]; then             #Down
      if [ $highlight -ge $((menu_size-1)) ]; then #Loop around list
        highlight=1
        echo
      else
        ((highlight++))
      fi
    elif [[ $choice == "" ]]; then               #Enter
      return "$highlight"                        #Return Highlighted value
    elif [[ $choice == "q" ]] || [[ $choice == "Q" ]]; then
      exit 1
    fi
    #C Right, D Left

    menu_size=0
    clear
  done
}


#######################################
# Copy File
#   Checks if Source file exists, then copies it to Destination
#
# Globals:
#   INSTALL_LOCATION
# Arguments:
#   $1: Source
#   $2: Destination
# Returns:
#   None
#######################################
function copy_file() {
  if [ -e "$1" ]; then                                     #Does file exist?
    echo "Copying $1 to $2"
    sudo cp "$1" "$2"
  else
    echo "WARNING: Unable to find file $1 :-("             #Display a warning if file doesn't exist
  fi
}


#######################################
# Rename File
#   Renames Source file to Destination
#   Set permissions to -rwxr-xr-x
#
# Globals:
#   None
# Arguments:
#   $1: Source
#   $2: Destination
# Returns:
#   None
#######################################
function rename_file() {
  if [ -e "$1" ]; then                                     #Does file exist?
    sudo mv "$1" "$2"
    sudo chmod 755 "$2"
  else
    echo "WARNING: Unable to rename file $1 :-("
  fi
}


#######################################
# Create File
# Checks if a file exists and creates it
#
# Globals:
#   None
# Arguments:
#   #$1 File to create
# Returns:
#   None
#######################################
function create_file() {
  if [ ! -e "$1" ]; then                         #Does file already exist?
    echo "Creating file: $1"
    sudo touch "$1"                              #If not then create it
    sudo chmod 664 "$1"                          #RW RW R permissions
  fi
}

#######################################
# Create Folder
#   Creates a folder if it doesn't exist
# Globals:
#   None
# Arguments:
#   $1 - Folder to create
# Returns:
#   None
#######################################
function create_folder() {
  if [ ! -d "$1" ]; then                         #Does folder exist?
    echo "Creating folder: $1"                   #Tell user folder being created
    sudo mkdir "$1"                              #Create folder
  fi
}


#######################################
# Delete File
#   Checks if a file exists and then deletes it
#
# Globals:
#   None
# Arguments:
#   #$1 File to delete
# Returns:
#   None
#######################################
function delete_file() {
  if [ -e "$1" ]; then                           #Does file exist?
    echo "Deleting file $1"
    sudo rm "$1"                                 #If yes then delete it
  fi
}


#######################################
# Backup Config Files
#   Take backups of dnsmasq and lighttpd
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
function backup_configs() {
  echo "Backing up old config files"
  copy_file /etc/dnsmasq.conf /etc/dnsmasq.conf.old
  copy_file /etc/lighttpd/lighttpd.conf /etc/lighttpd/lighttpd.conf.old
  echo "========================================================="
  echo
}


#######################################
# Copy Scripts
#   Copy notrack script files to /usr/local/sbin
# Globals:
#   INSTALL_LOCATION
# Arguments:
#   None
# Returns:
#   None
#######################################
function copy_scripts() {
  #Blocklist parser
  copy_file "$INSTALL_LOCATION/scripts/notrack.sh" /usr/local/sbin/notrack.sh
  rename_file /usr/local/sbin/notrack.sh /usr/local/sbin/notrack
  sudo chmod 755 /usr/local/sbin/notrack

  #Ntrk-Exec DEPRECATED
  copy_file "$INSTALL_LOCATION/scripts/ntrk-exec.sh" /usr/local/sbin/ntrk-exec.sh
  rename_file /usr/local/sbin/ntrk-exec.sh /usr/local/sbin/ntrk-exec

  #New Ntrk-Exec
  #copy_file "$INSTALL_LOCATION/scripts/ntrk-exec.py" /usr/local/sbin/ntrk-exec.py
  #rename_file /usr/local/sbin/ntrk-exec.py /usr/local/sbin/ntrk-exec

  #Ntrk-Pause
  copy_file "$INSTALL_LOCATION/scripts/ntrk-pause.sh" /usr/local/sbin/
  rename_file /usr/local/sbin/ntrk-pause.sh /usr/local/sbin/ntrk-pause

  #Ntrk-Upgrade
  copy_file "$INSTALL_LOCATION/scripts/ntrk-upgrade.sh" /usr/local/sbin/
  rename_file /usr/local/sbin/ntrk-upgrade.sh /usr/local/sbin/ntrk-upgrade

  #Ntrk-Parser
  copy_file "$INSTALL_LOCATION/scripts/ntrk-parse.sh" /usr/local/sbin/
  rename_file /usr/local/sbin/ntrk-parse.sh /usr/local/sbin/ntrk-parse

  #Ntrk-Analytics
  copy_file "$INSTALL_LOCATION/scripts/ntrk-analytics.sh" /usr/local/sbin/
  rename_file /usr/local/sbin/ntrk-analytics.sh /usr/local/sbin/ntrk-analytics
  #delete_file "/usr/local/sbin/ntrk-analytics"
  #sudo ln -s "$INSTALL_LOCATION/scripts/ntrk-analytics.py" "/usr/local/sbin/ntrk-analytics"
  #set_permissions "$INSTALL_LOCATION/scripts/ntrk-analytics" "775"

  echo "========================================================="
  echo
}


#######################################
# Download with Git
#   Download with Git if the user has it installed on their system
# Globals:
#   INSTALL_LOCATION, SUDO_REQUIRED
# Arguments:
#   None
# Returns:
#   None
#######################################
#function download_with_git() {
  #echo "Downloading NoTrack using Git"

  #if [ $SUDO_REQUIRED == false ]; then
    #git clone --depth=1 https://gitlab.com/quidsup/notrack.git "$INSTALL_LOCATION"
  #else
    #sudo git clone --depth=1 https://gitlab.com/quidsup/notrack.git "$INSTALL_LOCATION"
 #fi
  #echo
}


#######################################
# Download with wget (Modified by Zain)
#   Alternative download if user doesn't have Git
# Globals:
#   INSTALL_LOCATION, SUDO_REQUIRED
# Arguments:
#   None
# Returns:
#   None
#######################################
function download_with_wget() {
  if [ -d "$INSTALL_LOCATION" ]; then            #Check if NoTrack folder exists
    echo "NoTrack folder exists. Skipping download"
  else
    echo "Downloading notrack-v0.9.5 from Gitlab"
    wget https://gitlab.com/quidsup/notrack/-/archive/v0.9.5/notrack-v0.9.5.zip -O /tmp/notrack-master.zip
    #wget https://gitlab.com/quidsup/notrack/-/archive/master/notrack-master.zip -O /tmp/notrack-master.zip
    if [ ! -e /tmp/notrack-master.zip ]; then    #Check to see if download was successful
      #Abort we can't go any further without any code from git
      error_exit "Error Download from Gitlab has failed" "23"
    fi

    unzip -oq /tmp/notrack-master.zip -d /tmp
    if [ $SUDO_REQUIRED == false ]; then
      mv /tmp/notrack-master "$INSTALL_LOCATION"
    else
      sudo mv /tmp/notrack-master "$INSTALL_LOCATION"
    fi
    rm /tmp/notrack-master.zip                   #Cleanup
  fi

  sudo chown "$(whoami)":"$(whoami)" -hR "$INSTALL_LOCATION"
}


#######################################
# Get hostname
#   Attempt to find hostname of system
# Globals:
#   hostname
# Arguments:
#   None
# Returns:
#   None
#######################################
function get_hostname() {
  if [ -e /etc/sysconfig/network ]; then         #Set first entry for localhosts
    hostname=$(grep "HOSTNAME" /etc/sysconfig/network | cut -d "=" -f 2 | tr -d [[:space:]])
  elif [ -e /etc/hostname ]; then
    hostname=$(cat /etc/hostname)
  else
    echo "get_hostname() WARNING: Unable to find hostname"
  fi
}


#######################################
# Install Packages
#   Works out what type of package manager is in use
#   Call appropriate function depending on package manager
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
function install_packages() {
echo "========================================================="
echo "Installing Packages"
echo

  if [ "$(command -v apt)" ]; then install_deb
  elif [ "$(command -v dnf)" ]; then install_dnf
  elif [ "$(command -v pacman)" ]; then install_pacman
  elif [ "$(command -v apk)" ]; then install_apk
  elif [ "$(command -v xbps-install)" ]; then install_xbps
  else
    echo "I don't know which package manager you have."
    echo "Ensure you have the following packages installed:"
    echo -e "\tdnsmasq"
    echo -e "\tlighttpd"
    echo -e "\tmariadb"
    echo -e "\tmemcached"
    echo -e "\tphp-cgi"
    echo -e "\tphp-curl"
    echo -e "\tphp-mysql"
    echo -e "\tphp-memcache"
    echo -e "\tunzip"
    echo
    echo -en "Press any key to continue... "
    read -rn1
    echo
  fi
  echo "========================================================="
  echo
}


#######################################
# Install Deb Packages
#   Installs packages using apt for Ubuntu / Debian based systems
#   Checks to see if PHP7 is available
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
function install_deb() {
  local phpversion="php5"
  local phpmemcache="php5-memcache"
  i=6                                                      #Assume highest version of PHP 7 will be v7.6

  echo "Refreshing apt"
  sudo apt update
  echo

  echo "Searching package archives for latest PHP version"
  while [ $i -ge 0 ]; do                                   #Start while loop at highest version
    apt-cache show php7.$i &> /dev/null                    #Check apt-cache
    if [ $? == 0 ]; then                                   #Return value of zero means package available
      echo "Installing PHP 7.$i"
      phpversion="php7.$i"
      phpmemcache="php-memcache"                           #No version number in PHP >= 7
      break
    else                                                   #Not found, try lower version
      ((i--))
    fi
  done

  if [[ $phpversion == "php5" ]]; then                     #PHP 7 not found, fallback to v5.x
    echo "Installing PHP 5"
  fi

  echo "Preparing to install Deb packages..."
  sleep 2s
  echo "Installing dependencies"
  sleep 2s
  sudo apt -y install unzip
  echo
  echo "Installing Dnsmasq"
  sleep 2s
  sudo apt -y install dnsmasq
  echo
  echo "Installing MariaDB"
  sleep 2s
  sudo apt -y install mariadb-server
  echo
  echo "Installing Webserver"
  sleep 2s
  sudo apt -y install lighttpd
  echo
  echo "Installing PHP"
  sleep 2s
  sudo apt -y install memcached "$phpmemcache" "$phpversion-cgi" "$phpversion-curl" "$phpversion-mysql"
  echo
  echo "Installing Python3"
  sleep 2s
  sudo apt -y install python3 python3-mysql.connector
  echo
  echo "Finished installing Deb packages"
}


#######################################
# Install RPM Packages
#   Installs packages using dnf for Redhat / Fedora
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
function install_dnf() {
  echo "Preparing to install RPM packages using Dnf..."
  sleep 2s
  sudo dnf update
  echo
  echo "Installing dependencies"
  sleep 2s
  sudo dnf -y install unzip
  echo
  echo "Installing Dnsmasq"
  sleep 2s
  sudo dnf -y install dnsmasq
  echo
  echo "Installing MariaDB"
  sleep 2s
  sudo dnf -y install mariadb-server
  echo
  echo "Installing Webserver"
  sleep 2s
  sudo dnf -y install lighttpd
  echo
  echo "Installing PHP"
  sleep 2s
  sudo dnf -y install memcached php-pecl-memcached php
  # php-mysql is probably DEPRECATED now
  sudo dnf -y install php-mysql
  sudo dnf -y install php-mysqlnd
  echo "Installing Python3"
  sleep 2s
  sudo dnf -y install python3 mysql-connector-python3
  echo
}


#######################################
# Install Aur Packages
#   Installs packages using pacman for Arch
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
function install_pacman() {
  echo "Preparing to install Arch packages..."
  sleep 2s
  echo
  echo "Installing dependencies"
  sleep 2s
  sudo pacman -S --noconfirm unzip
  echo
  echo "Installing Dnsmasq"
  sleep 2s
  sudo pacman -S --noconfirm dnsmasq
  echo
  echo "Installing MariaDB"
  sleep 2s
  sudo pacman -S --noconfirm mysql
  echo
  echo "Installing Lighttpd and PHP"
  sleep 2s
  sudo pacman -S --noconfirm fcgi lighttpd php memcached php-memcache php-cgi 
  echo
  
  echo "Enabling MariaDB"
  sudo mysql_install_db --user=mysql --basedir=/usr --datadir=/var/lib/mysql
  sudo systemd start mysqld
  sudo systemd enable mysqld
}


#######################################
# Install apk Packages
#   Installs packages for Busybox
#   TODO
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
function install_apk() {
  echo "Preparing to install packages using Apk..."
  sleep 2s
  sudo apk update
  echo
  echo "Installing dependencies"
  sleep 2s
  sudo apk add unzip
  echo
  echo "Installing Dnsmasq"
  sleep 2s
  sudo apk add dnsmasq
  echo
  echo "Installing Dnsmasq"
  sleep 2s
  sudo apk add mariadb-server
  echo
  echo "Installing Lighttpd and PHP"
  sudo apk add lighttpd php5 memcached php-mysql               #Having issues here
  echo
}


#######################################
# Install xbps Packages
#   Installs packages using xbps-install for VoidLinux
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
function install_xbps() {
  echo "Preparing to install XBPS packages..."
  sudo xbps-install -Suy                         ##sync & update only once
  sleep 2s
  echo
  echo "Installing dependencies"
  sleep 2s
  sudo xbps-install -y unzip
  echo
  echo "Installing Dnsmasq"
  sleep 2s
  sudo xbps-install -y dnsmasq
  echo
  echo "Installing MariaDB"
  sleep 2s
  sudo xbps-install -y mariadb
  #sudo xbps-install -y mysql
  echo
  echo "Installing Lighttpd and PHP"
  sleep 2s
  #sudo xbps-install -y fcgi lighttpd php memcached php-memcache php-cgi ##TODO php-memcache so far unavailable in repository
  sudo xbps-install -y fcgi lighttpd php php-cgi
  echo

  echo "Enabling Services"
  sudo ln -s /etc/sv/mysqld /var/service
  sudo ln -s /etc/sv/dnsmasq /var/service
  sudo ln -s /etc/sv/lighttpd /var/service
  sleep 7s
}



#######################################
# Check Systemd Dnsmasq
#   Attempt to resolve any issues with systemd-resolved dns service conflicting with dnsmasq
#
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   0. Success
#   1. Failure
#
#######################################
function check_systemd_dnsmasq() {
  if [ "$(command -v systemctl)" ]; then
    if (systemctl -q is-active dnsmasq.service); then
      echo "Dnsmasq successfully restarted"
      return 0
    fi
    echo
    echo "WARNING: Dnsmasq has failed to restart. This could be due to a conflict with systemd-resolved service running a stub dns server on port 53."
    echo "This issue is known to affect Ubuntu 19.04"
    echo
    echo "I can fix the issue by adding DNSStubListener=no to /etc/systemd/resolved.conf"
    
    read -p "Do you want me to edit resolved.conf(Y/n)? " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      echo "DNSStubListener=no" | sudo tee -a /etc/systemd/resolved.conf &> /dev/null
      sudo systemctl restart systemd-resolved.service
      sudo systemctl restart dnsmasq.service
    else
      return 1
    fi
  fi
}


#######################################
# Setup Dnsmasq
#   Copy custom config settings into dnsmasq.conf and create log file
#   Create initial entry in /etc/localhosts.list
# Globals:
#   INSTALL_LOCATION, DNS_SERVER_1, DNS_SERVER_2, NETWORK_DEVICE
# Arguments:
#   None
# Returns:
#   None
#######################################
function setup_dnsmasq() {
  echo "Configuring Dnsmasq"
  
  create_folder "/etc/dnsmasq.d"                 #Issue #94 dnsmasq folder not created
  create_file "/var/log/notrack.log"             #File where DNS logs are stored
  chown dnsmasq:root /var/log/notrack.log        #Take ownership with dnsmasq
  chmod 664 /var/log/notrack.log
  create_file "/etc/localhosts.list"             #File for user to add DNS entries for their network
  create_file "/etc/dnsmasq.d/servers.conf"
  
  #Copy config files modified for NoTrack
  echo "Copying Dnsmasq config files from $INSTALL_LOCATION to /etc/conf"
  copy_file "$INSTALL_LOCATION/conf/dnsmasq.conf" /etc/dnsmasq.conf
  
  #Finish configuration of dnsmasq config
  sudo sed -i "s/interface=eth0/interface=$NETWORK_DEVICE/" /etc/dnsmasq.conf
  
  echo "Setting DNS Servers"
  echo "server=$DNS_SERVER_1" | sudo tee -a /etc/dnsmasq.d/servers.conf
  echo "server=$DNS_SERVER_2" | sudo tee -a /etc/dnsmasq.d/servers.conf

  echo "Setting up your /etc/localhosts.list for Local Hosts"
  
  echo "Writing first entry for this system: $IP_ADDRESS - $hostname"
  echo -e "$IP_ADDRESS\t$hostname" | sudo tee -a /etc/localhosts.list 

  service_restart dnsmasq
  check_systemd_dnsmasq
  
  echo "Setup of Dnsmasq complete"
  echo "========================================================="
  echo
  sleep 3s
}


#######################################
# Setup Lighttpd
#   Add www-data/http group rights to user
#   copy lighty config, and create sink page
# Globals:
#   INSTALL_LOCATION
# Arguments:
#   None
# Returns:
#   None
#######################################
setup_lighttpd() {
  local sudoerscheck=""
  local group=""

  echo "Configuring Lighttpd"

  if getent passwd www-data > /dev/null 2>&1; then         #Ubuntu uses group www-data
    echo "Adding www-data rights to $(whoami)"
    sudo usermod -a -G www-data "$(whoami)"
    group="www-data"
  elif getent passwd lighttpd > /dev/null 2>&1; then       #Fedora / Redhat uses group lighttpd
    echo "Adding lighttpd rights to $(whoami)"
    sudo usermod -a -G lighttpd "$(whoami)"
    group="lighttpd"
  elif getent passwd http > /dev/null 2>&1; then           #Arch uses group http
    echo "Adding http rights to $(whoami)"
    sudo usermod -a -G http "$(whoami)"
    group="http"
  elif getent passwd _lighttpd > /dev/null 2>&1; then      #void uses group _lighttpd
    echo "Adding _lighttpd rights to $(whoami)"
    sudo usermod -a -G _lighttpd "$(whoami)"
    group="_lighttpd"
  else
    echo "Setup_Lighttpd: WARNING - Unable to find group for lighttpd (normally www-data or http)"
    echo "Lighttpd webserver will have to be manually setup."
    sleep 8s
    return
  fi
  
  if [ "$(command -v lighty-enable-mod)" ]; then #Is lighty-enable-mod available?
    sudo lighty-enable-mod fastcgi fastcgi-php
  fi
  
  #Copy Config and change user name
  copy_file "$INSTALL_LOCATION/conf/lighttpd.conf" /etc/lighttpd/lighttpd.conf
  sudo sed -i "s/changegroup/$group/" /etc/lighttpd/lighttpd.conf
  sudo sed -i "s/changehost/$hostname/" /etc/lighttpd/lighttpd.conf
  
  #Fix for lighty 1.4.53 changing create-mime.assign and create-mime.conf
  if [ -e "/usr/share/lighttpd/create-mime.assign.pl" ]; then
    echo "Found create-mime.assign.pl, editing lighttpd.conf"
    sudo sed -i 's!##include_shell "/usr/share/lighttpd/create-mime.assign.pl"!include_shell "/usr/share/lighttpd/create-mime.assign.pl"!' /etc/lighttpd/lighttpd.conf
  fi
  
  if [ -e "/usr/share/lighttpd/create-mime.conf.pl" ]; then
    echo "Found create-mime.conf.pl, editing lighttpd.conf"
    sudo sed -i 's!##include_shell "/usr/share/lighttpd/create-mime.conf.pl"!include_shell "/usr/share/lighttpd/create-mime.conf.pl"!' /etc/lighttpd/lighttpd.conf
  fi
  
  #Fix for lighty 1.4.53 moving from include-conf-enabled.pl to /etc/lighttpd/conf-enabled/*.conf
  if [ -e "/usr/share/lighttpd/include-conf-enabled.pl" ]; then
    echo "Found include-conf-enabled.pl"
    if grep --quiet deprecated /usr/share/lighttpd/include-conf-enabled.pl; then
      echo "deprecated version of include-conf-enabled.pl, using newer config setting"
      #Deprecated exists in include-conf-enabled.pl, so use new method
      sudo sed -i 's!##include "/etc/lighttpd/conf-enabled/\*.conf"!include "/etc/lighttpd/conf-enabled/*.conf"!' /etc/lighttpd/lighttpd.conf
    else
      #Deprecated doesn't exist, so go with old method
      echo "legacy version of include-conf-enabled.pl, using older config setting"
      sudo sed -i 's!##include_shell "/usr/share/lighttpd/include-conf-enabled.pl"!include_shell "/usr/share/lighttpd/include-conf-enabled.pl"!' /etc/lighttpd/lighttpd.conf
    fi
  else
    echo "Unable to find include-conf-enabled.pl, assuming newer config setting"
    sudo sed -i 's!##include "/etc/lighttpd/conf-enabled/*.conf"!include "/etc/lighttpd/conf-enabled/*.conf"!' /etc/lighttpd/lighttpd.conf
  fi
  
    
  create_folder "/var/www"                                 #/var/www/html should be created by lighty
  create_folder "/var/www/html"
  delete_file "/var/www/html/index.lighttpd.html"          #Remove default lighty html file
  
  delete_file "/var/www/html/admin"                        #Remove old symlinks

  echo "Creating Sink Folder"                              #Create new sink folder
  create_folder "/var/www/html/sink"
  echo "Setting Block message to 1x1 pixel"
  echo '<img src="data:image/gif;base64,R0lGODlhAQABAAAAACwAAAAAAQABAAA=" alt="" />' | sudo tee /var/www/html/sink/index.html &> /dev/null

  echo "Changing ownership of sink folder to $group"
  sudo chown -hR "$group":"$group" /var/www/html/sink
  sudo chmod -R 775 /var/www/html/sink
  
  echo "Creating symlink from $INSTALL_LOCATION/admin to /var/www/html/admin"
  sudo ln -s "$INSTALL_LOCATION/admin" /var/www/html/admin
  sudo chmod -R 775 /var/www/html                #Give read/write/execute privilages to Web folder
  
  sudoerscheck=$(sudo cat /etc/sudoers | grep "$group")
  if [[ $sudoerscheck == "" ]]; then
    echo "Adding NoPassword permissions for $group to execute script /usr/local/sbin/ntrk-exec as root"
    echo -e "$group\tALL=(ALL:ALL) NOPASSWD: /usr/local/sbin/ntrk-exec" | sudo tee -a /etc/sudoers
    echo
  fi  
  
  if [ "$(command -v pacman)" ]; then          #Custom setup for Arch
    create_folder "/etc/lighttpd/conf.d"
    
    copy_file "$INSTALL_LOCATION/conf/fastcgi.conf" /etc/lighttpd/conf.d/fastcgi.conf
    echo 'include "conf.d/fastcgi.conf"' | sudo tee -a /etc/lighttpd/lighttpd.conf
    sudo sed -i "s/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=1/" /etc/php/php.ini
    sudo sed -i "s/;extension=mysqli.so/extension=mysqli.so/" /etc/php/php.ini
  fi
  
  echo "Setup of Lighttpd complete"
  echo "========================================================="
  echo
  sleep 3s
}


#######################################
# Setup MariaDB
#   Setup user account and password (TODO) for Maria DB
# Globals:
#   DBUSER, DBPASSWORD, DBNAME
# Arguments:
#   None
# Returns:
#   None
#######################################
function setup_mariadb() {
  local dbconfig="$INSTALL_LOCATION/admin/settings/dbconfig.php"
  local rootpass=""

  echo "Setting up MariaDB"
  echo -n "Please enter MariaDB root password you set earlier (leave blank if not set): "
  read -r rootpass;
  
  #Create a random password
  #DBPASSWORD="$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 40 | head -n 1)"

  service_start "mariadb.service"

  echo
  echo "Creating User $DBUSER"
  sudo mysql --user=root --password="$rootpass" -e "CREATE USER '$DBUSER'@'localhost' IDENTIFIED BY '$DBPASSWORD';"
  
  #Check to see if ntrk user has been added
  if [[ ! $(sudo mysql -sN --user=root --password="$rootpass" -e "SELECT User FROM mysql.user") =~ ntrk[[:space:]]root ]]; then
    error_exit "MariaDB command failed, have you entered incorrect root password?" "35"
  fi
  
  echo "Creating Database $DBNAME"
  sudo mysql --user=root --password="$rootpass" -e "CREATE DATABASE $DBNAME;"
    
  echo "Setting privilages for ntrk user"
  sudo mysql --user=root --password="$rootpass" -e "GRANT ALL PRIVILEGES ON $DBNAME.* TO 'ntrk'@'localhost';"
  sudo mysql --user=root --password="$rootpass" -e "GRANT FILE ON *.* TO 'ntrk'@'localhost';"
  #GRANT INSERT, SELECT, DELETE, UPDATE ON database.* TO 'user'@'localhost' IDENTIFIED BY 'password';
  sudo mysql --user=root --password="$rootpass" -e "FLUSH PRIVILEGES;"

  # NOTE This feature will be enabled in NoTrack 0.9.7
  #add password to local dbconfig.php
  #touch "$dbconfig"
  #echo "<?php" > "$dbconfig"
  #echo "//Local MariaDB password generated at install" >> "$dbconfig"
  #echo "\$dbconfig->password = '$dbpassword';" >> "$dbconfig"
  #echo "?>" >> "$dbconfig"

  #Create CRON Job for ntrk-parse
  echo "Creating cron job for Log Parser in /etc/cron.d"
  echo -e "*/4 * * * *\troot\t/usr/local/sbin/ntrk-parse" | sudo tee /etc/cron.d/ntrk-parse &> /dev/null

  echo
}


#######################################
# Create MariaDB Tables
# Globals:
#   DBUSER, DBPASSWORD, DBNAME
# Arguments:
#   None
# Returns:
#   None
#######################################
function create_tables() {
  echo "Creating Tables in MariaDB"

  #Analytics
  mysql --user="$DBUSER" --password="$DBPASSWORD" -D "$DBNAME" -e "CREATE TABLE IF NOT EXISTS analytics (id BIGINT UNSIGNED NOT NULL PRIMARY KEY AUTO_INCREMENT, log_time DATETIME, sys TINYTEXT, dns_request TINYTEXT, dns_result CHAR(1), issue TINYTEXT, ack BOOLEAN);"
  #dnslog
  mysql --user="$DBUSER" --password="$DBPASSWORD" -D "$DBNAME" -e "CREATE TABLE dnslog (id BIGINT UNSIGNED NOT NULL PRIMARY KEY AUTO_INCREMENT, log_time DATETIME, sys TINYTEXT, dns_request TINYTEXT, dns_result CHAR(1));"
  #users (not yet used)
  mysql --user="$DBUSER" --password="$DBPASSWORD" -D "$DBNAME" -e "CREATE TABLE users (id INT UNSIGNED NOT NULL PRIMARY KEY AUTO_INCREMENT, user TINYTEXT, pass TEXT, level CHAR(1));"
  #blocklist
  mysql --user="$DBUSER" --password="$DBPASSWORD" -D "$DBNAME" -e "CREATE TABLE blocklist (id BIGINT UNSIGNED NOT NULL PRIMARY KEY AUTO_INCREMENT, bl_source TINYTEXT, site TINYTEXT, site_status BOOLEAN, comment TEXT);"
  #weblog
  mysql --user="$DBUSER" --password="$DBPASSWORD" -D "$DBNAME" -e "CREATE TABLE weblog (id BIGINT UNSIGNED NOT NULL PRIMARY KEY AUTO_INCREMENT, log_time DATETIME, site TINYTEXT, http_method CHAR(4), uri_path TEXT, referrer TEXT, user_agent TEXT, remote_host TEXT);"

  echo "MariaDB setup complete"
  echo "========================================================="
  echo
  sleep 3s
}


#######################################
# Setup NoTrack
#   1. Initial setup of notrack.conf
#   2. Create cron jobs
#
# Globals:
#   INSTALL_LOCATION, IP_VERSION, NETWORK_DEVICE
# Arguments:
#   None
# Returns:
#   None
#
#######################################
function setup_notrack() {
  echo "Setting up NoTrack block list downloader"

  create_folder "/etc/notrack"
  create_file "/etc/notrack/notrack.conf"                  #Create Config file

  echo "Writing initial config"
  echo "IPVersion = $IP_VERSION" | sudo tee /etc/notrack/notrack.conf
  echo "NetDev = $NETWORK_DEVICE" | sudo tee -a /etc/notrack/notrack.conf

  delete_file "/etc/cron.daily/notrack"                    #Remove old symlinks
  delete_file "/etc/cron.hourly/ntrk-analytics"

  echo "Creating daily cron job in /etc/cron.daily/"
  sudo ln -s /usr/local/sbin/notrack /etc/cron.daily/notrack

  echo "Creating hourly cron job for ntrk-analytics in /etc/cron.hourly"
  sudo ln -s /usr/local/sbin/ntrk-analytics /etc/cron.hourly/ntrk-analytics

  echo
  echo "NoTrack configuration complete"
  echo "========================================================="
  echo
  sleep 3s
}


#FirewallD-----------------------------------------------------------
setup_firewalld() {
  #Configure FirewallD to Work With Dnsmasq
  echo "Creating Firewall Rules Using FirewallD"
  
  if [[ $(sudo firewall-cmd --query-service=dns) == "yes" ]]; then
    echo "Firewall rule DNS already exists! Skipping..."
  else
    echo "Firewall rule DNS has been added"
    sudo firewall-cmd --permanent --add-service=dns    #Add firewall rule for dns connections
  fi
    
  #Configure FirewallD to Work With Lighttpd
  if [[ $(sudo firewall-cmd --query-service=http) == "yes" ]]; then
    echo "Firewall rule HTTP already exists! Skipping..."
  else
    echo "Firewall rule HTTP has been added"
    sudo firewall-cmd --permanent --add-service=http    #Add firewall rule for http connections
  fi

  if [[ $(sudo firewall-cmd --query-service=https) == "yes" ]]; then
    echo "Firewall rule HTTPS already exists! Skipping..."
  else
    echo "Firewall rule HTTPS has been added"
    sudo firewall-cmd --permanent --add-service=https   #Add firewall rule for https connections
  fi
  
  echo "Reloading FirewallD..."
  sudo firewall-cmd --reload
  echo
  echo "FirewallD configuration complete"
  echo "========================================================="
  echo
}


#######################################
# Prompt for Install Location
# Globals:
#   INSTALL_LOCATION
# Arguments:
#   None
# Returns:
#   None
#######################################

prompt_installloc() {
  local homefolder="${HOME}"
  
  if [[ $homefolder == "/root" ]]; then      #Change root folder to users folder
    homefolder="$(getent passwd $SUDO_USER | grep /home | grep -v syslog | cut -d: -f6)"
    if [ $(wc -w <<< "$homefolder") -gt 1 ]; then   #Too many sudo users
      echo "Unable to estabilish which Home folder to install to"
      echo "Either run this installer without using sudo / root, or manually set the \$INSTALL_LOCATION variable"
      echo "\$INSTALL_LOCATION=\"/home/you/NoTrack\""
      exit 15
    fi
  fi
  
  menu "Select Install Folder" "Home $homefolder" "Opt /opt" "Cancel"
  
  case $? in
    1)
      INSTALL_LOCATION="$homefolder/notrack" 
    ;;
    2)
      INSTALL_LOCATION="/opt/notrack"
      SUDO_REQUIRED=true
    ;;
    3)
      error_exit "Aborting Install" 1
    ;;
  esac

  if [[ $INSTALL_LOCATION == "" ]]; then
    error_exit "Install folder not set" 15
  fi  
}



#######################################
# Prompt for network device
# Globals:
#   NETWORK_DEVICE
# Arguments:
#   None
# Returns:
#   None
#######################################
prompt_network_device() {
  local count_net_dev=0
  local device=""
  local -a device_list
  local menu_choice

  if [ ! -d /sys/class/net ]; then               #Check net devices folder exists
    echo "Error. Unable to find list of Network Devices"
    echo "Edit user customisable setting \$NetDev with the name of your Network Device"
    echo "e.g. \$NetDev=\"eth0\""
    exit 11
  fi

  for device in /sys/class/net/*; do             #Read list of net devices
    device="${device:15}"                        #Trim path off
    if [[ $device != "lo" ]]; then               #Exclude loopback
      device_list[$count_net_dev]="$device"
      ((count_net_dev++))
    fi
  done

  if [ $count_net_dev == 0 ]; then               #None found
    echo "Error. No Network Devices found"
    echo "Edit user customisable setting \$NetDev with the name of your Network Device"
    echo "e.g. \$NetDev=\"eth0\""
    exit 11

  elif [ $count_net_dev == 1 ]; then             #1 Device
    NETWORK_DEVICE=${device_list[0]}             #Simple, just set it
  elif [ $count_net_dev -gt 0 ]; then
    menu "Select Network Device" ${device_list[*]}
    menu_choice=$?
    NETWORK_DEVICE=${device_list[$((menu_choice-1))]}
  elif [ $count_net_dev -gt 9 ]; then            #9 or more use bash prompt
    clear
    echo "Network Devices detected: ${device_list[*]}"
    echo -n "Select Network Device to use for DNS queries: "
    read -r choice
    NETWORK_DEVICE=$choice
    echo    
  fi
  
  if [[ $NETWORK_DEVICE == "" ]]; then
    error_exit "Network Device not entered" 11
  fi  
}


#######################################
# Prompt for ip version
# Globals:
#   IP_VERSION
# Arguments:
#   None
# Returns:
#   None
#######################################
prompt_ip_version() {
  menu "Select IP Version being used" "IP Version 4 (default)" "IP Version 6" 
  case "$?" in
    1) IP_VERSION=$IP_V4 ;;
    2) IP_VERSION=$IP_V6 ;;
    3) error_exit "Aborting Install" 12
  esac
}


#######################################
# Prompt for DNS server
# Globals:
#   DNS_SERVER_1
#   DNS_SERVER_2
# Arguments:
#   $1 IP version
# Returns:
#   None
#######################################
prompt_dns_server() {
  menu "Choose DNS Server\nThe job of a DNS server is to translate human readable domain names (e.g. google.com) into an  IP address which your computer will understand (e.g. 109.144.113.88) \nBy default your router forwards DNS queries to your Internet Service Provider (ISP), however ISP DNS servers are not the best." "OpenDNS" "Google Public DNS" "DNS.Watch" "Verisign" "Comodo" "FreeDNS" "Yandex DNS" "Cloudflare" "Other" 
  
  case "$?" in
    1)                                           #OpenDNS
      if [[ $1 == "$IP_V6" ]]; then
        DNS_SERVER_1="2620:0:ccc::2"
        DNS_SERVER_2="2620:0:ccd::2"
      else
        DNS_SERVER_1="208.67.222.222" 
        DNS_SERVER_2="208.67.220.220"
      fi
    ;;
    2)                                           #Google
      if [[ $1 == "$IP_V6" ]]; then
        DNS_SERVER_1="2001:4860:4860::8888"
        DNS_SERVER_2="2001:4860:4860::8844"
      else
        DNS_SERVER_1="8.8.8.8"
        DNS_SERVER_2="8.8.4.4"
      fi
    ;;
    3)                                                     #DNSWatch
      if [[ $1 == "$IP_V6" ]]; then
        DNS_SERVER_1="2001:1608:10:25::1c04:b12f"
        DNS_SERVER_2="2001:1608:10:25::9249:d69b"
      else
        DNS_SERVER_1="84.200.69.80"
        DNS_SERVER_2="84.200.70.40"
      fi
    ;;
    4)                                                     #Verisign
      if [[ $1 == "$IP_V6" ]]; then
        DNS_SERVER_1="2620:74:1b::1:1"
        DNS_SERVER_2="2620:74:1c::2:2"
      else
        DNS_SERVER_1="64.6.64.6"
        DNS_SERVER_2="64.6.65.6"
      fi
    ;;
    5)                                                     #Comodo
      DNS_SERVER_1="8.26.56.26"
      DNS_SERVER_2="8.20.247.20"
    ;;
    6)                                                     #FreeDNS
      DNS_SERVER_1="37.235.1.174"
      DNS_SERVER_2="37.235.1.177"
    ;;
    7)                                                     #Yandex
      if [[ $1 == "$IP_V6" ]]; then
        DNS_SERVER_1="2a02:6b8::feed:bad"
        DNS_SERVER_2="2a02:6b8:0:1::feed:bad"
      else
        DNS_SERVER_1="77.88.8.88"
        DNS_SERVER_2="77.88.8.2"
      fi
    ;;
    8)
      if [[ $1 == "$IP_V6" ]]; then                        #Cloudflare
        DNS_SERVER_1="2606:4700:4700::1111"
        DNS_SERVER_2="2606:4700:4700::1001"
      else
        DNS_SERVER_1="1.1.1.1"
        DNS_SERVER_2="1.0.0.1"
      fi
    ;;
    9)                                                     #Other
      echo -en "DNS Server 1: "
      read -r DNS_SERVER_1
      echo -en "DNS Server 2: "
      read -r DNS_SERVER_2
    ;;
  esac
}


#######################################
# Get default internet gateway address
# Globals:
#   GATEWAY_ADDRESS
# Arguments:
#   None
# Returns:
#   None
#######################################
get_gateway_address() {
  GATEWAY_ADDRESS=$(ip route | grep default | awk '{print $3}')
}


#######################################
# Get current ip address
# Globals:
#   IP_ADDRESS
# Arguments:
#   $1 Ip version, IPv4 / IPv6
#   $2 Network device
# Returns:
#   None
#######################################
get_ip_address() {
  if [[ $1 == "$IP_V4" ]]; then
    echo "Reading IPv4 Address from $2"
    IP_ADDRESS=$(ip addr list "$2" |grep "inet " |cut -d' ' -f6|cut -d/ -f1)
    
  elif [[ $1 == "$IP_V6" ]]; then
    echo "Reading IPv6 Address from $2"
    IP_ADDRESS=$(ip addr list "$2" |grep "inet6 " |cut -d' ' -f6|cut -d/ -f1)    
  else
    error_exit "Unknown IP Version" 12
  fi
  
  if [[ $IP_ADDRESS == "" ]]; then
    error_exit "Unable to detect IP Address" 13
  fi
}


#######################################
# Get netmask address
# Globals:
#   NETMASK_ADDRESS
# Arguments:
#   $1 Network device
# Returns:
#   None
#######################################
get_netmask_address(){
  NETMASK_ADDRESS=$(ifconfig "$1" | sed -rn '2s/ .*:(.*)$/\1/p')
}


#######################################
# Get broadcast address
# Globals:
#   BROADCAST_ADDRESS
# Arguments:
#   $1 Network device
# Returns:
#   None
#######################################
get_broadcast_address(){
  BROADCAST_ADDRESS=$(ip addr list "$1" | grep "inet" | grep "brd" | cut -d " " -f8)
}


#######################################
# Get netmask address
# Globals:
#   NETWORK_START_ADDRESS
# Arguments:
#   $1 Ip address
#   $2 Netmask address
# Returns:
#   None
#######################################
get_network_start_address(){
  IFS=. read -r i1 i2 i3 i4 <<< "$1"
  IFS=. read -r m1 m2 m3 m4 <<< "$2"
  NETWORK_START_ADDRESS="$((i1 & m1)).$((i2 & m2)).$((i3 & m3)).$((i4 & m4))"
}


#######################################
# Restore dhcpcd config files
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
restore_dhcpcd_config() {
  if [ -e "$DHCPCD_CONF_OLD_PATH" ]; then
    echo "Restoring dhcpcd config files"
    copy_file $DHCPCD_CONF_OLD_PATH $DHCPCD_CONF_PATH
  fi
  echo
}


#######################################
# Backup dhcpcd config files
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
backup_dhcpcd_config() {
  echo "Backing up dhcpcd config files"
  
  echo "Copying $DHCPCD_CONF_PATH to $DHCPCD_CONF_OLD_PATH"
  if [ -e "$DHCPCD_CONF_PATH" ]; then
    copy_file $DHCPCD_CONF_PATH $DHCPCD_CONF_OLD_PATH
  fi
  echo
}


#######################################
# Restore network interfaces config files
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
restore_network_interfaces_config() {
  if [ -e "$NETWORK_INTERFACES_OLD_PATH" ]; then
    echo "Restoring network interfaces config files"
  
    echo "Copying $NETWORK_INTERFACES_OLD_PATH to $NETWORK_INTERFACES_PATH"
    copy_file $NETWORK_INTERFACES_OLD_PATH $NETWORK_INTERFACES_PATH
  fi
  echo
}


#######################################
# Backup network interfaces config files
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
backup_network_interfaces_config() {
  echo "Backing up network interfaces config files"
  
  echo "Copying $NETWORK_INTERFACES_PATH to $NETWORK_INTERFACES_OLD_PATH"
  if [ -e "$NETWORK_INTERFACES_PATH" ]; then
    copy_file $NETWORK_INTERFACES_PATH $NETWORK_INTERFACES_OLD_PATH
  fi
  echo
}


#######################################
# Set static ip using dhcpcd.conf
# Globals:
#   NETWORK_DEVICE
#   IP_ADDRESS
#   GATEWAY_ADDRESS
#   DNS_SERVER_1
# Arguments:
#   None
# Returns:
#   None
#######################################
set_static_ip_dhcpcd(){
  sudo sed -i -e "\$a\ " $DHCPCD_CONF_PATH
  sudo sed -i -e "\$a#Static Ip Address" $DHCPCD_CONF_PATH
  sudo sed -i -e "\$ainterface $NETWORK_DEVICE" $DHCPCD_CONF_PATH
  if [[ $IP_VERSION == "$IP_V4" ]]; then
    sudo sed -i -e "\$astatic ip_address=$IP_ADDRESS/24" $DHCPCD_CONF_PATH
  else
    sudo sed -i -e "\$astatic ip_address=$IP_ADDRESS/64" $DHCPCD_CONF_PATH
  fi
  sudo sed -i -e "\$astatic routers="$GATEWAY_ADDRESS $DHCPCD_CONF_PATH
  sudo sed -i -e "\$astatic domain_name_servers=$DNS_SERVER_1 $DNS_SERVER_2" $DHCPCD_CONF_PATH
}


#######################################
# Set static ip using /etc/network/interfaces
# Globals:
#   NETWORK_DEVICE
#   IP_ADDRESS
#   GATEWAY_ADDRESS
#   NETMASK_ADDRESS
#   NETWORK_START_ADDRESS
#   BROADCAST_ADDRESS
#   DNS_SERVER_1
#   DNS_SERVER_2
# Arguments:
#   None
# Returns:
#   None
#######################################
set_static_ip_network_interfaces(){
  sudo sed -i "s/iface $NETWORK_DEVICE inet dhcp/iface $NETWORK_DEVICE inet static/" $NETWORK_INTERFACES_PATH
  sudo sed -i -e '/iface '"$NETWORK_DEVICE"' inet static/a \\tdns-nameservers '"$DNS_SERVER_1 $DNS_SERVER_2" $NETWORK_INTERFACES_PATH
  sudo sed -i -e '/iface '"$NETWORK_DEVICE"' inet static/a \\tgateway '"$GATEWAY_ADDRESS" $NETWORK_INTERFACES_PATH
  sudo sed -i -e '/iface '"$NETWORK_DEVICE"' inet static/a \\tbroadcast '"$BROADCAST_ADDRESS" $NETWORK_INTERFACES_PATH
  sudo sed -i -e '/iface '"$NETWORK_DEVICE"' inet static/a \\tnetmask '"$NETMASK_ADDRESS" $NETWORK_INTERFACES_PATH
  sudo sed -i -e '/iface '"$NETWORK_DEVICE"' inet static/a \\tnetwork '"$NETWORK_START_ADDRESS" $NETWORK_INTERFACES_PATH
  sudo sed -i -e '/iface '"$NETWORK_DEVICE"' inet static/a \\taddress '"$IP_ADDRESS" $NETWORK_INTERFACES_PATH
}


#######################################
# Gather parameters required for setting static ip address
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
get_static_ip_address_info(){
  prompt_ip_version

  if [[ $IP_VERSION == "$IP_V6" ]]; then
    error_exit "Only IPv4 supported for now" 12
    # TODO: Add support for setting static IPv6 address in /etc/network/interfaces
  fi

  prompt_network_device
  prompt_dns_server "$IP_VERSION"
  get_ip_address "$IP_VERSION" "$NETWORK_DEVICE"
  get_broadcast_address "$NETWORK_DEVICE"
  get_netmask_address "$NETWORK_DEVICE"
  get_network_start_address "$IP_ADDRESS" "$NETMASK_ADDRESS"
  get_gateway_address
}


#######################################
# Prompt for ip address
# Globals:
#   IP_ADDRESS
# Arguments:
#   None
# Returns:
#   None
#######################################
prompt_ip_address(){
  clear
  echo "Your current ip address is [$IP_ADDRESS]"
  echo
  read -p "Enter ip address: " -i $IP_ADDRESS -e IP_ADDRESS
}


#######################################
# Promt for gateway address
# Globals:
#   GATEWAY_ADDRESS
# Arguments:
#   None
# Returns:
#   None
#######################################
prompt_gateway_address(){
  clear
  echo "Your current internet gateway address is [$GATEWAY_ADDRESS]"
  echo "This is usually the address of your router"
  echo
  read -p "Enter internet gateway address: " -i $GATEWAY_ADDRESS -e GATEWAY_ADDRESS
}


#######################################
# Makes bakup of ip config depending on which dhcpcd
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
backup_static_ip_address_config(){
  if [[ -n $(which dhcpcd) ]]; then
    restore_dhcpcd_config
    backup_dhcpcd_config
  else
    restore_network_interfaces_config
    backup_network_interfaces_config
  fi
}


#######################################
# Sets static ip depending on which dhcpcd
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
set_static_ip_address(){
  if [[ -z $(which dhcpcd) ]]; then
    set_static_ip_network_interfaces
  else
    set_static_ip_dhcpcd
  fi
}


#######################################
# Promt for new/existing static ip address
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
prompt_setup_static_ip_address(){
  menu "NoTrack is a server and requires a static ip address to function properly" "Set a static ip address" "System has static ip address" "Abort install"

  case "$?" in
    1)
      if [[ -z $(which dhcpcd) ]]; then
        if [[ -n $(dpkg -l | grep -Ei "(kde|gnome|lxde|xfce|mint|unity|fluxbox|openbox)" | grep -v library) ]]; then
          clear
          echo "Your system appears to have a GUI desktop"
          echo
          echo "Use the connection editor to set a static ip address, then run this installer again"
          echo
          exit
        fi
      fi

      SETUP_STATIC_IP_ADDRESS=true
    ;;
    2)
      echo "System has static ip address"
    ;;
    3)
      error_exit "Aborting install" 1
    ;;
  esac
}



#######################################
# Welcome Screen
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
function show_welcome() {
  echo "Welcome to NoTrack v$VERSION"
  echo
  echo "This installer will transform your system into a network-wide Tracker Blocker"
  echo "Install Guides: https://youtu.be/MHsrdGT5DzE"
  echo "                https://github.com/quidsup/notrack/wiki"
  echo
  echo
  echo "Installation of MariaDB might ask you for a root password"
  echo "If it does, make a note of it, as you will need it later during the install of NoTrack"
  echo
  echo "Press any key to continue..."
  read -rn1
}

#######################################
# Finish Screen
# Globals:
#   INSTALL_LOCATION, REBOOT_REQUIRED, hostname
# Arguments:
#   None
# Returns:
#   None
#######################################
function show_finish() {
  echo "========================================================="
  echo
  echo -e "NoTrack Install Complete :-)"
  echo "Access the admin console at: http://$(hostname)/admin"
  echo
  echo "Post Install Checklist:"
  echo -e "\t\u2022 Secure MariaDB Installation"
  echo -e "\t    Run: /usr/bin/mysql_secure_installation"
  echo
  echo -e "\t\u2022 Create HTTPS Certificate"
  echo -e "\t    bash $INSTALL_LOCATION/scripts/create-ssl-cert.sh"
  echo
  echo -e "\t\u2022 Enable DHCP"
  echo -e "\t    http://$(hostname)/dhcp"
  echo
  echo
  echo "========================================================="
  echo
  
  if [[ $REBOOT_REQUIRED == true ]]; then
    echo "System reboot is required"
    echo
    echo "Press any key to reboot"
    read -rn1
    sudo reboot
  fi
}


#######################################
# Main
#######################################
if [[ $(command -v sudo) == "" ]]; then          #Is sudo available?
  error_exit "NoTrack requires Sudo to be installed for Admin functionality" "10"
fi

show_welcome

prompt_setup_static_ip_address

if [[ "$SETUP_STATIC_IP_ADDRESS" == true ]]; then
  # Get info required to set static ip address
  get_static_ip_address_info
  prompt_ip_address
  prompt_gateway_address

  # Setting static ip requires reboot
  REBOOT_REQUIRED=true
fi

if [[ $INSTALL_LOCATION == "" ]]; then
  prompt_installloc
fi

if [[ $NETWORK_DEVICE == "" ]]; then
  prompt_network_device
fi

if [[ $IP_VERSION == "" ]]; then
  prompt_ip_version
fi

if [[ $IP_ADDRESS == "" ]]; then
  get_ip_address "$IP_VERSION" "$NETWORK_DEVICE"
fi

if [[ $DNS_SERVER_1 == "" ]]; then
  prompt_dns_server $IP_VERSION
fi

get_hostname

clear
echo "Installing to: $INSTALL_LOCATION"          #Final report before Installing
echo "Network Device set to: $NETWORK_DEVICE"
echo "IP version set to: $IP_VERSION"
echo "IP address: $IP_ADDRESS"
echo "Hostname: $hostname"
echo "Primary DNS server set to: $DNS_SERVER_1"
echo "Secondary DNS server set to: $DNS_SERVER_2"
echo

seconds=$((8))
while [ $seconds -gt 0 ]; do
   echo -ne "$seconds\033[0K\r"
   sleep 1
   : $((seconds--))
done

if [[ "$SETUP_STATIC_IP_ADDRESS" == true ]]; then
  backup_static_ip_address_config
  set_static_ip_address
fi

install_packages                                 #Install Apps with the appropriate package manager

backup_configs                                   #Backup old config files

if [ "$(command -v git)" ]; then                 #Utilise Git if its installed
  download_with_git
else
  download_with_wget                             #Git not installed, fallback to wget
fi

copy_scripts                                     #Copy NoTrack script files
setup_dnsmasq
setup_lighttpd
setup_mariadb
create_tables
setup_notrack

if [ "$(command -v firewall-cmd)" ]; then        #Check FirewallD exists
  setup_firewalld
fi

service_restart lighttpd

if [ ! -e "/usr/local/sbin/notrack" ]; then
  error_exit "Script files missing" "1"
fi

echo "========================================================="
echo "Downloading and configuring blocklists"
echo
sudo /usr/local/sbin/notrack -f

show_finish
 
