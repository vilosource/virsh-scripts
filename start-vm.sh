#!/bin/bash 

#This script starts the vm with the name provided as an argument and prints the IP address of the VM

# Check if a VM name was provided
if [ $# -ne 1 ]; then
    echo "Usage: $0 <vm-name>"
    exit 1
fi

# VM name
VM_NAME="$1"

# Function to check and load environment variables
check_env_file() {
    local env_file="$1"
    
    # Check if the environment file exists
    if [ ! -f "$env_file" ]; then
        echo "Cloudflare configuration file not found at $env_file"
        return 1
    fi

    # Load the environment file
    echo "Loading Cloudflare API details from $env_file..."
    source "$env_file"

    # Validate required variables are set
    if [ -z "$CF_API_TOKEN" ] || [ -z "$CF_DOMAIN" ]; then
        echo "Required Cloudflare configuration variables are missing in $env_file."
        return 1
    fi
    
    return 0
}

# Check environment variables, first in /etc, then in script directory
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
if check_env_file "/etc/cloudflare.env"; then
    # Successfully loaded from /etc
    CF_ENV_FILE="/etc/cloudflare.env"
elif check_env_file "$SCRIPT_DIR/cloudflare.env"; then
    # Successfully loaded from script directory
    CF_ENV_FILE="$SCRIPT_DIR/cloudflare.env"
else
    echo "Error: Cloudflare configuration file not found in /etc or $SCRIPT_DIR"
    echo "Please create this file with your Cloudflare API details before running this script."
    echo "Required variables: CF_API_TOKEN, CF_DOMAIN, CF_API_EMAIL"
    exit 1
fi

# Function to get Zone ID for domain
get_zone_id() {
    echo "Retrieving Zone ID for $CF_DOMAIN..."
    CF_ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CF_DOMAIN" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" | jq -r '.result[0].id')
    
    if [ -z "$CF_ZONE_ID" ] || [ "$CF_ZONE_ID" == "null" ]; then
        echo "Error: Could not retrieve Zone ID for domain $CF_DOMAIN"
        echo "Please check your API token permissions and domain name."
        exit 1
    fi
    
    echo "Found Zone ID: $CF_ZONE_ID"
}

start_vm() {
    # Check if VM is already running
    if virsh domstate $VM_NAME | grep -q "running"; then
        echo "VM $VM_NAME is already running."
    else
        echo "Starting VM: $VM_NAME..."
        virsh start $VM_NAME
        echo "Waiting for VM to boot and acquire an IP address..."
        sleep 15
    fi
}

