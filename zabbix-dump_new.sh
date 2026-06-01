#!/usr/bin/env bash
#
# NAME
#     zabbix-dump - Configuration Backup for Zabbix' MySQL or PostgreSQL data
#
# SYNOPSIS
#     Configuration backup script for Zabbix 1.x to 7.x on Ubuntu.
#     By default it does a full backup of all configuration tables but only a
#     schema backup of large data tables. Use -F to back up ALL tables with data.
#
#     For a consistent backup the script stops the zabbix-server service before
#     dumping and restarts it afterwards (even if the backup fails).
#
#     The script is based on a script by Ricardo Santos
#     (http://zabbixzone.com/zabbix/backuping-only-the-zabbix-configuration/)
#
# CONTRIBUTORS
#      - Ricardo Santos
#      - Jens Berthold (maxhq)
#      - Oleksiy Zagorskyi (zalex)
#      - Petr Jendrejovsky
#      - Jonathan Bayer
#      - Andreas Niedermann (dre-)
#      - Mișu Moldovan (dumol)
#      - Daniel Schneller (dschneller)
#      - Ruslan Ohitin (ruslan-ohitin)
#      - Jonathan Wright (neonardo1)
#      - msjmeyer
#      - Sergey Galkin (sergeygalkin)
#      - Greg Cockburn (gergnz)
#      - yangqi
#      - Johannes Petz (PetzJohannes)
#      - Wesley Schaft (wschaft)
#      - Tiago Cruz (tiago-cruz-movile)
#      - Mario Trangoni (mjtrangoni)
#      - ironbishop
#      - Stephan (stephankn)
#      - Andrew P. (diffway)
#
# AUTHOR
#     Jens Berthold (maxhq), 2020
#
# LICENSE
#     This script is released under the MIT License (see LICENSE.txt)

# Some notes/todo
#
# I do not like to much to have the HANDLE_UNKWOWN and the database stored in two different files divided
# in data and schema. (i've to study more about how to recover from disaster with data splitted,
# maybe foreign key disablig i enough.)
#
# Furthermore i do not like the approach to split the variables and get a common state
# and passing arguments via GLOBAL variables, i do not like it at all, maybe i will review the structure.
#
# TODO Review the use of 'log' and 'quiet = no' around the code

VERSION=0.11.0

# Absolute path to this script (BASH_SOURCE[0], not [*] which joins the stack).
SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"

# =============================================================================
#  DEFAULTS
#
#  DO NOT EDIT THESE VALUES!
#  Use command line parameters or a config file to specify options.
# =============================================================================
DEFAULT_STAGING_DIR="/opt/zab-bck"   # fixed staging dir unless -o overrides it
DBTYPE="mysql"
DEFAULT_DBHOST="127.0.0.1"
DEFAULT_DBSCHEMA="public"
DEFAULT_DBNAME="zabbix"
DEFAULT_DBUSER="zabbix"
EFAULT_DBPASS=""
COMPRESSION="gz"
QUIET="no"
REVERSELOOKUP="yes" # TODO check if functionality realli needed or in case delete
COLUMN_NAMES="no"
CUSTOM_FORMAT="no"
FULL_BACKUP="no"
GENERATIONSTOKEEP=0
ZBX_CONFIG="/etc/zabbix/zabbix_server.conf"
READ_ZBX_CONFIG="yes"
HANDLE_UNKNOWN="fail"
BANNER="no"

# Runtime state (populated as the script runs)
DUMPDIR=""                  # resolved output dir (staging unless -o)
DUMPDIR_OVERRIDDEN="no"
ERRORLOG=""
ZBX_SERVICE=""              # name of the detected zabbix-server unit, if any
ZBX_WAS_RUNNING="no"        # whether we stopped it and must restart it

# Config directories captured by the single filesystem-config archive
CFG_DIRS=(
    /etc/zabbix /usr/share/zabbix usr/share/zabbix*
    /etc/apache2 /etc/httpd /etc/nginx /etc/php
    /etc/mysql /etc/my.cnf.d /etc/postgresql
    /etc/snmp /usr/share/snmp/mibs /var/lib/zabbix/mibs
)

# =============================================================================
#  SMALL HELPERS
# =============================================================================
log()  { [ "$QUIET" == "no" ] && echo "$@"; return 0; }
err()  { echo "$@" >&2; }
die()  { err "ERROR: $*"; cleanup; exit 1; }

# TRUE if argument 1 is part of the given array (remaining arguments)
elementIn() {
    local e
    for e in "${@:2}"; do [[ "$e" == "$1" ]] && return 0; done
    return 1
}

check_binary() {
    if ! which "$1" >/dev/null 2>&1; then
        err "Executable '$1' not found."
        case $1 in
            mysqldump) err "(on Ubuntu try \"apt-get install mysql-client\")" ;;
            pg_dump)   err "(on Ubuntu try \"apt-get install postgresql-client\")" ;;
        esac
        exit 1
    fi
}

# Single cleanup path: remove temp files and restart zabbix-server if we stopped it.
cleanup() {
    [ -n "$ERRORLOG" ] && rm -f "$ERRORLOG"
    if [ "$DBTYPE" == "psql" ] && [ -n "$PGPASSFILE" ]; then
        rm -f "$PGPASSFILE"
    fi
    restart_zabbix_server
}

# =============================================================================
#  USAGE / VERSION
# =============================================================================
show_version() { echo "zabbix-dump version $VERSION"; exit 0; }

show_help() {
    cat <<EOF
USAGE
    $SCRIPT_NAME [options]

    Runs on Ubuntu only. Stops the zabbix-server service for a consistent
    backup and restarts it afterwards. Backups are staged under
    $DEFAULT_STAGING_DIR (which must NOT already exist) unless -o is given.

OPTIONS
    -t DATABASE_TYPE   Database type (mysql or psql). Default: $DBTYPE
    -H DBHOST          Hostname/IP of database server. Default: $DEFAULT_DBHOST
    -P DBPORT          DBMS port. Default: mysql 3306, psql 5432
    -s DBSOCKET        Path to DBMS socket file (alternative to host/port).
    -S SCHEMA          Database schema (PostgreSQL only). Default: $DEFAULT_DBSCHEMA
    -d DATABASE        Name of Zabbix database. Default: $DEFAULT_DBNAME
    -u DBUSER          DBMS user. Default: $DEFAULT_DBUSER
    -p DBPASSWORD      DBMS password (specify "-" for a prompt). Default: none
    -o DIR             Output dir. Overrides the $DEFAULT_STAGING_DIR staging dir
                       and lifts the "must not exist" restriction.
    -z ZABBIX_CONFIG   Read DB host/credentials from a Zabbix config file.
                       Default: $ZBX_CONFIG
    -Z                 Do not read the Zabbix server configuration.
    -c MYSQL_CONFIG    MySQL only: read DB host/credentials from a MySQL config
                       file. The first "database" option in the file is used.
    -r NUM             Rotate backups, keeping up to NUM generations. A
                       generation is one run's whole set (db dump + config
                       archive + manifest), matched by its shared timestamp.
                       Default: keep all backups
    -F                 Full backup: dump ALL tables WITH data, including large
                       data tables (history, trends, events, ...). Can be huge.
    -x                 Compress with XZ instead of GZip (smaller, slower).
    -0                 Do not compress the sql dump.
    -n                 Skip reverse lookup of the host IP address.
    -N                 Add quoted column names in INSERT INTO .. VALUES ..
    -C                 Custom dump format (PostgreSQL only).
    -f                 Force backup of unknown tables (full data backup).
    -i                 Ignore unknown tables (exclude them from the backup).
    -B                 Print a detailed banner (planned command, paths, etc.).
    -q                 Quiet mode: errors only (for batch/crontab use).
    -h, --help         Show this help.

