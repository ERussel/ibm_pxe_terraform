# Pull in existing SSH key for use with Ansible
data "ibm_compute_ssh_key" "deploymentKey" {
  label = "ryan_tycho"
}

# Create a random name for our VLAN. This is mainly used in testing and will be removed at some point
resource "random_id" "name" {
  byte_length = 4
}

# Create our PXE Vlan 
resource "ibm_network_vlan" "pxe_vlan" {
  name            = "pxe_vlan_${var.datacenter["us-east2"]}"
  datacenter      = "${var.datacenter["us-east2"]}"
  type            = "PRIVATE"
  router_hostname = "bcr01a.${var.datacenter["us-east2"]}"
}

# Create a subnet for DHCP server 
resource "ibm_subnet" "dhcp_subnet" {
  type = "Portable"
  private = true
  ip_version = 4
  capacity = 8
  vlan_id = "${ibm_network_vlan.pxe_vlan.id}"
  notes = "dhcp testing subnet"
}

# Create our VSI PXE instance 
resource "ibm_compute_vm_instance" "pxe_server" {
  hostname             = "pxe${var.datacenter["us-east2"]}"
  domain               = "${var.domain}"
  os_reference_code    = "${var.os_reference_code["u16"]}"
  datacenter           = "${var.datacenter["us-east2"]}"
  network_speed        = 1000
  hourly_billing       = true
  private_network_only = false
  user_metadata        = "${file("install.yml")}"
  flavor_key_name      = "${var.flavor_key_name["pxe"]}"
  tags                 = ["ryantiffany", "pxe-server", "${var.datacenter["us-east2"]}"]
  ssh_key_ids          = ["${data.ibm_compute_ssh_key.deploymentKey.id}"]
  private_vlan_id      = "${ibm_network_vlan.pxe_vlan.id}"
  local_disk           = false
}

# Create a temp inventory file to run Playbooks against 
resource "local_file" "ansible_hosts" {
  content = <<EOF
[vm_instances]
pxe ansible_host=${ibm_compute_vm_instance.pxe_server.ipv4_address} 

EOF

  filename = "${path.cwd}/Hosts/inventory.env"
}

resource "local_file" "curl_body" {
  depends_on = ["local_file.ansible_hosts"]

  content = <<EOF
{
  "parameters": [
    {
      "subjectId": 1061,
      "title": "Set DHCP helper IP for PXE boot"
    },
    "Please set the DHCP helper IP on VLAN ${ibm_network_vlan.pxe_vlan.id} in the ${var.datacenter["us-east2"]} DC to ${ibm_compute_vm_instance.pxe_server.ipv4_address_private}."
  ]
}
EOF

  filename = "${path.cwd}/ticket.json"
}

// resource "null_resource" "create_ticket" {
//   depends_on = ["local_file.curl_body"]

//   provisioner "local-exec" {
//     command = "curl -u ${var.ibm_sl_username}:${var.ibm_sl_api_key} -X POST -H 'Accept: */*' -H 'Accept-Encoding: gzip, deflate, compress' -d @${path.cwd}/ticket.json 'https://api.softlayer.com/rest/v3.1/SoftLayer_Ticket/createStandardTicket.json'"
//   }
// }

# Run ansible playbook to install and configure TFTP/DHCP/Webroot
// resource "null_resource" "run_playbook" {
//   // depends_on = ["null_resource.create_ticket"]
//     depends_on = ["local_file.curl_body"]
//   provisioner "local-exec" {
//     command = "ansible-playbook -i Hosts/inventory.env Playbooks/server-config.yml"
//   }
// }

output "subnet_cidr" {
  value = "${ibm_subnet.dhcp_subnet.subnet_cidr}"
}

data "template_file" "init" {
  template = "${file("${path.cwd}/Templates/pxe.yml.tpl")}"

  vars = {
    first_usable_ip = "${cidrhost(ibm_subnet.dhcp_subnet.subnet_cidr, 2)}"
    last_usable_ip = "${cidrhost(ibm_subnet.dhcp_subnet.subnet_cidr, 6)}"
    subnet_netmask = "${cidrnetmask(ibm_subnet.dhcp_subnet.subnet_cidr)}"
    subnet_gw = "${cidrhost(ibm_subnet.dhcp_subnet.subnet_cidr, 1)}"
    pxe_ip = "${ibm_compute_vm_instance.pxe_server.ipv4_address_private}"
    rando = "${random_id.name.hex}"
  }
}

resource "local_file" "dnsmasq_playbook" {
content = <<EOF
  ${data.template_file.init.rendered}

EOF

  filename = "${path.cwd}/Playbooks/pxe.yml"
}