get_vm_ip() {
    MAX_ATTEMPTS=12
    ATTEMPTS=0
    VM_IP=""

    while [ -z "$VM_IP" ] && [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
        # Method 1: Try using virsh domifaddr with guest agent
        VM_IP=$(virsh domifaddr $VM_NAME --source agent 2>/dev/null | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | grep -v "127\.0\.0\." | head -1)
        
        # Method 2: If Method 1 failed, try without specifying source
        if [ -z "$VM_IP" ]; then
            VM_IP=$(virsh domifaddr $VM_NAME 2>/dev/null | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | grep -v "127\.0\.0\." | head -1)
        fi
        
        # Method 3: Try using direct qemu-agent command if jq is available
        if [ -z "$VM_IP" ] && command -v jq &>/dev/null; then
            if virsh qemu-agent-command $VM_NAME '{"execute":"guest-ping"}' &>/dev/null; then
                GUEST_IPS=$(virsh qemu-agent-command $VM_NAME '{"execute":"guest-network-get-interfaces"}' 2>/dev/null | 
                          jq -r '.return[] | select(.name != "lo") | .ip_addresses[] | select(.ip_address_type == "ipv4") | .ip_address' 2>/dev/null)
                VM_IP=$(echo "$GUEST_IPS" | grep -v "^127\." | head -1)
            fi
        fi
        
        # Method 4: Try using arp table lookup based on the VM's MAC address
        if [ -z "$VM_IP" ]; then
            # Get the MAC address of the VM
            MAC=$(virsh dumpxml $VM_NAME | grep -o -E "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}" | head -1)
            if [ ! -z "$MAC" ]; then
                # Try to find IP from ARP table
                VM_IP=$(ip neigh | grep -i "$MAC" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -1)
            fi
        fi
        
        if [ -z "$VM_IP" ]; then
            echo "Waiting for IP address... (attempt $((ATTEMPTS+1))/$MAX_ATTEMPTS)"
            sleep 10
            ATTEMPTS=$((ATTEMPTS+1))
        fi
    done

    if [ -z "$VM_IP" ]; then
        echo "Could not get IP address for VM $VM_NAME after $MAX_ATTEMPTS attempts."
        echo "Make sure qemu-guest-agent is installed and running inside the VM."
        echo "You may need to manually determine the IP address."
        exit 1
    else
        echo "VM $VM_NAME is running with IP address: $VM_IP"
    fi
}

check_dns_record() {
    # Get the hostname of the VM
    VM_HOSTNAME=$(virsh dominfo $VM_NAME | grep 'Name:' | awk '{print $2}')
    
    if [ -z "$VM_HOSTNAME" ]; then
        echo "Could not determine the hostname for VM $VM_NAME."
        exit 1
    fi

    # Check the DNS record using local resolver
    DNS_IP=$(dig +short $VM_HOSTNAME)
    
    # Check if the VM name already contains the domain suffix
    if [[ "$VM_NAME" == *".$CF_DOMAIN"* ]]; then
        # The VM name already includes the domain
        RECORD_NAME="${VM_NAME%.$CF_DOMAIN}"
        FQDN="$VM_NAME"
    else
        # The VM name doesn't include the domain
        RECORD_NAME="$VM_NAME"
        FQDN="$RECORD_NAME.$CF_DOMAIN"
    fi
    
    # Also check Cloudflare's DNS records directly
    CF_DNS_RECORD=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=A&name=$FQDN" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json")
    
    CF_DNS_IP=$(echo "$CF_DNS_RECORD" | jq -r '.result[0].content')
    RECORD_ID=$(echo "$CF_DNS_RECORD" | jq -r '.result[0].id')

    echo "Comparing DNS records:"
    echo "- VM Name: $VM_NAME"
    echo "- Record Name: $RECORD_NAME"
    echo "- FQDN: $FQDN"
    echo "- VM Current IP: $VM_IP"
    echo "- Local DNS IP: $DNS_IP"
    echo "- Cloudflare DNS IP: $CF_DNS_IP"

    # First check: Compare VM_IP with local DNS
    if [ -n "$DNS_IP" ] && [ "$DNS_IP" != "$VM_IP" ]; then
        echo "Local DNS record mismatch: $DNS_IP vs $VM_IP"
        DNS_NEEDS_UPDATE=true
    # Second check: Compare VM_IP with Cloudflare DNS
    elif [ "$CF_DNS_IP" == "null" ]; then
        echo "No DNS record found in Cloudflare zone."
        DNS_NEEDS_UPDATE=true
    elif [ "$CF_DNS_IP" != "$VM_IP" ]; then
        echo "Cloudflare DNS record mismatch: $CF_DNS_IP vs $VM_IP"
        DNS_NEEDS_UPDATE=true
    else
        echo "DNS records match the VM IP. No update needed."
        DNS_NEEDS_UPDATE=false
    fi
}

update_dns_record() {
    # Skip if DNS record already matches
    if [ "$DNS_NEEDS_UPDATE" = false ]; then
        echo "Skipping DNS update as record is already correct."
        return
    fi
    
    RECORD_TYPE="A"
    
    # RECORD_ID is now set in check_dns_record
    if [ -z "$RECORD_ID" ] || [ "$RECORD_ID" == "null" ]; then
        # Create a new DNS record
        echo "Creating new DNS record for $FQDN..."
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data '{"type":"'$RECORD_TYPE'","name":"'$RECORD_NAME'","content":"'$VM_IP'","ttl":120,"proxied":false}'
    else
        # Update the existing DNS record
        echo "Updating DNS record for $FQDN..."
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$RECORD_ID" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data '{"type":"'$RECORD_TYPE'","name":"'$RECORD_NAME'","content":"'$VM_IP'","ttl":120,"proxied":false}'
    fi
}

get_zone_id
start_vm
get_vm_ip
check_dns_record
update_dns_record