EXAMPLES
    # back up local MySQL Zabbix DB into $DEFAULT_STAGING_DIR (reads $ZBX_CONFIG)
    $SCRIPT_NAME

    # ...same for PostgreSQL
    $SCRIPT_NAME -t psql

    # full backup (all tables with data)
    $SCRIPT_NAME -F

    # write to a custom dir instead of the staging dir
    $SCRIPT_NAME -o /tmp/zbxbackup

    # do NOT read $ZBX_CONFIG; ask for the password
    $SCRIPT_NAME -Z -p -

    # read DB options from a MySQL config file, override database name
    $SCRIPT_NAME -c /etc/mysql/mysql.cnf -d zabbixdb
EOF
    exit 1
}

# =============================================================================
#  ENVIRONMENT CHECKS
# =============================================================================

# Block on anything that is not Ubuntu.
require_ubuntu() {
    local id=""
    if [ -r /etc/os-release ]; then
        id="$(. /etc/os-release 2>/dev/null; echo "$ID")"
    fi
    if [ "$id" != "ubuntu" ]; then
        err "ERROR: This script is intended for Ubuntu only."
        err "Detected distribution ID: '${id:-unknown}' (see /etc/os-release)."
        exit 1
    fi
}

# =============================================================================
#  ARGUMENT PARSING + CONFIG RESOLUTION
# =============================================================================
parse_args() {
    DB_GIVEN=0
    while getopts ":Bc:S:d:H:o:p:P:r:s:t:u:z:0nNCqxZfiFv" opt; do
        case $opt in
            B)  BANNER="yes" ;;
            t)  DBTYPE="$OPTARG" ;;
            H)  ODBHOST="$OPTARG" ;;
            s)  ODBSOCKET="$OPTARG" ;;
            S)  ODBSCHEMA="$OPTARG" ;;
            d)  ODBNAME="$OPTARG"; DB_GIVEN=1 ;;
            u)  ODBUSER="$OPTARG" ;;
            P)  ODBPORT="$OPTARG" ;;
            p)  ODBPASS="$OPTARG" ;;
            c)  MYSQL_CONFIG="$OPTARG" ;;
            o)  ODUMPDIR="$OPTARG"; DUMPDIR_OVERRIDDEN="yes" ;;
            z)  ZBX_CONFIG="$OPTARG" ;;
            Z)  READ_ZBX_CONFIG="no" ;;
            r)  GENERATIONSTOKEEP=$(printf '%.0f' "$OPTARG") ;;
            F)  FULL_BACKUP="yes" ;;
            x)  COMPRESSION="xz" ;;
            0)  COMPRESSION="" ;;
            n)  REVERSELOOKUP="no" ;;
            N)  COLUMN_NAMES="yes" ;;
            C)  CUSTOM_FORMAT="yes" ;;
            f)  HANDLE_UNKNOWN="backup" ;;
            i)  HANDLE_UNKNOWN="ignore" ;;
            q)  QUIET="yes" ;;
            v)  show_version ;;
            \?) err "Invalid option: -$OPTARG"; exit 1 ;;
            :)  err "Option -$OPTARG requires an argument"; exit 1 ;;
        esac
    done
}

# Read DB connection settings from zabbix_server.conf (using awk, not sourcing,
# to avoid executing shell metacharacters in the file).
read_zabbix_config() {
    log "Reading database options from ${ZBX_CONFIG}..."

    DBHOST="$(/usr/bin/awk -F'=' '/^DBHost/{ print $2 }'   "${ZBX_CONFIG}")"
    DBPORT="$(/usr/bin/awk -F'=' '/^DBPort/{ print $2 }'   "${ZBX_CONFIG}")"
    DBNAME="$(/usr/bin/awk -F'=' '/^DBName/{ print $2 }'   "${ZBX_CONFIG}")"
    DBSCHEMA="$(/usr/bin/awk -F'=' '/^DBSchema/{ print $2 }' "${ZBX_CONFIG}")"
    DBUSER="$(/usr/bin/awk -F'=' '/^DBUser/{ print $2 }'   "${ZBX_CONFIG}")"
    DBPASS="$(/usr/bin/grep '^DBPassword=' "${ZBX_CONFIG}" | /usr/bin/cut -d= -f2-)"

    [ -z "${DBHOST+x}" ] && DBHOST="localhost"

    # Zabbix treats DBHost specially:
    #   mysql + "localhost"   -> use socket
    #   psql  + ""            -> use socket
    if [[ ( "$DBTYPE" == "mysql" && "$DBHOST" == "localhost" ) || \
          ( "$DBTYPE" == "psql"  && "$DBHOST" == "" ) ]]; then
        local searchstr="" sock=""
        [ "$DBTYPE" == "mysql" ] && searchstr="mysqld.sock"
        [ "$DBTYPE" == "psql"  ] && searchstr="postgres"
        sock=$(netstat -lxn | grep -m1 "$searchstr" | sed -r 's/^.*\s+([^ ]+)$/\1/')
        if [[ -n "$sock" && -S "$sock" ]]; then DBSOCKET="$sock"; DBHOST=""; fi
    else
        DBSOCKET="$(/usr/bin/awk -F'=' '/^DBSocket/{ print $2 }' "${ZBX_CONFIG}")"
    fi
}

