targetScope = 'resourceGroup'

@minLength(3)
@maxLength(40)
@description('Nome do Private Endpoint.')
param privateEndpointName string = 'pe-storage'

@minLength(3)
@maxLength(24)
@description('Nome da Storage Account existente.')
param storageAccountName string

@minLength(1)
@maxLength(40)
@description('Nome da VNet existente.')
param vnetName string

@minLength(1)
@maxLength(24)
@description('Nome da subnet privada na VNet onde colocar o Private Endpoint.')
param subnetName string

@description('Localização para o Private Endpoint e DNS Zone (geralmente igual ao RG/VNet).')
param location string = resourceGroup().location

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' existing = {
  name: storageAccountName
}

resource vnet 'Microsoft.Network/virtualNetworks@2022-09-01' existing = {
  name: vnetName
}
var subnetResourceId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetName)

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2022-05-01' = {
  name: privateEndpointName
  location: location
  properties: {
    subnet: { id: subnetResourceId }
    privateLinkServiceConnections: [
      {
        name: 'pe-connection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [ 'blob' ]
          requestMessage: 'Please approve connection'
        }
      }
    ]
  }
}

// Private DNS Zone para Blob, usando environment suffix
var dnsZoneName = 'privatelink.blob${environment().suffixes.storage}'
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: dnsZoneName
  location: 'global'
}
resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: '${vnetName}-link'
  parent: privateDnsZone
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}
var privateIp = privateEndpoint.properties.ipConfigurations[0].properties.privateIPAddress
resource aRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  name: storageAccountName
  parent: privateDnsZone
  properties: {
    ttl: 3600
    aRecords: [ { ipv4Address: privateIp } ]
  }
  dependsOn: [ privateEndpoint, vnetLink ]
}

output privateEndpointId string = privateEndpoint.id
