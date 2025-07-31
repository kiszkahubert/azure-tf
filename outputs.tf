output "vm-ip-addr" {
  description = "Public IP address of the VM"
  value       = azurerm_public_ip.tf-ipaddr.ip_address
}