resolve_config() {
    [ -n "$MYSQL_CONFIG" ] && READ_ZBX_CONFIG="no"

    if [[ "$READ_ZBX_CONFIG" == "yes" && -f "$ZBX_CONFIG" && -r "$ZBX_CONFIG" ]]; then
        read_zabbix_config
    elif [ -z "$MYSQL_CONFIG" ]; then
        # No Zabbix config and no MySQL config file: fall back to defaults.
        DBHOST="$DEFAULT_DBHOST"
        DBNAME="$DEFAULT_DBNAME"
        DBUSER="$DEFAULT_DBUSER"
        DBPASS="$DEFAULT_DBPASS"
    fi

    # Defaults that always apply
    [[ -z "$DBPORT" && "$DBTYPE" == "mysql" ]] && DBPORT="3306"
    [[ -z "$DBPORT" && "$DBTYPE" == "psql"  ]] && DBPORT="5432"
    [ -z "$DBSCHEMA" ] && DBSCHEMA="$DEFAULT_DBSCHEMA"

    # Command-line options override everything resolved above
    [ -n "$ODBHOST" ]   && DBHOST="$ODBHOST"
    [ -n "$ODBPORT" ]   && DBPORT="$ODBPORT"
    [ -n "$ODBSOCKET" ] && { DBSOCKET="$ODBSOCKET"; DBHOST=""; }
    [ -n "$ODBSCHEMA" ] && DBSCHEMA="$ODBSCHEMA"
    [ -n "$ODBNAME" ]   && DBNAME="$ODBNAME"
    [ -n "$ODBUSER" ]   && DBUSER="$ODBUSER"
    [ -n "$ODBPASS" ]   && DBPASS="$ODBPASS"

    # Password prompt
    if [ "$DBPASS" = "-" ]; then
        read -r -s -p "Enter database password for user '$DBUSER' (input will be hidden): " DBPASS
        echo ""
    fi

    # MySQL config file: validate and (maybe) pull the database name from it
    if [ -n "$MYSQL_CONFIG" ]; then
        [ -r "$MYSQL_CONFIG" ] || die "Cannot read configuration file $MYSQL_CONFIG"
        if [ $DB_GIVEN -eq 0 ]; then
            DBNAME=$(grep -m1 ^database= "$MYSQL_CONFIG" | cut -d= -f2)
        fi
    fi

    [ -z "$DBNAME" ] && die "Please specify a database name (option -d)"
}


# Resolve and prepare the staging/output directory.
#   - default $DEFAULT_STAGING_DIR, which must NOT already exist
#   - -o DIR overrides it and lifts the "must not exist" restriction
prepare_dumpdir() {
    if [ "$DUMPDIR_OVERRIDDEN" == "yes" ]; then
        DUMPDIR="$ODUMPDIR"
        [ "$DUMPDIR" = "-" ] && { QUIET="yes"; return 0; }   # stdout mode
        mkdir -p "$DUMPDIR" || die "Could not create output dir $DUMPDIR"
    else
        DUMPDIR="$DEFAULT_STAGING_DIR"
        if [ -e "$DUMPDIR" ]; then
            die "Staging directory $DUMPDIR already exists. Remove it or use -o DIR."
        fi
        mkdir -p "$DUMPDIR" || die "Could not create staging dir $DUMPDIR (need root?)"
    fi
}

# =============================================================================
#  ZABBIX SERVICE CONTROL
# =============================================================================

# TODO check if use is.running is better to check the state, 
# seems that there is also a check in stop_zabbix_server() maybe cand be deleted.

# Detect the zabbix-server systemd unit (name varies a little across packages).
detect_zabbix_service() {
    command -v systemctl >/dev/null 2>&1 || return 0
    local candidate
    for candidate in zabbix-server zabbix_server; do
        if systemctl list-unit-files "${candidate}.service" >/dev/null 2>&1 \
           && systemctl cat "${candidate}.service" >/dev/null 2>&1; then
            ZBX_SERVICE="${candidate}.service"
            return 0
        fi
    done
}

stop_zabbix_server() {
    [ -n "$ZBX_SERVICE" ] || { log "No zabbix-server service found - skipping stop."; return 0; }
    if systemctl is-active --quiet "$ZBX_SERVICE"; then
        log "Stopping $ZBX_SERVICE for a consistent backup..."
        if systemctl stop "$ZBX_SERVICE"; then
            ZBX_WAS_RUNNING="yes"
        else
            die "Could not stop $ZBX_SERVICE"
        fi
    else
        log "$ZBX_SERVICE is not running - nothing to stop."
    fi
}

# Restart only if we were the ones who stopped it. Safe to call multiple times.
restart_zabbix_server() {
    if [ "$ZBX_WAS_RUNNING" == "yes" ]; then
        log "Restarting $ZBX_SERVICE..."
        systemctl start "$ZBX_SERVICE" || err "WARNING: could not restart $ZBX_SERVICE"
        ZBX_WAS_RUNNING="no"   # guard against double restart from the trap
    fi
}

# =============================================================================
#  DB OPTION ASSEMBLY
# =============================================================================

# TODO the function can be improved deduplicationg the same variables. 

build_db_opts() {
    DB_OPTS=()
    case $DBTYPE in
        mysql)
            [ -n "$MYSQL_CONFIG" ] && DB_OPTS+=(--defaults-extra-file="$MYSQL_CONFIG")
            [ -n "$DBSOCKET" ] && DB_OPTS+=(-S "$DBSOCKET")
            [ -n "$DBHOST" ]   && DB_OPTS+=(-h "$DBHOST")
            [ -n "$DBUSER" ]   && DB_OPTS+=(-u "$DBUSER")
            [ -n "$DBPASS" ]   && DB_OPTS+=(-p"$DBPASS")
            DB_OPTS+=(-P"$DBPORT")

            # Dividing options from mysql and mysqldump executable

            DB_OPTS_BATCH=("${DB_OPTS[@]}" --batch --silent)
            [ -n "$DBNAME" ] && DB_OPTS_BATCH+=(-D "$DBNAME")
	    
            # TODO check what do following lines and also is if is better to prepare the 
	    # db dump options here.
            [ "$COLUMN_NAMES" == "yes" ] && DB_OPTS+=(--complete-insert --quote-names)
            ;;
        psql)
            [ -n "$DBSOCKET" ] && DB_OPTS+=(-h "$DBSOCKET")
            [ -n "$DBHOST" ]   && DB_OPTS+=(-h "$DBHOST")
            [ -n "$DBUSER" ]   && DB_OPTS+=(-U "$DBUSER")
            DB_OPTS+=(-p"$DBPORT")
            if [ -n "$DBPASS" ]; then
                PGPASSFILE=$(mktemp -u); export PGPASSFILE
                echo "$DBHOST:$DBPORT:$DBNAME:$DBUSER:$DBPASS" > "$PGPASSFILE"
                chmod 600 "$PGPASSFILE"
            fi
            DB_OPTS_BATCH=("${DB_OPTS[@]}" -AtwX)
            [ -n "$DBNAME" ] && DB_OPTS_BATCH+=(-d "$DBNAME")
            [ "$CUSTOM_FORMAT" == "yes" ] && DB_OPTS+=(--format=custom)
            [ "$CUSTOM_FORMAT" == "no" ]  && DB_OPTS+=(--format=plain)
            [ "$COLUMN_NAMES" == "yes" ]  && DB_OPTS+=(--inserts --column-inserts --quote-all-identifiers)
            ;;
    esac
}

# Determine a friendly host name for the backup file names.
resolve_hostname() {
    if [[ -z "$DBHOST" || "$DBHOST" == "localhost" || "$DBHOST" == "127.0.0.1" ]]; then
        DBHOSTNAME="$(uname -n)"
        return 0
    fi
    DBHOSTNAME="$DBHOST"
    if [[ "$REVERSELOOKUP" == "yes" ]] && command -v dig >/dev/null 2>&1; then
        local newHostname
        newHostname=$(dig +noall +answer -x "${DBHOST}" | head -n1 | sed -r 's/((\S+)\s+)+([^\.]+)\..*/\3/')
        [ -n "$newHostname" ] && DBHOSTNAME="$newHostname"
    fi
}

