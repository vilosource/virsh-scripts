#!/bin/bash
# Check if a VM name was provided
if [ $# -ne 1 ]; then
    echo "Usage: $0 <new-vm-name>"
    exit 1
fi
# Template VM name
TEMPLATE_VM="ubuntu22.04"
NEW_VM="$1"
# SSH user (already configured in the system)
SSH_USER="jasonvi"

# Ensure template VM is powered off
echo "Checking if template VM is running..."
if virsh domstate $TEMPLATE_VM | grep -q "running"; then
    echo "Shutting down template VM..."
    virsh shutdown $TEMPLATE_VM
    
    # Wait for VM to shut down
    while virsh domstate $TEMPLATE_VM | grep -q "running"; do
        echo "Waiting for template VM to shut down..."
        sleep 5
    done
fi
# Clone the VM with a new MAC address
echo "Cloning template VM to $NEW_VM with a new MAC address..."
virt-clone --original $TEMPLATE_VM --name $NEW_VM --auto-clone --mac RANDOM
# Start the new VM
echo "Starting new VM: $NEW_VM..."
virsh start $NEW_VM
# Wait for VM to boot and get an IP address
echo "Waiting for VM to boot and acquire an IP address..."
sleep 30
# Get the IP address of the new VM
MAX_ATTEMPTS=12
ATTEMPTS=0
VM_IP=""
while [ -z "$VM_IP" ] && [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    # Try virsh domifaddr first
    VM_IP=$(virsh domifaddr $NEW_VM | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -1)
    
    # If that doesn't work, try to get MAC address and use arp
    if [ -z "$VM_IP" ]; then
        echo "virsh domifaddr didn't return an IP, trying alternative methods..."
        # Get the MAC address of the VM
        MAC=$(virsh domiflist $NEW_VM | grep -o -E "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}" | head -1)
        
        if [ ! -z "$MAC" ]; then
            # Try to find IP from MAC using arp
            VM_IP=$(arp -an | grep -i "$MAC" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -1)
            
            # If still no IP, try ping sweep of local network (replace with your subnet)
            if [ -z "$VM_IP" ]; then
                echo "Trying to locate IP with ping sweep..."
                # Get host's IP and subnet
                HOST_IP=$(ip -4 addr show br0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
                if [ -z "$HOST_IP" ]; then
                    # Try the other interface if br0 doesn't have an IP
                    HOST_IP=$(ip -4 addr show enp9s0f1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
                fi
                
                if [ ! -z "$HOST_IP" ]; then
                    SUBNET=$(echo $HOST_IP | cut -d. -f1-3)
                    for i in $(seq 1 254); do
                        ping -c 1 -W 1 "$SUBNET.$i" >/dev/null 2>&1 &
                    done
                    sleep 3
                    VM_IP=$(arp -an | grep -i "$MAC" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -1)
                fi
            fi
        fi
    fi
    
    if [ -z "$VM_IP" ]; then
        echo "Waiting for IP address... (attempt $((ATTEMPTS+1))/$MAX_ATTEMPTS)"
        sleep 10
        ATTEMPTS=$((ATTEMPTS+1))
    fi
done
if [ -z "$VM_IP" ]; then
    echo "Could not get IP address for the new VM. You'll need to change the hostname manually."
    exit 1
fi
echo "New VM IP address: $VM_IP"
# Change the hostname on the new VM
echo "Changing hostname to $NEW_VM..."
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$VM_IP" >/dev/null 2>&1
# Try to SSH as jasonvi user (using preconfigured SSH settings)
echo "Connecting as $SSH_USER..."
if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 $SSH_USER@$VM_IP "sudo hostnamectl set-hostname $NEW_VM && sudo sed -i 's/127.0.1.1.*/127.0.1.1 $NEW_VM/g' /etc/hosts && echo 'Hostname changed to $NEW_VM'" 2>/dev/null; then
    echo "Hostname successfully changed to $NEW_VM"
    echo "Rebooting VM to apply changes..."
    ssh -o StrictHostKeyChecking=no $SSH_USER@$VM_IP "sudo reboot" 2>/dev/null || true
    exit 0
else
    echo "Could not SSH into the VM as $SSH_USER. You'll need to change the hostname manually."
    echo "VM has been cloned and is running with IP: $VM_IP"
    exit 1
fi

