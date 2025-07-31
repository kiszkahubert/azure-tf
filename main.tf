terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.5.0"
    }
  }
  required_version = ">= 1.0"
}

provider "azurerm" {
  features {}
}

provider "random" {}

provider "http" {}
  
resource "random_pet" "vm_name" {
  length    = 2
  separator = "-"
}

locals {
  common_tags = {
    environment = var.environment
    owner       = var.owner
  }
}
resource "azurerm_resource_group" "tf-group" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.common_tags
}

resource "azurerm_virtual_network" "tf-vnet" {
  name                = var.virtual_network_name
  address_space       = ["10.0.0.0/24"]
  location            = azurerm_resource_group.tf-group.location
  resource_group_name = azurerm_resource_group.tf-group.name
}

module "subnet-1" {
  source               = "./modules/subnet"
  name                 = "tf-subnet-1"
  resource_group_name  = azurerm_resource_group.tf-group.name
  virtual_network_name = azurerm_virtual_network.tf-vnet.name
  address_prefixes     = ["10.0.0.0/26"]
}

module "subnet-2" {
  source               = "./modules/subnet"
  name                 = "tf-subnet-2"
  resource_group_name  = azurerm_resource_group.tf-group.name
  virtual_network_name = azurerm_virtual_network.tf-vnet.name
  address_prefixes     = ["10.0.0.64/26"]
}

resource "azurerm_network_security_group" "tf-nsg" {
  name                = "tf-nsg"
  location            = azurerm_resource_group.tf-group.location
  resource_group_name = azurerm_resource_group.tf-group.name
  security_rule {
    name                       = "AllowSSHInbound-tf"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_ssh_ip[0]
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "AllowICMPInbound-tf"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Icmp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.allowed_ssh_ip[0]
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "AllowHTTPInbound-tf"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"                 
    destination_address_prefix = "*"
  }
}

resource "azurerm_public_ip" "tf-ipaddr" {
  name                = "tf-ipaddr"
  location            = azurerm_resource_group.tf-group.location
  resource_group_name = azurerm_resource_group.tf-group.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "tf-nic" {
  name                = "tf-nic"
  location            = azurerm_resource_group.tf-group.location
  resource_group_name = azurerm_resource_group.tf-group.name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = module.subnet-1.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.tf-ipaddr.id
  }
}

resource "azurerm_network_interface_security_group_association" "tf-nic-nsg" {
  network_interface_id      = azurerm_network_interface.tf-nic.id
  network_security_group_id = azurerm_network_security_group.tf-nsg.id
}

resource "azurerm_linux_virtual_machine" "tf-vm" {
  name                  = random_pet.vm_name.id
  resource_group_name   = azurerm_resource_group.tf-group.name
  location              = azurerm_resource_group.tf-group.location
  size                  = "Standard_B1s"
  admin_username        = "tf-admin"
  network_interface_ids = [azurerm_network_interface.tf-nic.id]

  # OPTION 1 - Startup script from the local file
  # custom_data = base64encode(file("${path.module}/startup.sh"))

  # OPTION 2 - wget download script from storage acc - need sas token
  # custom_data = base64encode(<<-EOF
  #  #!/bin/bash
  #  exec > >(tee /var/log/startup.log) 2>&1
  #  wget -O /tmp/startup.sh https://LINK_TO_BLOB_STORAGE_HERE
  #  chmod +x /tmp/startup.sh
  #  /tmp/startup.sh
  #EOF
  #)

  # OPTION 3 - Pulling directly from the storage account using SAS token
  custom_data = base64encode(data.http.startup_script.response_body)

  admin_ssh_key {
    username   = "tf-admin"
    public_key = file("~/.ssh/id_rsa_azure.pub")
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}

data "azurerm_storage_account_blob_container_sas" "startup-script" {
  connection_string = "CONNECTION_STRING_HERE"
  container_name    = "scripts"
  https_only        = true
  start  = "2025-07-31"
  expiry = "2025-08-01"
  permissions {
    read   = true
    add    = false
    create = false
    write  = false
    delete = false
    list   = false
  }
}

data "http" "startup_script" {
  url = "https://LINK_TO_BLOB_STORAGE_HERE?${data.azurerm_storage_account_blob_container_sas.startup-script.sas}"
}