# =============================================================================
#  TABLE LIST
# =============================================================================

# Read the table list from the __DATA__ section at the end of this file.
# SCHEMAONLY marks large monitoring-data tables (schema backed up, data skipped),
# unless -F (full backup) was given, in which case nothing is schema-only.
load_table_list() {
    SCHEMAONLY_TABLES=()
    KNOWN_TABLES=()
    local line table
    while read -r line; do
        table=$(echo "$line" | cut -d" " -f1)
        if echo "$line" | cut -d" " -f5 | grep -qi "SCHEMAONLY"; then # TODO Check if it is better to make a check for -F flag here
            SCHEMAONLY_TABLES+=("$table")
        fi
        KNOWN_TABLES+=("$table")
    done < <(sed '0,/^__DATA__$/d' "$SCRIPT_PATH" | tr -s " ")

    [ ${#SCHEMAONLY_TABLES[@]} -lt 5 ] && \
        die "The number of large data tables configured in this script is less than 5."

    [ "$FULL_BACKUP" == "yes" ] && SCHEMAONLY_TABLES=()
}

# Fetch the actual table list from the live database.
fetch_db_tables() {
    log "Fetching list of existing tables..."
    case $DBTYPE in
        mysql)
            DB_TABLES=$(mysql "${DB_OPTS_BATCH[@]}" -e \
                "SELECT table_name FROM information_schema.tables WHERE table_schema = '$DBNAME'" 2>"$ERRORLOG")
            ;;
        psql)
            DB_TABLES=$(psql "${DB_OPTS_BATCH[@]}" -c \
                "SELECT table_name FROM information_schema.tables WHERE table_schema='$DBSCHEMA' AND table_catalog='$DBNAME' AND table_type='BASE TABLE'" 2>"$ERRORLOG")
            ;;
    esac
    if [ $? -ne 0 ]; then
        err "ERROR while trying to access database:"
        cat "$ERRORLOG" >&2
        cleanup; exit 1
    fi
    DB_TABLES=$(echo "$DB_TABLES" | sort)
}

# Compare DB tables against the known list and react per HANDLE_UNKNOWN.
# print a warning depending on $HANDLE_UNKOWN to inform about the behaviour 
check_unknown_tables() {
    UNKNOWN_TABLES=()
    local table
    while read -r table; do
        elementIn "$table" "${KNOWN_TABLES[@]}" || UNKNOWN_TABLES+=("$table");
    done <<< "$DB_TABLES"

    [ ${#UNKNOWN_TABLES[@]} -eq 0 ] && return 0

    if [[ "$QUIET" == "no" || "$HANDLE_UNKNOWN" == "fail" ]]; then
        echo ""
        [ "$HANDLE_UNKNOWN" == "fail" ] && echo "ERROR"
        echo "Unknown tables found in database:"
        local tab; for tab in "${UNKNOWN_TABLES[@]}"; do echo " - $tab"; done
        [ "$HANDLE_UNKNOWN" == "backup" ] && echo "They will be included (full data backup) as -f was specified"
        [ "$HANDLE_UNKNOWN" == "ignore" ] && echo "They will be ignored as -i was specified"
        [ "$HANDLE_UNKNOWN" == "fail"  ] && echo "To include them (full data backup) specify -f, to ignore them use -i"
        echo ""
    fi
    [ "$HANDLE_UNKNOWN" == "fail" ] && { cleanup; exit 1; }
    return 0
}

# Build the "_db-mysql-X.Y.Z" version suffix from the dbversion table.
# and save in $VERSION_SUFFIX
resolve_db_version() {
    VERSION_SUFFIX=""
    local db_ver
    case $DBTYPE in
        mysql) db_ver=$(mysql "${DB_OPTS_BATCH[@]}" -N -e "select optional from dbversion;" 2>/dev/null) ;;
        psql)  db_ver=$(psql  "${DB_OPTS_BATCH[@]}" -c "select optional from dbversion;" 2>/dev/null) ;;
    esac
    [ $? -eq 0 ] || return 0
    local re='(.*)([0-9]{2})([0-9]{4})'   # e.g. 02030015 -> 2.3.15
    if [[ $db_ver =~ $re ]]; then
        VERSION_SUFFIX="_db-${DBTYPE}-${BASH_REMATCH[1]}.$(( 10#0${BASH_REMATCH[2]} )).$(( 10#0${BASH_REMATCH[3]} ))"
    fi
}

# =============================================================================
#  BANNER
# =============================================================================
print_banner() {
    [ "$BANNER" == "yes" ] || return 0

    local display_opts=() opt
    for opt in "${DB_OPTS[@]}"; do
        [[ "$opt" == -p* ]] && display_opts+=("-p***") || display_opts+=("$opt")
    done

    local display_cmd
    if [ "$FULL_BACKUP" == "yes" ]; then
        case $DBTYPE in
            mysql) display_cmd="mysqldump ${display_opts[*]} --opt --single-transaction --skip-lock-tables $DBNAME" ;;
            psql)  display_cmd="pg_dump   ${display_opts[*]} -d $DBNAME" ;;
        esac
    else
        case $DBTYPE in
            mysql) display_cmd="mysqldump ${display_opts[*]} (schema all + data, large tables schema-only) $DBNAME" ;;
            psql)  display_cmd="pg_dump   ${display_opts[*]} (large tables via --exclude-table-data) -d $DBNAME" ;;
        esac
    fi

    local compress_label rotate_label mode_label
    case "$COMPRESSION" in
        gz) compress_label="gzip (.tar.gz)" ;;
        xz) compress_label="xz   (.tar.xz)" ;;
        *)  compress_label="none (.tar)"    ;;
    esac
    [ $GENERATIONSTOKEEP -gt 0 ] && rotate_label="keep last $GENERATIONSTOKEEP generation(s)" \
                                 || rotate_label="keep all (no rotation)"
    [ "$FULL_BACKUP" == "yes" ] && mode_label="full (all tables with data)" \
                                || mode_label="config (large data tables: schema only)"

    local fmt_dirs d
    fmt_dirs=""
    for d in "${CFG_DIRS[@]}"; do
        [ -d "$d" ] && fmt_dirs+="  $d [found]\n" || fmt_dirs+="  $d [not present]\n"
    done

    cat <<EOF

================================================================================
  zabbix-dump $VERSION — backup plan
================================================================================

  DATABASE
    Type        : $DBTYPE
    Mode        : $mode_label
