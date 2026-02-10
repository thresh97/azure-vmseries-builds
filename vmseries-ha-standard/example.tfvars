# --------------------------------------------------------------------------
# General Configuration
# --------------------------------------------------------------------------
subscription_id = "YOUR_SUBSCRIPTION_ID_HERE"
deployment_code = ""              
prefix          = "vmseries-ha"
location        = "East US"
vm_size         = "Standard_D8s_v5"

# --------------------------------------------------------------------------
# Networking Configuration
# --------------------------------------------------------------------------
vnet_cidr           = "10.0.0.0/16"
default_subnet_mask = 24

# Access Allowlist - REQUIRED: Enter your public IP/range here (e.g. ["1.2.3.4/32"])
allowed_mgmt_cidrs = [] 

# Indices: mgmt=1, untrust=2, trust=3, ha2=4, workload=5
# Matches SCM/OCI requirement for 3rd octet consistency
untrust_floating_ip = "10.0.2.100"
trust_floating_ip   = "10.0.3.100"

# --------------------------------------------------------------------------
# Instance Configuration
# --------------------------------------------------------------------------
ssh_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC..."

firewalls = {
  "fw1" = {
    hostname  = "az-hub-fw1"
    user_data = <<EOT
authcodes=YOUR_AUTH_CODE_HERE
panorama-server=cloud
plugin-op-commands=advance-routing:enable,set-cores:2
vm-series-auto-registration-pin-id=00000000-0000-0000-0000-000000000000
vm-series-auto-registration-pin-value=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
dgname=azure_ha
dhcp-send-hostname=yes
dhcp-send-client-id=yes
dhcp-accept-server-hostname=yes
dhcp-accept-server-domain=yes
EOT
  }

  "fw2" = {
    hostname  = "az-hub-fw2"
    user_data = <<EOT
authcodes=YOUR_AUTH_CODE_HERE
panorama-server=cloud
plugin-op-commands=advance-routing:enable,set-cores:2
vm-series-auto-registration-pin-id=00000000-0000-0000-0000-000000000000
vm-series-auto-registration-pin-value=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
dgname=azure_ha
dhcp-send-hostname=yes
dhcp-send-client-id=yes
dhcp-accept-server-hostname=yes
dhcp-accept-server-domain=yes
EOT
  }
}
