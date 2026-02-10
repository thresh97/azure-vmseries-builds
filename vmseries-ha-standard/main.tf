# --------------------------------------------------------------------------
# 1. PROVIDERS & DATA SOURCES
# --------------------------------------------------------------------------
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "random" {}

data "azurerm_client_config" "current" {}

# Generate a random 3-alpha character prefix if deployment_code is null/empty
resource "random_string" "deploy_id" {
  length  = 3
  special = false
  upper   = false
  numeric = false
}

locals {
  deploy_prefix = var.deployment_code != null && var.deployment_code != "" ? var.deployment_code : random_string.deploy_id.result
  full_prefix   = "${local.deploy_prefix}-${var.prefix}"
  
  vnet_mask = tonumber(split("/", var.vnet_cidr)[1])
  
  # Subnet indices mapped EXACTLY from OCI template:
  # mgmt=1, untrust=2, trust=3, ha2=4, workload=5
  subnet_cidrs = {
    mgmt     = azurerm_subnet.mgmt.address_prefixes[0]
    untrust  = azurerm_subnet.untrust.address_prefixes[0]
    trust    = azurerm_subnet.trust.address_prefixes[0]
    ha2      = azurerm_subnet.ha2.address_prefixes[0]
    workload = azurerm_subnet.workload.address_prefixes[0]
  }
}

resource "azurerm_resource_group" "this" {
  name     = "${local.full_prefix}-rg"
  location = var.location
}

# --------------------------------------------------------------------------
# 2. MARKETPLACE AGREEMENT
# --------------------------------------------------------------------------
resource "azurerm_marketplace_agreement" "paloalto" {
  publisher = "paloaltonetworks"
  offer     = "vmseries-flex"
  plan      = "byol-gen2"
}

# --------------------------------------------------------------------------
# 3. NETWORKING (Locked Indices 1-5)
# --------------------------------------------------------------------------
resource "azurerm_virtual_network" "hub" {
  name                = "${local.full_prefix}-vnet"
  address_space       = [var.vnet_cidr]
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_subnet" "mgmt" {
  name                 = "mgmt"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, var.default_subnet_mask - local.vnet_mask, 1)]
}

resource "azurerm_subnet" "untrust" {
  name                 = "untrust"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, var.default_subnet_mask - local.vnet_mask, 2)]
}

resource "azurerm_subnet" "trust" {
  name                 = "trust"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, var.default_subnet_mask - local.vnet_mask, 3)]
}

resource "azurerm_subnet" "ha2" {
  name                 = "ha2"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, var.default_subnet_mask - local.vnet_mask, 4)]
}

resource "azurerm_subnet" "workload" {
  name                 = "workload"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, var.default_subnet_mask - local.vnet_mask, 5)]
}

# --------------------------------------------------------------------------
# 4. SECURITY & ROUTING
# --------------------------------------------------------------------------
resource "azurerm_network_security_group" "mgmt" {
  name                = "${local.full_prefix}-mgmt-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  security_rule {
    name                       = "AllowMgmtInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "443"]
    source_address_prefixes    = var.allowed_mgmt_cidrs
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "mgmt" {
  subnet_id                 = azurerm_subnet.mgmt.id
  network_security_group_id = azurerm_network_security_group.mgmt.id
}

resource "azurerm_network_security_group" "untrust" {
  name                = "${local.full_prefix}-untrust-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  security_rule {
    name                       = "AllowOutboundInternet"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }
}

resource "azurerm_subnet_network_security_group_association" "untrust" {
  subnet_id                 = azurerm_subnet.untrust.id
  network_security_group_id = azurerm_network_security_group.untrust.id
}