EOF
    [ -n "$DBHOST"     ] && echo "    Host        : $DBHOST ($DBHOSTNAME)"
    [ -n "$DBSOCKET"   ] && echo "    Socket      : $DBSOCKET"
    [ -n "$DBPORT"     ] && echo "    Port        : $DBPORT"
    [ -n "$DBSCHEMA"   ] && echo "    Schema      : $DBSCHEMA"
    [ -n "$DBNAME"     ] && echo "    Database    : $DBNAME"
    [ -n "$DBUSER"     ] && echo "    User        : $DBUSER"
    [ -n "$ZBX_CONFIG" ] && echo "    Zabbix cfg  : $ZBX_CONFIG"
    cat <<EOF
    Service     : ${ZBX_SERVICE:-<none detected>} (stopped during backup)
    Output dir  : $DUMPDIR
    Compression : $compress_label
    Rotation    : $rotate_label
    Command     : $display_cmd

  FILESYSTEM CONFIG BACKUP (single archive)
$(printf "%b" "$fmt_dirs")
    Archive     : ${DUMPFILENAME_PREFIX:-zabbix_cfg_<host>}_<timestamp>_configs.tar[.gz|.xz]
    Manifest    : ${DUMPFILENAME_PREFIX:-zabbix_cfg_<host>}_<timestamp>_manifest.md

================================================================================

EOF
}

#TODO Check if duplicated
print_config_summary() {
    [ "$QUIET" == "no" ] || return 0
    local mode_label
    [ "$FULL_BACKUP" == "yes" ] && mode_label="full (all tables with data)" \
                                || mode_label="config (large data tables: schema only)"
    echo "Configuration:"
    echo " - type:     $DBTYPE"
    [ -n "$MYSQL_CONFIG" ] && echo " - cfg file: $MYSQL_CONFIG"
    [ -n "$DBHOST" ]       && echo " - host:     $DBHOST ($DBHOSTNAME)" && echo " - port:     $DBPORT"
    [ -n "$DBSOCKET" ]     && echo " - socket:   $DBSOCKET"
    [ -n "$DBSCHEMA" ]     && echo " - schema:   $DBSCHEMA"
    [ -n "$DBNAME" ]       && echo " - database: $DBNAME"
    [ -n "$DBUSER" ]       && echo " - user:     $DBUSER"
    [ -n "$DUMPDIR" ]      && echo " - output:   $DUMPDIR"
    echo " - service:  ${ZBX_SERVICE:-<none detected>}"
    echo " - mode:     $mode_label"
}

# =============================================================================
#  DATABASE DUMP
# =============================================================================

# TODO Those names need to be passed for relative function as arguments
# Names shared by every artifact of this run.
init_run_names() {
    RUN_TS="$(date +%Y%m%d-%H%M)"
    DUMPFILENAME_PREFIX="zabbix_cfg_${DBHOSTNAME}"
    RUN_BASE="${DUMPFILENAME_PREFIX}_${RUN_TS}${VERSION_SUFFIX}"
    DUMPFILEBASE="${RUN_BASE}.sql"
    DUMPFILE="$DUMPDIR/$DUMPFILEBASE"
}

# TODO Review all the dump sequence.

dump_mysql() {
    # mysqldump cannot mix "data for some tables / no-data for others" in one
    # pass, so split mode needs two passes (schema-all, then data-minus-large).
    # In full mode SCHEMAONLY_TABLES is empty, so pass 2 dumps every table's data.
    local table

    # Pass 1: structure (no data) for all tables + routines
    local opts=(--opt --single-transaction --skip-lock-tables --no-data --routines)
    if [ "$HANDLE_UNKNOWN" == "ignore" ]; then
        while read -r table; do
            elementIn "$table" "${UNKNOWN_TABLES[@]}" && opts+=(--ignore-table="$DBNAME.$table")
        done <<<"$DB_TABLES"
    fi
    
    # TODO check if emit is valid or can be removed
    # TODO add a print here before the start.
    emit truncate mysqldump "${DB_OPTS[@]}" "${opts[@]}" "$DBNAME" \
        || err_dump "table schemas"

    # Pass 2: data (excluding schema-only and, if requested, ignored tables)
    opts=(--opt --single-transaction --skip-lock-tables --no-create-info --skip-extended-insert --skip-triggers)
    while read -r table; do
        if elementIn "$table" "${SCHEMAONLY_TABLES[@]}"; then
            opts+=(--ignore-table="$DBNAME.$table")
            PROCESSED_SCHEMAONLY_TABLES+=("$table")
        fi
        if [ "$HANDLE_UNKNOWN" == "ignore" ]; then
            elementIn "$table" "${UNKNOWN_TABLES[@]}" && opts+=(--ignore-table="$DBNAME.$table")
        fi
    done <<<"$DB_TABLES"
    emit append mysqldump "${DB_OPTS[@]}" "${opts[@]}" "$DBNAME" \
        || err_dump "table data"
}

dump_psql() {
    local table
    local opts=()
    while read -r table; do
        if [ "$HANDLE_UNKNOWN" == "ignore" ]; then
            elementIn "$table" "${UNKNOWN_TABLES[@]}" && opts+=(--exclude-table="$table")
        fi
        if elementIn "$table" "${SCHEMAONLY_TABLES[@]}"; then
            opts+=(--exclude-table-data="$table")
            PROCESSED_SCHEMAONLY_TABLES+=("$table")
        fi
    done <<<"$DB_TABLES"
    [ -n "$DBSCHEMA" ] && opts+=(-n "$DBSCHEMA")

    emit truncate pg_dump "${DB_OPTS[@]}" "${opts[@]}" -d "$DBNAME" \
        || err_dump "database"
}

# emit <truncate|append> <command...>
# Runs the command, sending stdout to the dump file (truncating or appending)
# or to the terminal's stdout when in stdout mode (DUMPDIR == "-").
emit() {
    local action="$1"; shift
    if [ "$DUMPDIR" == "-" ]; then
        "$@" 2>"$ERRORLOG"
    elif [ "$action" == "append" ]; then
        "$@" >>"$DUMPFILE" 2>"$ERRORLOG"
    else
        "$@" >"$DUMPFILE" 2>"$ERRORLOG"
    fi
}

err_dump() {
    err $'\nERROR: Could not backup '"$1"$'.\n'
    cat "$ERRORLOG" >&2
    cleanup; exit 1
}

backup_database() {
    PROCESSED_SCHEMAONLY_TABLES=()
    log "Starting database backup..."
    case $DBTYPE in
        mysql) dump_mysql ;;
        psql)  dump_psql ;;
    esac
}

compress_dump() {
    [ "$DUMPDIR" == "-" ] && return 0

    if [ "$QUIET" == "no" ]; then
        if [ ${#PROCESSED_SCHEMAONLY_TABLES[@]} -gt 0 ]; then
            echo $'\nFor the following large tables only the schema (without data) was stored:'
            local t; for t in "${PROCESSED_SCHEMAONLY_TABLES[@]}"; do echo " - $t"; done
        else
            echo $'\nFull backup: all tables were stored with their data.'
        fi
        echo $'\nCompressing backup file...'
    fi

    case "$COMPRESSION" in
        gz) gzip -f "$DUMPFILE" || die "Could not compress backup file" ;;
        xz) xz   -f "$DUMPFILE" || die "Could not compress backup file" ;;
    esac
    log "Database backup completed"
    log "${DUMPFILE}${SUFFIX}"
}

