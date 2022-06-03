#!/bin/bash

# Variables
rg=rg-guacamole
location=eastus
mysqldb=guacamoledb
mysqladmin=guacadbadminuser
mysqlpassword=MyStrongPassW0rd
vnet=myVnet
snet=mySubnet
avset=guacamoleAvSet
vmadmin=guacauser
nsg=NSG-Guacamole
lbguacamolepip=lbguacamolepip
pipdnsname=loadbalancerguacamole
lbname=lbguacamole

# Resource Group Creation
az group create --name $rg --location $location

# MySQL Creation
az mysql server create \
    --resource-group $rg \
    --name $mysqldb \
    --location $location \
    --admin-user $mysqladmin \
    --admin-password $mysqlpassword \
    --sku-name B_Gen5_1 \
    --storage-size 51200 \
    --ssl-enforcement Disabled

# MySQL Firewall Settings
az mysql server firewall-rule create \
    --resource-group $rg \
    --server $mysqldb \
    --name AllowYourIP \
    --start-ip-address 0.0.0.0 \
    --end-ip-address 255.255.255.255

# VNET creation
az network vnet create \
    --resource-group $rg \
    --name $vnet \
    --address-prefix 10.0.0.0/16 \
    --subnet-name $snet \
    --subnet-prefix 10.0.1.0/24

# Availability set creation
az vm availability-set create \
    --resource-group $rg \
    --name $avset \
    --platform-fault-domain-count 2 \
    --platform-update-domain-count 3

for i in `seq 1 2`; do
    # VMs Creation
    az vm create --resource-group $rg \
        --name Guacamole-VM$i \
        --availability-set $avset \
        --size Standard_DS1_v2 \
        --image Canonical:UbuntuServer:18.04-LTS:latest \
        --admin-username $vmadmin \
        --generate-ssh-keys \
        --public-ip-address "" \
        --no-wait \
        --vnet-name $vnet \
        --subnet $snet \
        --nsg $nsg 
    done

# Setting NSG rules
az network nsg rule create \
    --resource-group $rg \
    --nsg-name $nsg \
    --name web-rule \
    --access Allow \
    --protocol Tcp \
    --direction Inbound \
    --priority 200 \
    --source-address-prefix Internet \
    --source-port-range "*" \
    --destination-address-prefix "*" \
    --destination-port-range 80

for i in `seq 1 2`; do
    # Generating the Guacamole setup script locally on the VMs
    az vm run-command invoke -g $rg -n Guacamole-VM$i  \
        --command-id RunShellScript \
        --scripts "wget https://raw.githubusercontent.com/ahmedmuhsin/apache-guacamole-azure/main/guac-install.sh -O /tmp/guac-install.sh"
    done
    
for i in `seq 1 2`; do
    # Adjusting database credentials to match the variables
    az vm run-command invoke -g $rg -n Guacamole-VM$i  \
        --command-id RunShellScript \
        --scripts "sudo sed -i.bkp -e 's/mysqlpassword/$mysqlpassword/g' \
        -e 's/mysqldb/$mysqldb/g' \
        -e 's/mysqladmin/$mysqladmin/g' /tmp/guac-install.sh"
    done

for i in `seq 1 2`; do
    # Executing the Guacamole setup script
    az vm run-command invoke -g $rg -n Guacamole-VM$i \
        --command-id RunShellScript \
        --scripts "/bin/bash /tmp/guac-install.sh"
    done

for i in `seq 1 2`; do
    # Installing Nginx to be used as Proxy for Tomcat
    az vm run-command invoke -g $rg -n Guacamole-VM$i \
        --command-id RunShellScript --scripts "sudo apt install --yes nginx-core"
    done