resource "azurerm_network_security_group" "workload" {
  name                = "${local.full_prefix}-workload-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  security_rule {
    name                       = "AllowPing"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Icmp"
    source_address_prefixes    = var.allowed_mgmt_cidrs
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowSSH"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    destination_port_range     = "22"
    source_address_prefixes    = var.allowed_mgmt_cidrs
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowHTTP"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    destination_port_range     = "80"
    source_address_prefixes    = var.allowed_mgmt_cidrs
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "workload" {
  subnet_id                 = azurerm_subnet.workload.id
  network_security_group_id = azurerm_network_security_group.workload.id
}

resource "azurerm_route_table" "workload" {
  name                = "${local.full_prefix}-workload-rt"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  route {
    name                   = "DefaultRouteToFW"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.trust_floating_ip
  }

  dynamic "route" {
    for_each = var.allowed_mgmt_cidrs
    content {
      name           = "MgmtDirectReturn-${replace(route.value, "/", "-")}"
      address_prefix = route.value
      next_hop_type  = "Internet"
    }
  }
}

resource "azurerm_subnet_route_table_association" "workload" {
  subnet_id      = azurerm_subnet.workload.id
  route_table_id = azurerm_route_table.workload.id
}

# --------------------------------------------------------------------------
# 5. VM-SERIES INSTANCES
# --------------------------------------------------------------------------
resource "azurerm_public_ip" "pip" {
  for_each = {
    for pair in setproduct(keys(var.firewalls), ["mgmt", "untrust"]) : "${pair[0]}-${pair[1]}" => {
      fw_key   = pair[0]
      nic_type = pair[1]
    }
  }
  name                = "${local.full_prefix}-${each.key}-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_public_ip" "untrust_floating_pip" {
  name                = "${local.full_prefix}-untrust-floating-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "nics" {
  for_each = {
    for pair in setproduct(keys(var.firewalls), ["mgmt", "untrust", "trust", "ha2"]) : "${pair[0]}-${pair[1]}" => {
      fw_key   = pair[0]
      nic_type = pair[1]
    }
  }

  name                           = "${local.full_prefix}-${each.key}-nic"
  location                       = azurerm_resource_group.this.location
  resource_group_name            = azurerm_resource_group.this.name
  accelerated_networking_enabled = each.value.nic_type == "mgmt" ? false : true
  ip_forwarding_enabled          = each.value.nic_type == "trust" ? true : false

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = (
      each.value.nic_type == "mgmt" ? azurerm_subnet.mgmt.id :
      each.value.nic_type == "untrust" ? azurerm_subnet.untrust.id :
      each.value.nic_type == "trust" ? azurerm_subnet.trust.id :
      azurerm_subnet.ha2.id
    )
    private_ip_address_allocation = "Static"
    private_ip_address            = cidrhost(local.subnet_cidrs[each.value.nic_type], each.value.fw_key == "fw1" ? 4 : 5)
    public_ip_address_id          = contains(["mgmt", "untrust"], each.value.nic_type) ? azurerm_public_ip.pip[each.key].id : null
    primary                       = true
  }

  dynamic "ip_configuration" {
    for_each = each.value.fw_key == keys(var.firewalls)[0] && contains(["trust", "untrust"], each.value.nic_type) ? [1] : []
    content {
      name                          = "floating-vip"
      subnet_id                     = each.value.nic_type == "trust" ? azurerm_subnet.trust.id : azurerm_subnet.untrust.id
      private_ip_address_allocation = "Static"
      private_ip_address            = each.value.nic_type == "trust" ? var.trust_floating_ip : var.untrust_floating_ip
      public_ip_address_id          = each.value.nic_type == "untrust" ? azurerm_public_ip.untrust_floating_pip.id : null
    }
  }
}

resource "azurerm_linux_virtual_machine" "vmseries" {
  for_each = var.firewalls

  name                = "${local.full_prefix}-${each.key}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  size                = var.vm_size
  zone                = tostring(index(keys(var.firewalls), each.key) + 1)
  admin_username      = "panadmin"

  network_interface_ids = [
    azurerm_network_interface.nics["${each.key}-mgmt"].id,
    azurerm_network_interface.nics["${each.key}-untrust"].id,
    azurerm_network_interface.nics["${each.key}-trust"].id,
    azurerm_network_interface.nics["${each.key}-ha2"].id
  ]

  admin_ssh_key {
    username   = "panadmin"
    public_key = var.ssh_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "paloaltonetworks"
    offer     = "vmseries-flex"
    sku       = "byol-gen2"
    version   = "12.1.4"
  }

  plan {
    name      = "byol-gen2"
    publisher = "paloaltonetworks"
    product   = "vmseries-flex"
  }

  custom_data = base64encode(replace(each.value.user_data, "\n", ";"))
  depends_on  = [azurerm_marketplace_agreement.paloalto]
}

# --------------------------------------------------------------------------
# 6. WORKLOAD LINUX INSTANCE
# --------------------------------------------------------------------------
resource "azurerm_public_ip" "workload_pip" {
  name                = "${local.full_prefix}-workload-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "workload_nic" {
  name                = "${local.full_prefix}-workload-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.workload.id
    private_ip_address_allocation = "Static"
    private_ip_address            = cidrhost(local.subnet_cidrs["workload"], 10)
    public_ip_address_id          = azurerm_public_ip.workload_pip.id
  }
}

resource "azurerm_linux_virtual_machine" "workload" {
  name                = "${local.full_prefix}-workload"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  size                = var.workload_vm_size
  admin_username      = "azureuser"
  network_interface_ids = [
    azurerm_network_interface.workload_nic.id,
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = var.ssh_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  custom_data = base64encode(<<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y nginx
              systemctl start nginx
              systemctl enable nginx
              echo "<h1>Workload VM (Nginx) - Managed by Palo Alto VM-Series HA</h1><p>Azure Hub-Spoke Deployment</p>" > /var/www/html/index.html
              EOF
  )
}

# --------------------------------------------------------------------------
# 7. VARIABLES
# --------------------------------------------------------------------------
variable "subscription_id" { type = string }
variable "deployment_code" { type = string; default = null }
variable "vm_size" { type = string; default = "Standard_D8s_v5" }
variable "workload_vm_size" { type = string; default = "Standard_B2s" }
variable "prefix" { type = string; default = "vmseries-ha" }
variable "location" { type = string }
variable "vnet_cidr" { type = string }
variable "default_subnet_mask" { type = number; default = 24 }
variable "trust_floating_ip" { type = string }
variable "untrust_floating_ip" { type = string }
variable "ssh_key" { type = string }
variable "allowed_mgmt_cidrs" { type = list(string) }
variable "firewalls" {
  type = map(object({
    hostname  = string
    user_data = string
  }))
}

# --------------------------------------------------------------------------
# 8. OUTPUTS
# --------------------------------------------------------------------------
output "environment_info" {
  value = {
    tenant_id       = data.azurerm_client_config.current.tenant_id
    subscription_id = var.subscription_id
    resource_group  = azurerm_resource_group.this.name
  }
}

output "firewall_access_info" {
  value = {
    for k, v in var.firewalls : k => {
      mgmt_public_ip     = azurerm_public_ip.pip["${k}-mgmt"].ip_address
      untrust_public_ip  = azurerm_public_ip.pip["${k}-untrust"].ip_address
    }
  }
}

output "floating_ip_info" {
  value = {
    untrust_public_vip  = azurerm_public_ip.untrust_floating_pip.ip_address
    untrust_private_vip = var.untrust_floating_ip
    trust_private_vip   = var.trust_floating_ip
  }
}

output "workload_access_info" {
  value = {
    public_ip      = azurerm_public_ip.workload_pip.ip_address
    admin_username = azurerm_linux_virtual_machine.workload.admin_username
  }
}