# =============================================================================
#  FILESYSTEM CONFIG ARCHIVE + MANIFEST
# =============================================================================
backup_filesystem_configs() {
    [ "$DUMPDIR" == "-" ] && return 0

    local tarf tarext
    case "$COMPRESSION" in
        gz) tarf="czf"; tarext=".tar.gz" ;;
        xz) tarf="cJf"; tarext=".tar.xz" ;;
        *)  tarf="cf";  tarext=".tar"    ;;
    esac

    CFG_ARCHIVE="$DUMPDIR/${RUN_BASE}_configs${tarext}"
    CFG_MANIFEST="$DUMPDIR/${RUN_BASE}_manifest.md"

    local present_dirs=() d
    for d in "${CFG_DIRS[@]}"; do
        [ -d "$d" ] && present_dirs+=("$d")
    done

    # NOTE good approach it keep spaces avoiding to duplicate the object.

    log $'\nBacking up filesystem configs (single archive)...'
    if [ ${#present_dirs[@]} -gt 0 ]; then
        tar "$tarf" "$CFG_ARCHIVE" "${present_dirs[@]}" 2>/dev/null \
            || err "WARNING: config archive creation reported errors"
    else
        log "  (no config directories present - skipping archive)"
    fi

    write_manifest "$tarext" present_dirs

    if [ "$QUIET" == "no" ]; then
        [ ${#present_dirs[@]} -gt 0 ] && echo "  $CFG_ARCHIVE"
        echo "  $CFG_MANIFEST"
    fi
}

# TODO pass the output dir as argument could be more appropiate.
# write_manifest <tarext> <name-of-present_dirs-array>
write_manifest() {
    local tarext="$1"; local -n _dirs="$2"
    local mode_label
    [ "$FULL_BACKUP" == "yes" ] && mode_label="full (all data)" \
                                || mode_label="config (large tables schema only)"
    {
        echo "# Zabbix DR Manifest — $(date '+%Y-%m-%d %H:%M')"
        echo ""
        echo "| Field | Value |"
        echo "|-------|-------|"
        echo "| Host | $(hostname -f 2>/dev/null || hostname) |"
        echo "| DB type / name | ${DBTYPE} / ${DBNAME} |"
        echo "| Backup mode | ${mode_label} |"
        echo "| Zabbix service | ${ZBX_SERVICE:-<none>} |"
        echo "| Zabbix DB version | ${VERSION_SUFFIX:-unknown} |"
        echo ""
        echo "## OS"; echo '```'
        [ -f /etc/os-release ] && grep -E '^(NAME|VERSION)=' /etc/os-release || true
        echo "Kernel: $(uname -r)"; echo '```'; echo ""
        echo "## Network Interfaces"; echo '```'
        ip -brief address show 2>/dev/null || ifconfig 2>/dev/null || echo "N/A"
        echo '```'; echo ""
        echo "## Installed Zabbix Packages"; echo '```'
        dpkg -l 'zabbix*' 2>/dev/null || echo "N/A"
        echo '```'; echo ""
        echo "## Web Server / PHP"; echo '```'
        apachectl -v 2>/dev/null || nginx -v 2>/dev/null || echo "N/A"
        php -v 2>/dev/null | head -1 || echo "PHP: N/A"
        echo '```'; echo ""
        echo "## Database"; echo '```'
        case $DBTYPE in
            mysql) mysql --version 2>/dev/null || echo "N/A" ;;
            psql)  psql  --version 2>/dev/null || echo "N/A" ;;
        esac
        echo '```'; echo ""
        echo "## Zabbix Services"; echo '```'
        systemctl list-units 'zabbix*' --no-pager 2>/dev/null || echo "N/A"
        echo '```'; echo ""
        echo "## Archived Paths"; echo '```'
        if [ ${#_dirs[@]} -gt 0 ]; then
            local d; for d in "${_dirs[@]}"; do echo "$d"; done
        else
            echo "(none)"
        fi
        echo '```'; echo ""
        echo "## Artifacts (this backup set)"
        echo "| File | Description |"
        echo "|------|-------------|"
        echo "| \`${DUMPFILEBASE}${SUFFIX}\` | Database dump |"
        echo "| \`${RUN_BASE}_configs${tarext}\` | Filesystem config archive |"
        echo "| \`${RUN_BASE}_manifest.md\` | This manifest |"
        echo ""
        echo "## Restore"; echo '```bash'
        echo "# Filesystem configs"
        echo "tar -xf ${RUN_BASE}_configs${tarext} -C /"
        echo ""
        echo "# Database (example)"
        case $DBTYPE in
            mysql) echo "zcat ${DUMPFILEBASE}${SUFFIX} | mysql -u $DBUSER -p $DBNAME" ;;
            psql)  echo "zcat ${DUMPFILEBASE}${SUFFIX} | psql  -U $DBUSER -d $DBNAME" ;;
        esac
        echo '```'
    } > "$CFG_MANIFEST"
}

# =============================================================================
#  ROTATION (whole backup set)
# =============================================================================
# One rule for the entire set: every run shares "${prefix}_${timestamp}".
# We list the distinct timestamps (newest first), keep GENERATIONSTOKEEP of
# them, and delete every artifact of the older generations.
rotate_backups() {
    [ $GENERATIONSTOKEEP -gt 0 ] || return 0
    [ "$DUMPDIR" == "-" ] && return 0

    log "Rotating old backups, keeping up to $GENERATIONSTOKEEP generation(s)..."
    local old_stamps stamp
    old_stamps=$(
        cd "$DUMPDIR" || exit 0
        ls -1 "${DUMPFILENAME_PREFIX}_"* 2>/dev/null \
            | sed -nE "s/^${DUMPFILENAME_PREFIX}_([0-9]{8}-[0-9]{4}).*/\1/p" \
            | sort -ru \
            | awk "NR>${GENERATIONSTOKEEP}"
    )
    [ -n "$old_stamps" ] || return 0
    while read -r stamp; do
        [ -z "$stamp" ] && continue
        log "  removing generation $stamp"
        ( cd "$DUMPDIR" && rm -f "${DUMPFILENAME_PREFIX}_${stamp}"* 2>/dev/null )
    done <<<"$old_stamps"
}

# =============================================================================
#  MAIN
# =============================================================================
main() {
    # --version / --help (long forms handled before getopts)
    [ "$1" == "--version" ] && show_version
    [[ "$1" == "--help" || "$1" == "-h" ]] && show_help

    require_ubuntu

    parse_args "$@"
    resolve_config

    SUFFIX=""; [ -n "$COMPRESSION" ] && SUFFIX=".${COMPRESSION}"

    # Verify required tooling early
    case $DBTYPE in
        mysql) check_binary mysqldump ;;
        psql)  check_binary pg_dump ;;
        *)     err "Unsupported database type '$DBTYPE'. Use 'mysql' or 'psql'."; exit 1 ;;
    esac

    build_db_opts
    resolve_hostname
    ERRORLOG=$(mktemp)

    # From here on, make sure we always clean up and restart the service.
    trap cleanup EXIT INT TERM

    prepare_dumpdir
    detect_zabbix_service
    
    # TODO add references/comment to the generated vars 
    # SCHEMAONLY_TABLES and KNOWN_TABLES.
    # if -F flag is set SCHEMAONLY_TABLES will be wiped
    load_table_list

    print_config_summary
    print_banner

    # Stop the service for a consistent dump, then do all DB work.
    stop_zabbix_server

    # Generate the variable $DB_TABLES
    fetch_db_tables

    # Generate the variable $UNKOWN_TABLES
    check_unknown_tables

    # Build the "_db-mysql-X.Y.Z" version suffix from the dbversion table.
    # and save in $VERSION_SUFFIX
    resolve_db_version
    
    # Initialize the variables with names and location
    init_run_names

    backup_database
    compress_dump

    # Service can come back up now; DB work is done. (Trap also covers failures.)
    restart_zabbix_server

    backup_filesystem_configs
    rotate_backups

    # Normal exit: disable the trap-driven cleanup duplication, then clean once.
    trap - EXIT INT TERM
    cleanup
    exit 0
}

