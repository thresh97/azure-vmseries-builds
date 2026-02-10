#  **VM-Series Active/Passive High Availability (HA) on Azure**

This deployment provides a native azurerm implementation of a VM-Series firewall VNET in a single-file format for simplicity.

## **Official Documentation**

For detailed guidance on building Azure secondary IP and UDR-based Active/Passive HA, refer to the [official Palo Alto Networks documentation](https://docs.paloaltonetworks.com/vm-series/11-1/vm-series-deployment/set-up-the-vm-series-firewall-on-azure/configure-activepassive-ha-for-vm-series-firewall-on-azure).

## **Key Architecture Components**

1. **High Availability (HA):** Two VM-Series instances deployed across **Availability Zones 1 and 2**. Failover is coordinated by the PAN-OS Azure Plugin via API calls to transition secondary private IPs and update User-Defined Routes (UDRs).  
   * **Note on Failover Timing:** When a failover is initiated by the secondary (passive) VM, the transition of resources typically completes in approximately **30 seconds**.  
2. **Standard SKU Public IPs:** All public IPs use the **Standard SKU** and are "Secure by Default," requiring associated Network Security Groups (NSGs) to permit traffic.  
3. **Subnet Indexing:** **mgmt=1, untrust=2, trust=3, ha2=4, workload=5**.  
4. **Symmetric Return Paths:** The deployment includes dynamic route table entries to ensure that traffic from management source CIDRs returns via the Internet gateway, preventing asymmetric routing when accessing internal workloads.  
5. **Bootstrapping:** Workload instances are automatically provisioned with Nginx and a custom landing page via cloud-init. Firewalls support bootstrap parameters through the firewalls variable map.

## **Selecting a PAN-OS Version & Image**

This deployment defaults to the vmseries-flex offer and byol-gen2 SKU. To verify available images in your target region (e.g., eastus), use the following Azure CLI commands:

### **1\. List Available Offers**

Find the publisher's offers to ensure vmseries-flex is available.
```
az vm image list-offers --location eastus --publisher paloaltonetworks --output table
```
### **2\. List SKUs for the Offer**

Determine the SKU (e.g., byol, bundle1, byol-gen2) for the Flex offer.
```
az vm image list-skus --location eastus --publisher paloaltonetworks --offer vmseries-flex --output table
```
### **3\. List All Available Versions**

List specific PAN-OS versions for a chosen SKU to find the exact version string (e.g., 12.1.4).

```
az vm image list \  
  --location eastus \  
  --publisher paloaltonetworks \  
  --offer vmseries-flex \  
  --sku byol-gen2 \  
  --all \  
  --output table
```
*Note: Ensure the source\_image\_reference and plan blocks in the Terraform configuration match these values.*

## **Instance Selection & Performance**

Selecting the appropriate VM size is critical for both the stability of the HA cluster and the throughput of the security stack:

* **NIC Requirement:** This architecture requires **exactly 4 NICs** per firewall instance (Management, Untrust, Trust, HA2). Ensure your selected VM size supports a minimum of 4 network interfaces.  
* **Performance Generations:** Network Virtual Appliances (NVAs) generally perform better on newer hardware generations. For example, **Dv5-series** instances typically offer superior networking throughput and lower latency compared to **Dv4-series** counterparts.  
* **Vendor Restrictions:** Palo Alto Networks explicitly restricts which Azure instance types and sizes can be used to launch the VM-Series. Not every general-purpose VM size is supported or performant for firewall workloads.  
* **Regional & Subscription Variability:** Instance types and sizes are variable across Azure regions and may be restricted based on your specific Azure subscription quotas.

**Cross-Reference Guides:**

* [Azure Dv5-series size and networking specs](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/dv5-series?tabs=sizenetwork)  
* [Azure Dv4-series size and networking specs](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/dv4-series?tabs=sizenetwork)  
* [Palo Alto Networks VM-Series Azure Performance & Capacity Guide](https://docs.paloaltonetworks.com/vm-series/11-1/vm-series-performance-capacity/vm-series-performance-capacity/vm-series-on-azure-performance-and-capacity)  
* [Palo Alto Networks VM-Series on Azure Models and VM Sizes](https://docs.paloaltonetworks.com/vm-series/11-1/vm-series-performance-capacity/vm-series-performance-capacity/vm-series-on-azure-models-and-vms)

## **Availability Zones vs. Availability Sets**

This architecture prioritizes **Availability Zones (AZ)** over Availability Sets (AS) to provide the highest level of fault protection available in Azure:

| Feature | Availability Zones (Used Here) | Availability Sets |
| :---- | :---- | :---- |
| **Fault Protection** | Protects against **Data Center failures**. | Protects against **Hardware/Rack failures**. |
| **Physical Separation** | Instances are in unique physical buildings with independent power/cooling. | Instances are in the same building, separated by Fault Domains (Racks). |
| **Availability SLA** | **99.99%** for two or more VMs across zones. | **99.95%** for two or more VMs in a set. |
| **Resource Scope** | Zonal resources (Standard SKU) are required. | Regional resources (Basic/Standard) are allowed. |

**Technical Impact:** By utilizing Zones 1 and 2, this deployment ensures that the VM-Series HA pair remains resilient even if an entire Azure data center facility experiences an outage.

## **Resource Inventory**

The following resources are managed by this Terraform configuration:

| Category | Resource Type | Quantity | Purpose |
| :---- | :---- | :---- | :---- |
| **Compute** | azurerm\_linux\_virtual\_machine | 3 | 2x VM-Series Firewalls, 1x Ubuntu Workload VM. |
| **Networking** | azurerm\_virtual\_network | 1 | Hub VNET (e.g., 10.0.0.0/16). |
| **Networking** | azurerm\_subnet | 5 | Mgmt, Untrust, Trust, HA2, and Workload subnets. |
| **Networking** | azurerm\_network\_interface | 9 | 4 NICs per firewall \+ 1 Workload NIC. |
| **Networking** | azurerm\_public\_ip | 6 | 2x Mgmt, 2x Untrust, 1x Untrust Floating, 1x Workload. |
| **Security** | azurerm\_network\_security\_group | 3 | Subnet-level NSGs for Management, Untrust, and Workload. |
| **Routing** | azurerm\_route\_table | 1 | UDR for Workload steering 0.0.0.0/0 to the Trust VIP. |
| **Legal** | azurerm\_marketplace\_agreement | 1 | Programmatic acceptance of Marketplace terms. |

## **Input Variables**

| Variable | Type | Description |
| :---- | :---- | :---- |
| subscription\_id | string | The target Azure Subscription ID. |
| deployment\_code | string | A 3-character prefix (e.g., lab) for unique naming. |
| prefix | string | Base string for resource naming (default: hub-ha). |
| location | string | Azure Region (e.g., East US). |
| vnet\_cidr | string | The address space for the Hub VNET. |
| untrust\_floating\_ip | string | Secondary private IP for Untrust (Internet-facing VIP). |
| trust\_floating\_ip | string | Secondary private IP for Trust (Internal-facing VIP). |
| allowed\_mgmt\_cidrs | list | IPs allowed to access Mgmt and Workload via SSH/HTTPS. |
| ssh\_key | string | Public SSH key for instance login. |
| vm\_size | string | Firewall instance type (default: Standard\_D8s\_v5). |
| workload\_vm\_size | string | Workload instance type (default: Standard\_B2s). |

## **Provider Complexities: AzureRM vs. Microsoft Graph**

Infrastructure resources (managed via azurerm) and identity resources (managed via azuread) interact with different APIs. Due to Entra ID (Graph API) permission constraints often encountered by Terraform service principals, identity creation is handled via the Azure CLI.

Furthermore, PAN-OS 12.1.x requires a client-secret for a successful commit, which is most reliably generated and retrieved via the CLI's interactive or administrative context.

## **1\. Infrastructure Deployment**

First, deploy the core networking and compute resources:

1. **Initialize:** terraform init  
2. **Configure:** Update az\_vmseries\_ha.tfvars with your subscription\_id and ssh\_key. **Note:** You must also populate allowed\_mgmt\_cidrs with your source IP ranges; leaving it empty will prevent management access.  
3. **Apply:** terraform apply \-var-file="az\_vmseries\_ha.tfvars"

**Note the output:** Take note of the environment\_info output (Subscription ID, Tenant ID, and Resource Group Name), as you will need the Resource Group name for the following steps.

## **2\. Azure Identity Setup (Post-Deployment)**

Once Terraform has created the Resource Group (e.g., xyz-vmseries-ha-rg), create the identity required for the Azure HA Plugin.

### **A. Create the Role Definition File**

Create a file named pan\_ha\_role.json. Use the \<subscription\_id\> and \<resource\_group\_name\> from the Terraform outputs.
```
{  
  "Name": "\<role\_name\>",  
  "IsCustom": true,  
  "Description": "Allows VM-Series firewalls to manage Secondary IP Move, UDR, and Public IP associations for HA.",  
  "Actions": \[  
    "Microsoft.Authorization/\*/read",  
    "Microsoft.Compute/virtualMachines/read",  
    "Microsoft.Network/networkInterfaces/\*",  
    "Microsoft.Network/networkSecurityGroups/\*",  
    "Microsoft.Network/routeTables/\*",  
    "Microsoft.Network/virtualNetworks/join/action",  
    "Microsoft.Network/virtualNetworks/subnets/join/action",  
    "Microsoft.Network/publicIPAddresses/join/action",  
    "Microsoft.Network/publicIPAddresses/read",  
    "Microsoft.Network/publicIPAddresses/write"  
  \],  
  "NotActions": \[\],  
  "AssignableScopes": \[  
    "/subscriptions/\<subscription\_id\>/resourceGroups/\<resource\_group\_name\>"  
  \]  
}
```

### **B. Create the Role and Service Principal**

\# Create the custom role in the specific resource group scope  
```
az role definition create --role-definition pan_ha_role.json
```

\# Create the Service Principal scoped to the Resource Group  
```
az ad sp create-for-rbac -n <sp-name> --scopes /subscriptions/<subscription_id>/resourceGroups/<resource_group_name> --role <role_name>
```

*Save the appId (Client ID) and password (Client Secret) from the output for the PAN-OS configuration.*

## **3\. Post-Deployment HA Configuration**

Run these commands via the CLI on each firewall. HA2 uses Ethernet 1/3.

### **Firewall 1 (Primary)**
```
configure  
set network interface ethernet ethernet1/3 ha  
set deviceconfig system hostname azure-ha-fw1  
set deviceconfig high-availability interface ha1 port management  
set deviceconfig high-availability interface ha2 ip-address 10.0.4.4  
set deviceconfig high-availability interface ha2 netmask 255.255.255.0  
set deviceconfig high-availability interface ha2 gateway 10.0.4.1  
set deviceconfig high-availability interface ha2 port ethernet1/3  
set deviceconfig high-availability group mode active-passive   
set deviceconfig high-availability group group-id 63  
set deviceconfig high-availability group peer-ip 10.0.1.5  
set deviceconfig high-availability group state-synchronization enabled yes  
set deviceconfig high-availability group state-synchronization transport udp  
set deviceconfig high-availability group election-option device-priority 100  
set deviceconfig high-availability enabled yes  
set deviceconfig setting advance-routing yes  
set deviceconfig plugins vm_series azure-ha-config client-id <client_id>  
set deviceconfig plugins vm_series azure-ha-config client-secret <client_secret>  
set deviceconfig plugins vm_series azure-ha-config tenant-id <tenant_id>  
set deviceconfig plugins vm_series azure-ha-config subscription-id <subscription_id>  
set deviceconfig plugins vm_series azure-ha-config resource-group <resource_group_name>  
commit  
exit
```

### **Firewall 2 (Secondary)**

```
configure  
set network interface ethernet ethernet1/3 ha  
set deviceconfig system hostname azure-ha-fw2  
set deviceconfig high-availability interface ha1 port management  
set deviceconfig high-availability interface ha2 ip-address 10.0.4.5  
set deviceconfig high-availability interface ha2 netmask 255.255.255.0  
set deviceconfig high-availability interface ha2 gateway 10.0.4.1  
set deviceconfig high-availability interface ha2 port ethernet1/3  
set deviceconfig high-availability group mode active-passive   
set deviceconfig high-availability group group-id 63  
set deviceconfig high-availability group peer-ip 10.0.1.4  
set deviceconfig high-availability group state-synchronization enabled yes  
set deviceconfig high-availability group state-synchronization transport udp  
set deviceconfig high-availability group election-option device-priority 101  
set deviceconfig high-availability enabled yes  
set deviceconfig setting advance-routing yes  
set deviceconfig plugins vm_series azure-ha-config client-id <client_id>  
set deviceconfig plugins vm_series azure-ha-config client-secret <client_secret>  
set deviceconfig plugins vm_series azure-ha-config tenant-id <tenant_id>  
set deviceconfig plugins vm_series azure-ha-config subscription-id <subscription_id>  
set deviceconfig plugins vm_series azure-ha-config resource-group <resource_group_name>  
commit  
exit
```

## **4\. SCM Folder Configuration**

After successfully committing to your SCM Folder, ensure the following network and policy objects are configured to match the live state of the hub firewalls.

**Important Note on HA (SCM 2025.r5.0):** High Availability (HA) must NOT be configured or managed within the SCM Folder as of version 2025.r5.0. This deployment utilizes the Management port for HA1 control traffic, a configuration that is currently not supported in the SCM workflow. HA settings must remain as local device configuration and should be excluded from SCM-pushed templates.

### **Network Interfaces & Zones**

Map the hardware interfaces to the logical zones and virtual routers.

| Interface | Type | IPv4 Address(es) | Zone | Forwarding |
| :---- | :---- | :---- | :---- | :---- |
| ethernet1/1 | Layer3 | 10.0.2.100/24, 10.0.2.4/32, 10.0.2.5/32 | internet | lr:default |
| ethernet1/2 | Layer3 | 10.0.3.100/24, 10.0.3.4/32, 10.0.3.5/32 | local | lr:default |

### **NAT Policy**

Configure the SNAT policy to ensure outbound traffic uses the **Floating VIP** for consistent identity during failover.

**Policy Name:** SNAT Egress

* **Source Zone:** local  
* **Destination Zone:** internet  
* **Destination Interface:** ethernet1/1  
* **Service:** any  
* **Source Translation:** Dynamic IP and Port  
* **Translated Address:** Interface Address \-\> ethernet1/1 \-\> 10.0.2.100

### **Routing (Virtual Router: default)**

* **Default Route (0.0.0.0/0):** Interface ethernet1/1, Next Hop IP Address (Azure Subnet Gateway: 10.0.2.1).  
* **RFC1918 (Private) Routes:** Interface ethernet1/2, Next Hop IP Address (Azure Subnet Gateway: 10.0.3.1).  
