targetScope = 'resourceGroup'

@minLength(1)
@maxLength(40)
@description('Nome do Private Endpoint.')
param privateEndpointName string = 'pe-storage'

@minLength(1)
@maxLength(40)
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

// Referenciar recurso existente: Storage Account
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' existing = {
  name: storageAccountName
}

// Referenciar VNet/subnet existente
resource vnet 'Microsoft.Network/virtualNetworks@2022-09-01' existing = {
  name: vnetName
}
var subnetResourceId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetName)

// 1. Criar Private Endpoint para o blob da Storage
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2022-05-01' = {
  name: privateEndpointName
  location: location
  properties: {
    subnet: {
      id: subnetResourceId
    }
    privateLinkServiceConnections: [
      {
        name: 'pe-connection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'blob'
          ]
          requestMessage: 'Please approve connection'
        }
      }
    ]
  }
}

// 2. Private DNS Zone para Blob (privatelink)
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.blob.core.windows.net'
  location: 'global'
}

resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: '${vnetName}-link'
  parent: privateDnsZone
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
    registrationEnabled: false
  }
}

// 3. A record para o Storage Account no Private DNS Zone: usa o IP privado atribuído
// Nota: em Bicep, para obter o IP privado, usamos a propriedade do Private Endpoint
var privateIp = privateEndpoint.properties.ipConfigurations[0].properties.privateIPAddress

resource aRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  name: storageAccountName
  parent: privateDnsZone
  properties: {
    ttl: 3600
    aRecords: [
      {
        ipv4Address: privateIp
      }
    ]
  }
  dependsOn: [
    privateEndpoint
    vnetLink
  ]
}

// 4. (Opcional) Aprovar a Private Endpoint Connection no Storage Account, se necessário.
// Muitas vezes, se o SP tiver permissão, não é preciso. Mas, se for preciso, podes fazer algo assim:
// resource peConnectionApproval 'Microsoft.Storage/storageAccounts/privateEndpointConnections@2021-04-01' = {
//   name: '${storageAccountName}/${privateEndpoint.name}'
//   properties: {
//     privateLinkServiceConnectionState: {
//       status: 'Approved'
//       description: 'Aprovado via Bicep'
//     }
//   }
//   dependsOn: [
//     privateEndpoint
//   ]
// }

output privateEndpointId string = privateEndpoint.id