for i in `seq 1 2`; do
    # Configuring NGINX
    az vm run-command invoke -g $rg -n Guacamole-VM$i \
        --command-id RunShellScript \
        --scripts "cat <<'EOT' > /etc/nginx/sites-enabled/default
            # Nginx Config
            server {
            listen 80;
            server_name _;

            location / {


            proxy_pass http://localhost:8080/;
            proxy_buffering off;
            proxy_http_version 1.1;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$http_connection;
            access_log off;
        }
}
EOT"
    done

for i in `seq 1 2`; do
    # Restart NGINX
    az vm run-command invoke -g $rg -n Guacamole-VM$i \
        --command-id RunShellScript \
        --scripts "sudo systemctl restart nginx"
    done

for i in `seq 1 2`; do
    # Restart Tomcat
    az vm run-command invoke -g $rg -n Guacamole-VM$i \
        --command-id RunShellScript \
        --scripts "sudo systemctl restart tomcat8"
    done

for i in `seq 1 2`; do
    # Change to call guacamole directly at "/" instead of "/guacamole"
    az vm run-command invoke -g $rg -n Guacamole-VM$i \
        --command-id RunShellScript \
        --scripts "sudo /bin/rm -rf /var/lib/tomcat7/webapps/ROOT/* && sudo /bin/cp -pr /var/lib/tomcat8/webapps/guacamole/* /var/lib/tomcat8/webapps/ROOT/"
    done

# Creation of Public IP for the Azure Load Balancer
az network public-ip create -g $rg -n $lbguacamolepip -l $location \
    --dns-name $pipdnsname \
    --allocation-method static \
    --idle-timeout 4 \
    --sku Standard

# Creation of Azure Load Balancer
az network lb create -g $rg \
    --name $lbname -l $location \
    --public-ip-address $lbguacamolepip \
    --backend-pool-name backendpool  \
    --frontend-ip-name lbguacafrontend \
    --sku Standard

# Creation of the healthprobe
az network lb probe create \
    --resource-group $rg \
    --lb-name $lbname \
    --name healthprobe \
    --protocol "http" \
    --port 80 \
    --path / \
    --interval 15 

# Creation of the load balancing rule
az network lb rule create \
    --resource-group $rg \
    --lb-name $lbname \
    --name lbrule \
    --protocol tcp \
    --frontend-port 80 \
    --backend-port 80 \
    --frontend-ip-name lbguacafrontend \
    --backend-pool-name backendpool \
    --probe-name healthprobe \
    --load-distribution SourceIPProtocol

# Adding VM1 to the Load Balancer
az network nic ip-config update \
    --name ipconfigGuacamole-VM1 \
    --nic-name Guacamole-VM1VMNic \
    --resource-group $rg \
    --lb-address-pools backendpool \
    --lb-name $lbname 

# Adding VM2 to the Load Balancer
az network nic ip-config update \
    --name ipconfigGuacamole-VM2 \
    --nic-name Guacamole-VM2VMNic \
    --resource-group $rg \
    --lb-address-pools backendpool \
    --lb-name $lbname 

# Creating the INAT Rules
az network lb inbound-nat-rule create \
    --resource-group $rg \
    --lb-name $lbname \
    --name ssh1 \
    --protocol tcp \
    --frontend-port 21 \
    --backend-port 22 \
    --frontend-ip-name lbguacafrontend

az network lb inbound-nat-rule create \
    --resource-group $rg \
    --lb-name $lbname \
    --name ssh2 \
    --protocol tcp \
    --frontend-port 23 \
    --backend-port 22 \
    --frontend-ip-name lbguacafrontend

az network nic ip-config inbound-nat-rule add \
    --inbound-nat-rule ssh1 \
    --ip-config-name ipconfigGuacamole-VM1 \
    --nic-name Guacamole-VM1VMNic \
    --resource-group $rg \
    --lb-name $lbname 

az network nic ip-config inbound-nat-rule add \
    --inbound-nat-rule ssh2 \
    --ip-config-name ipconfigGuacamole-VM2 \
    --nic-name Guacamole-VM2VMNic \
    --resource-group $rg \
    --lb-name $lbname