main "$@"

################################################################################
# List of all known table names.
# The flag SCHEMAONLY marks tables that contain monitoring data (as opposed to
# config data), so only their database schema will be backed up.
#
__DATA__
acknowledges               1.3.1    - 7.4.7     SCHEMAONLY
actions                    1.3.1    - 7.4.7
alerts                     1.3.1    - 7.4.7     SCHEMAONLY
application_discovery      2.5.0    - 5.2.7
application_prototype      2.5.0    - 5.2.7
application_template       2.1.0    - 5.2.7
applications               1.3.1    - 5.2.7
auditlog                   1.3.1    - 7.4.7     SCHEMAONLY
auditlog_details           1.7      - 5.4.12    SCHEMAONLY
autoreg                    1.3.1    - 1.3.4
autoreg_host               1.7      - 7.4.7
changelog                  6.2.0    - 7.4.7
conditions                 1.3.1    - 7.4.7
config                     1.3.1    - 7.2.15
config_autoreg_tls         4.4.0    - 7.4.7
connector                  6.4.0    - 7.4.7
connector_tag              6.4.0    - 7.4.7
corr_condition             3.2.0    - 7.4.7
corr_condition_group       3.2.0    - 7.4.7
corr_condition_tag         3.2.0    - 7.4.7
corr_condition_tagpair     3.2.0    - 7.4.7
corr_condition_tagvalue    3.2.0    - 7.4.7
corr_operation             3.2.0    - 7.4.7
correlation                3.2.0    - 7.4.7
dashboard                  3.4.0    - 7.4.7
dashboard_page             5.4.0    - 7.4.7
dashboard_user             3.4.0    - 7.4.7
dashboard_usrgrp           3.4.0    - 7.4.7
dbversion                  2.1.0    - 7.4.7
dchecks                    1.3.4    - 7.4.7
dhosts                     1.3.4    - 7.4.7
drules                     1.3.4    - 7.4.7
dservices                  1.3.4    - 7.4.7
escalations                1.5.3    - 7.4.7
event_recovery             3.2.0    - 7.4.7     SCHEMAONLY
event_suppress             4.0.0    - 7.4.7     SCHEMAONLY
event_symptom              6.4.0    - 7.4.7     SCHEMAONLY
event_tag                  3.2.0    - 7.4.7     SCHEMAONLY
events                     1.3.1    - 7.4.7     SCHEMAONLY
expressions                1.7      - 7.4.7
functions                  1.3.1    - 7.4.7
globalmacro                1.7      - 7.4.7
globalvars                 1.9.6    - 7.4.7
graph_discovery            1.9.0    - 7.4.7
graph_theme                1.7      - 7.4.7
graphs                     1.3.1    - 7.4.7
graphs_items               1.3.1    - 7.4.7
group_discovery            2.1.4    - 7.4.7
group_prototype            2.1.4    - 7.4.7
groups                     1.3.1    - 3.4.15
ha_node                    6.0.0    - 7.4.7
help_items                 1.3.1    - 2.1.8
hgset                      7.0.0    - 7.4.7
hgset_group                7.0.0    - 7.4.7
history                    1.3.1    - 7.4.7     SCHEMAONLY
history_bin                7.0.0    - 7.4.7     SCHEMAONLY
history_log                1.3.1    - 7.4.7     SCHEMAONLY
history_str                1.3.1    - 7.4.7     SCHEMAONLY
history_str_sync           1.3.1    - 2.2.23    SCHEMAONLY
history_sync               1.3.1    - 2.2.23    SCHEMAONLY
history_text               1.3.1    - 7.4.7     SCHEMAONLY
history_uint               1.3.1    - 7.4.7     SCHEMAONLY
history_uint_sync          1.3.1    - 2.2.23    SCHEMAONLY
host_discovery             2.1.4    - 7.4.7
host_hgset                 7.0.0    - 7.4.7
host_inventory             1.9.6    - 7.4.7
host_profile               1.9.3    - 1.9.5
host_proxy                 7.0.0    - 7.4.7
host_rtdata                6.2.0    - 7.4.7
host_tag                   4.2.0    - 7.4.7
hostmacro                  1.7      - 7.4.7
hostmacro_config           7.4.0    - 7.4.7
hosts                      1.3.1    - 7.4.7
hosts_groups               1.3.1    - 7.4.7
hosts_profiles             1.3.1    - 1.9.2
hosts_profiles_ext         1.6      - 1.9.2
hosts_templates            1.3.1    - 7.4.7
housekeeper                1.3.1    - 7.4.7
hstgrp                     4.0.0    - 7.4.7
httpstep                   1.3.3    - 7.4.7
httpstep_field             3.4.0    - 7.4.7
httpstepitem               1.3.3    - 7.4.7
httptest                   1.3.3    - 7.4.7
httptest_field             3.4.0    - 7.4.7
httptest_tag               5.4.0    - 7.4.7
httptestitem               1.3.3    - 7.4.7
icon_map                   1.9.6    - 7.4.7
icon_mapping               1.9.6    - 7.4.7
ids                        1.3.3    - 7.4.7
images                     1.3.1    - 7.4.7
interface                  1.9.1    - 7.4.7
interface_discovery        2.1.4    - 7.4.7
interface_snmp             5.0.0    - 7.4.7
item_application_prototype 2.5.0    - 5.2.7
item_condition             2.3.0    - 7.4.7
item_discovery             1.9.0    - 7.4.7
item_parameter             5.2.0    - 7.4.7
item_preproc               3.4.0    - 7.4.7
item_rtdata                4.4.0    - 7.4.7
item_rtname                7.0.0    - 7.4.7
item_tag                   5.4.0    - 7.4.7
items                      1.3.1    - 7.4.7
items_applications         1.3.1    - 5.2.7
lld_macro_export           7.4.0    - 7.4.7
lld_macro_path             4.2.0    - 7.4.7
lld_override               5.0.0    - 7.4.7
lld_override_condition     5.0.0    - 7.4.7
lld_override_opdiscover    5.0.0    - 7.4.7
lld_override_operation     5.0.0    - 7.4.7
lld_override_ophistory     5.0.0    - 7.4.7
lld_override_opinventory   5.0.0    - 7.4.7
lld_override_opperiod      5.0.0    - 7.4.7
lld_override_opseverity    5.0.0    - 7.4.7
lld_override_opstatus      5.0.0    - 7.4.7
lld_override_optag         5.0.0    - 7.4.7
lld_override_optemplate    5.0.0    - 7.4.7
lld_override_optrends      5.0.0    - 7.4.7
maintenance_tag            4.0.0    - 7.4.7
maintenances               1.7      - 7.4.7
maintenances_groups        1.7      - 7.4.7
maintenances_hosts         1.7      - 7.4.7
maintenances_windows       1.7      - 7.4.7
mappings                   1.3.1    - 5.2.7
media                      1.3.1    - 7.4.7
media_type                 1.3.1    - 7.4.7
media_type_message         5.0.0    - 7.4.7
media_type_oauth           7.4.0    - 7.4.7
media_type_param           4.4.0    - 7.4.7
mfa                        7.0.0    - 7.4.7
mfa_totp_secret            7.0.0    - 7.4.7
module                     5.0.0    - 7.4.7
node_cksum                 1.3.1    - 2.2.23
node_configlog             1.3.1    - 1.4.7
nodes                      1.3.1    - 2.2.23
opcommand                  1.9.4    - 7.4.7
opcommand_grp              1.9.2    - 7.4.7
opcommand_hst              1.9.2    - 7.4.7
opconditions               1.5.3    - 7.4.7
operations                 1.3.4    - 7.4.7
opgroup                    1.9.2    - 7.4.7
opinventory                3.0.0    - 7.4.7
opmediatypes               1.7      - 1.8.22
opmessage                  1.9.2    - 7.4.7
opmessage_grp              1.9.2    - 7.4.7
opmessage_usr              1.9.2    - 7.4.7
optag                      7.0.0    - 7.4.7
optemplate                 1.9.2    - 7.4.7
permission                 7.0.0    - 7.4.7
problem                    3.2.0    - 7.4.7     SCHEMAONLY
problem_tag                3.2.0    - 7.4.7     SCHEMAONLY
profiles                   1.3.1    - 7.4.7
proxy                      7.0.0    - 7.4.7
proxy_autoreg_host         1.7      - 7.4.7
proxy_dhistory             1.5      - 7.4.7
proxy_group                7.0.0    - 7.4.7
proxy_group_rtdata         7.0.0    - 7.4.7
proxy_history              1.5.1    - 7.4.7
proxy_rtdata               7.0.0    - 7.4.7
regexps                    1.7      - 7.4.7
report                     5.4.0    - 7.4.7
report_param               5.4.0    - 7.4.7
report_user                5.4.0    - 7.4.7
report_usrgrp              5.4.0    - 7.4.7
rights                     1.3.1    - 7.4.7
role                       5.2.0    - 7.4.7
role_rule                  5.2.0    - 7.4.7
scim_group                 6.4.0    - 7.4.7
screen_user                3.0.0    - 5.2.7
screen_usrgrp              3.0.0    - 5.2.7
screens                    1.3.1    - 5.2.7
screens_items              1.3.1    - 5.2.7
script_param               5.4.0    - 7.4.7
scripts                    1.5      - 7.4.7
service_alarms             1.3.1    - 7.4.7
service_problem            6.0.0    - 7.4.7
service_problem_tag        6.0.0    - 7.4.7
service_status_rule        6.0.0    - 7.4.7
service_tag                6.0.0    - 7.4.7
services                   1.3.1    - 7.4.7
services_links             1.3.1    - 7.4.7
services_times             1.3.1    - 5.4.12
sessions                   1.3.1    - 7.4.7
settings                   7.4.0    - 7.4.7
sla                        6.0.0    - 7.4.7
sla_excluded_downtime      6.0.0    - 7.4.7
sla_schedule               6.0.0    - 7.4.7
sla_service_tag            6.0.0    - 7.4.7
slides                     1.3.4    - 5.2.7
slideshow_user             3.0.0    - 5.2.7
slideshow_usrgrp           3.0.0    - 5.2.7
slideshows                 1.3.4    - 5.2.7
sysmap_element_trigger     3.4.0    - 7.4.7
sysmap_element_url         1.9.0    - 7.4.7
sysmap_link_threshold      7.4.0    - 7.4.7
sysmap_shape               3.4.0    - 7.4.7
sysmap_url                 1.9.0    - 7.4.7
sysmap_user                3.0.0    - 7.4.7
sysmap_usrgrp              3.0.0    - 7.4.7
sysmaps                    1.3.1    - 7.4.7
sysmaps_element_tag        5.4.0    - 7.4.7
sysmaps_elements           1.3.1    - 7.4.7
sysmaps_link_triggers      1.5      - 7.4.7
sysmaps_links              1.3.1    - 7.4.7
tag_filter                 4.0.0    - 7.4.7
task                       3.2.0    - 7.4.7     SCHEMAONLY
task_acknowledge           3.4.0    - 7.4.7     SCHEMAONLY
task_check_now             4.0.0    - 7.4.7     SCHEMAONLY
task_close_problem         3.2.0    - 7.4.7     SCHEMAONLY
task_data                  5.0.0    - 7.4.7
task_remote_command        3.4.0    - 7.4.7     SCHEMAONLY
task_remote_command_result 3.4.0    - 7.4.7     SCHEMAONLY
task_result                5.0.0    - 7.4.7
timeperiods                1.7      - 7.4.7
token                      5.4.0    - 7.4.7
trends                     1.3.1    - 7.4.7     SCHEMAONLY
trends_uint                1.5      - 7.4.7     SCHEMAONLY
trigger_depends            1.3.1    - 7.4.7
trigger_discovery          1.9.0    - 7.4.7
trigger_queue              5.2.0    - 7.4.7
trigger_tag                3.2.0    - 7.4.7
triggers                   1.3.1    - 7.4.7
ugset                      7.0.0    - 7.4.7
ugset_group                7.0.0    - 7.4.7
user_history               1.7      - 2.4.8
user_scim_group            6.4.0    - 7.4.7
user_ugset                 7.0.0    - 7.4.7
userdirectory              6.2.0    - 7.4.7
userdirectory_idpgroup     6.4.0    - 7.4.7
userdirectory_ldap         6.4.0    - 7.4.7
userdirectory_media        6.4.0    - 7.4.7
userdirectory_saml         6.4.0    - 7.4.7
userdirectory_usrgrp       6.4.0    - 7.4.7
users                      1.3.1    - 7.4.7
users_groups               1.3.1    - 7.4.7
usrgrp                     1.3.1    - 7.4.7
valuemap                   5.4.0    - 7.4.7
valuemap_mapping           5.4.0    - 7.4.7
valuemaps                  1.3.1    - 5.2.7
widget                     3.4.0    - 7.4.7
widget_field               3.4.0    - 7.4.7
