targetScope = 'resourceGroup'

@minLength(1)
@maxLength(40)
@description('Nome da Virtual Network.')
param vnetName string = 'myVNet'

@description('Localização. Por defeito, usa a localização do Resource Group.')
param location string = resourceGroup().location

@minLength(2)
@maxLength(30)
@description('Prefixo de endereço da VNet em CIDR. Ex.: "10.0.0.0/16".')
param addressPrefix string = '10.0.0.0/16'

@minLength(3)
@maxLength(24)
@description('Nome da subnet privada. Ex.: "private-subnet".')
param privateSubnetName string = 'private-subnet'

@description('Prefixo CIDR da subnet privada. Ex.: "10.0.1.0/24".')
param privateSubnetPrefix string = '10.0.1.0/24'

@minLength(3)
@maxLength(24)
@description('Nome da subnet pública. Ex.: "public-subnet".')
param publicSubnetName string = 'public-subnet'

@description('Prefixo CIDR da subnet pública. Ex.: "10.0.2.0/24".')
param publicSubnetPrefix string = '10.0.2.0/24'

// NSG para a subnet privada: bloqueia inbound da Internet, permite tráfego interno e saída.
resource nsgPrivate 'Microsoft.Network/networkSecurityGroups@2022-09-01' = {
  name: '${vnetName}-${privateSubnetName}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-VNet-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: addressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: addressPrefix
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-Internet-Inbound'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: addressPrefix
          destinationPortRange: '*'
        }
      }
      {
        name: 'Allow-Internet-Outbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: addressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// NSG para a subnet pública: permite inbound HTTP/HTTPS/SSH da Internet, tráfego interno e saída.
resource nsgPublic 'Microsoft.Network/networkSecurityGroups@2022-09-01' = {
  name: '${vnetName}-${publicSubnetName}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-HTTP-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: addressPrefix
          destinationPortRange: '80'
        }
      }
      {
        name: 'Allow-HTTPS-Inbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: addressPrefix
          destinationPortRange: '443'
        }
      }
      {
        name: 'Allow-SSH-Inbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: addressPrefix
          destinationPortRange: '22'
        }
      }
      {
        name: 'Allow-VNet-Inbound'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: addressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: addressPrefix
          destinationPortRange: '*'
        }
      }
      {
        name: 'Allow-Internet-Outbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: addressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// Virtual Network com duas subnets
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2022-09-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    subnets: [
      {
        name: privateSubnetName
        properties: {
          addressPrefix: privateSubnetPrefix
          networkSecurityGroup: {
            id: nsgPrivate.id
          }
        }
      }
      {
        name: publicSubnetName
        properties: {
          addressPrefix: publicSubnetPrefix
          networkSecurityGroup: {
            id: nsgPublic.id
          }
        }
      }
    ]
  }
}

output vnetId string = virtualNetwork.id
output privateSubnetId string = virtualNetwork.properties.subnets[0].id
output publicSubnetId string = virtualNetwork.properties.subnets[1].id
