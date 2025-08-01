#!/bin/sh

# CheckIP.sh 

# Set PATH for essential commands
PATH=$PATH:/usr/sbin:/usr/bin:/sbin:/bin

# Function to get all non-local IP addresses
get_ips() {
    local os_type=$(uname)
    if [ "$os_type" = "Linux" ]; then
        if [ "$1" = "old" ]; then
            # Use ifconfig for older Linux systems or the -old flag
            ifconfig -a 2>/dev/null | awk '/inet / && !/127.0.0.1/ {print $2}' | cut -d: -f2 | sort -u
        else
            # Use ip addr for modern Linux systems
            ip addr show 2>/dev/null | awk '/inet / && !/127.0.0.1/ {print $2}' | cut -d/ -f1 | sort -u
        fi
    elif [ "$os_type" = "AIX" ]; then
        # Use ifconfig for AIX
        ifconfig -a | awk '/inet / && !/127.0.0.1/ {print $2}' | cut -d/ -f1 | sort -u
    fi
}

# Get a valid nameserver from /etc/resolv.conf
NSERVER=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null)

# Hostname of the current machine (short name)
HOST=$(uname -n | cut -d. -f1)

# Check for command-line options
OLD_CMD=false
SKIP_SPECIAL=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        -old) OLD_CMD=true ;;
        -S)   SKIP_SPECIAL=true ;;
        *)    ;;
    esac
    shift
done

# Iterate over each unique IP address
get_ips "$([ "$OLD_CMD" = "true" ] && echo "old")" | while read -r ip_address; do
    # Skip if IP is a dialup connection
    if [ "$ip_address" = "0.0.0.0" ]; then
        printf "IP: %-18s\t Dialup-Verbindung\n" "$ip_address"
        continue
    fi

    # Perform forward DNS lookup (IP to Name)
    dns_name=$(nslookup "$ip_address" "$NSERVER" 2>/dev/null | awk '/name =/ {print tolower(substr($NF, 1, length($NF)-1)); exit}')

    # If DNS lookup is successful
    if [ -n "$dns_name" ]; then
        # Skip special hostnames if -S flag is set
        if [ "$SKIP_SPECIAL" = "true" ] && echo "$dns_name" | grep -qE "${HOST}boot|${HOST}c"; then
            continue
        fi

        # Perform reverse DNS lookup (Name to IP)
        reverse_ip=$(nslookup "$dns_name" "$NSERVER" 2>/dev/null | awk '/^Address: / && !/#/ {print $2; exit}')

        # Check if the reverse IP matches the original IP
        if [ "$reverse_ip" = "$ip_address" ]; then
            reverse_status="Reverse-IP: $reverse_ip: OK"
        else
            reverse_status="Reverse-IP: $reverse_ip: ERROR"
        fi

        # Get the network interface name
        if [ "$(uname)" = "Linux" ]; then
            if [ "$OLD_CMD" = "true" ]; then
                interface=$(ifconfig -a 2>/dev/null | awk '/inet / && /'${ip_address}'/ {print $1; exit}')
            else
                interface=$(ip addr show | awk '/inet / && /'${ip_address}'/ {print $NF; exit}')
            fi
        else
            interface=$(netstat -in 2>/dev/null | awk '/^'${ip_address}'/ {print $1; exit}')
        fi

        printf "IP: %-16s %-20s Name (nslookup): %-32s %s\n" "$ip_address" "$interface" "$dns_name" "$reverse_status"

        # Check for inconsistencies with /etc/hosts using a here-document for reliability.
        host_names=$(
            awk -v ip="$ip_address" -v dns_name="$dns_name" -v host="$HOST" -f /dev/stdin /etc/hosts <<'EOF'
                $1 == ip {
                    for (i=2; i<=NF; i++) {
                        field = tolower($i);
                        if (field != "" && field != ip && field != dns_name && field != host && field != "loghost") {
                            print field;
                        }
                    }
                }
EOF
        )

        echo "$host_names" | while read -r host_entry; do
            # Check if the hostname from /etc/hosts resolves in DNS
            hosts_ip=$(nslookup "$host_entry" "$NSERVER" 2>/dev/null | awk '/^Address: / && !/#/ {print $2; exit}')
            if [ -z "$hosts_ip" ]; then
                echo "WARNING: IP address $ip_address according to DNS: $dns_name "
                echo "         Found different name in /etc/hosts: $host_entry : not found in DNS"
            else
                echo "INFO: IP address $ip_address according to DNS: $dns_name; "
                echo "      Found different name in /etc/hosts: $host_entry with IP address $hosts_ip"
            fi
        done
    else
        # DNS lookup failed, check /etc/hosts
        host_name=$(awk -v ip="$ip_address" '$1 == ip {print $2; exit}' /etc/hosts 2>/dev/null | tr '[A-Z]' '[a-z]')

        # Get interface name
        if [ "$(uname)" = "Linux" ]; then
            if [ "$OLD_CMD" = "true" ]; then
                interface=$(ifconfig -a 2>/dev/null | awk '/inet / && /'${ip_address}'/ {print $1; exit}')
            else
                interface=$(ip addr show | awk '/inet / && /'${ip_address}'/ {print $NF; exit}')
            fi
        else
            interface=$(netstat -in 2>/dev/null | awk '/^'${ip_address}'/ {print $1; exit}')
        fi

        if [ -n "$host_name" ]; then
            printf "IP: %-16s %-6s Name (/etc/hosts): %s\n" "$ip_address" "$interface" "$host_name"
        else
            printf "IP: %-16s %-20s ERROR? Name not found in DNS or /etc/hosts\n" "$ip_address" "$interface"
        fi
    fi
done
