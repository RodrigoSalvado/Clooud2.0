// Unified template: vnet, storage, private endpoint, app service plan, web app
// Guarda este ficheiro em templates/main.bicep

targetScope = 'resourceGroup'

// Parâmetros gerais
@minLength(1)
@maxLength(40)
@description('Nome da Virtual Network.')
param vnetName string = 'myVNet'

@description('Prefixo de endereço da VNet em CIDR. Ex.: "10.0.0.0/16".')
param addressPrefix string = '10.0.0.0/16'

@minLength(3)
@maxLength(24)
@description('Nome da subnet privada.')
param privateSubnetName string = 'private-subnet'

@description('Prefixo CIDR da subnet privada. Ex.: "10.0.1.0/24".')
param privateSubnetPrefix string = '10.0.1.0/24'

@minLength(3)
@maxLength(24)
@description('Nome da subnet pública.')
param publicSubnetName string = 'public-subnet'

@description('Prefixo CIDR da subnet pública. Ex.: "10.0.2.0/24".')
param publicSubnetPrefix string = '10.0.2.0/24'

@minLength(3)
@maxLength(24)
@description('Nome da Storage Account.')
param storageAccountName string = 'miniprojetostorage20'

@minLength(3)
@maxLength(63)
@description('Nome do Blob Container.')
param containerName string = 'reddit-posts'

@description('Habilitar versioning em blobs?')
param enableBlobVersioning bool = true
@description('Dias de soft delete para blobs. Se <= 0, não configura.')
param blobSoftDeleteDays int = 7

@minLength(1)
@maxLength(40)
@description('Nome do Private Endpoint para Storage.')
param privateEndpointName string = 'pe-storage'

@minLength(1)
@maxLength(40)
@description('Nome do App Service Plan.')
param planName string = 'ASP-MiniProjetoCloud2.0'

@allowed([
  'Free'
  'Shared'
  'Basic'
  'Standard'
  'PremiumV2'
  'PremiumV3'
  'ElasticPremium'
  'Isolated'
])
@description('Tier do App Service Plan.')
param skuTier string = 'Basic'
@description('SKU do App Service Plan.')
param skuName string = 'B2'
@minValue(1)
@description('Número de instâncias do App Service Plan.')
param capacity int = 1
@description('Se true, Plano Linux.')
param isLinux bool = true

@minLength(2)
@maxLength(60)
@description('Nome do Web App.')
param webAppName string = 'minhaapp-rodrig0salv'

@description('Nome da imagem Docker para o Web App.')
param imageName string = 'rodrig0salv/minha-app:latest'

@description('Opcional: SAS token para o container, sem "?". Se usar Managed Identity, deixa vazio.')
@secure()
param containerSasToken string = ''

@description('Se imagem Docker privada: registo URL; caso público, vazio.')
param containerRegistryUrl string = ''
@description('Username do registo privado; vazio se público.')
param containerRegistryUsername string = ''
@secure()
@description('Password do registo privado; vazio se público.')
param containerRegistryPassword string = ''

@description('Definir a true para criar Role Assignment para Managed Identity no Storage. Requer permissões Microsoft.Authorization/roleAssignments/write.')
param createRoleAssignment bool = false

@description('Definir a true para saltar a VNet Integration se já existir. Permite evitar conflito se já estiver integrado.')
param skipVnetIntegration bool = false

// 1. NSG da subnet privada
resource nsgPrivate 'Microsoft.Network/networkSecurityGroups@2022-09-01' = {
  name: '${vnetName}-${privateSubnetName}-nsg'
  location: resourceGroup().location
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

// 2. NSG da subnet pública
resource nsgPublic 'Microsoft.Network/networkSecurityGroups@2022-09-01' = {
  name: '${vnetName}-${publicSubnetName}-nsg'
  location: resourceGroup().location
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

// 3. Virtual Network com subnets
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2022-09-01' = {
  name: vnetName
  location: resourceGroup().location
  properties: {
    addressSpace: { addressPrefixes: [ addressPrefix ] }
    subnets: [
      {
        name: privateSubnetName
        properties: {
          addressPrefix: privateSubnetPrefix
          networkSecurityGroup: { id: nsgPrivate.id }
        }
      }
      {
        name: publicSubnetName
        properties: {
          addressPrefix: publicSubnetPrefix
          networkSecurityGroup: { id: nsgPublic.id }
        }
      }
    ]
  }
}

// 4. Storage Account e Container
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: resourceGroup().location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: []
    }
  }
}
// Configurar versioning e soft delete
resource blobServiceUpdate 'Microsoft.Storage/storageAccounts/blobServices@2021-04-01' = if (enableBlobVersioning || blobSoftDeleteDays > 0) {
  name: 'default'
  parent: storageAccount
  properties: {
    isVersioningEnabled: enableBlobVersioning
    deleteRetentionPolicy: {
      enabled: blobSoftDeleteDays > 0
      days: blobSoftDeleteDays > 0 ? blobSoftDeleteDays : 0
    }
  }
}
resource blobServiceExisting 'Microsoft.Storage/storageAccounts/blobServices@2021-04-01' existing = {
  name: 'default'
  parent: storageAccount
}
resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-04-01' = {
  name: containerName
  parent: blobServiceExisting
  properties: { publicAccess: 'None' }
}

// 5. Private Endpoint para Storage
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2022-05-01' = {
  name: privateEndpointName
  location: resourceGroup().location
  properties: {
    subnet: { id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, privateSubnetName) }
    privateLinkServiceConnections: [
      {
        name: 'pe-connection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [ 'blob' ]
          requestMessage: 'Please approve'
        }
      }
    ]
  }
}
// Private DNS Zone
var dnsZoneName = 'privatelink.blob${environment().suffixes.storage}'
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: dnsZoneName
  location: 'global'
}
resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: '${vnetName}-link'
  parent: privateDnsZone
  properties: {
    virtualNetwork: { id: resourceId('Microsoft.Network/virtualNetworks', vnetName) }
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
  dependsOn: [ vnetLink ]
}

// 6. App Service Plan
resource appServicePlan 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: planName
  location: resourceGroup().location
  sku: {
    tier: skuTier
    name: skuName
    capacity: capacity
  }
  kind: isLinux ? 'linux' : 'app'
  properties: { reserved: isLinux }
}

// Variáveis auxiliares para App Settings
var dockerSettings = (containerRegistryUrl != '' && containerRegistryUsername != '' && containerRegistryPassword != '') ? [
  {
    name: 'DOCKER_REGISTRY_SERVER_URL'
    value: containerRegistryUrl
  }
  {
    name: 'DOCKER_REGISTRY_SERVER_USERNAME'
    value: containerRegistryUsername
  }
  {
    name: 'DOCKER_REGISTRY_SERVER_PASSWORD'
    value: containerRegistryPassword
  }
] : []

var baseSettings = [
  {
    name: 'WEBSITES_PORT'
    value: '5000'
  }
]

var sasSettings = (containerSasToken != '') ? [
  {
    name: 'CONTAINER_SAS_TOKEN'
    value: containerSasToken
  }
  {
    name: 'CONTAINER_URL_WITH_SAS'
    value: 'https://${storageAccountName}.blob${environment().suffixes.storage}/${containerName}?${containerSasToken}'
  }
] : []

// 7. Web App com Managed Identity e App Settings
resource webApp 'Microsoft.Web/sites@2022-03-01' = {
  name: webAppName
  location: resourceGroup().location
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      linuxFxVersion: 'DOCKER|${imageName}'
      alwaysOn: true
      appSettings: concat(dockerSettings, baseSettings, sasSettings)
    }
  }
}

// 8. VNet Integration para Web App (condicional)
resource vnetIntegration 'Microsoft.Web/sites/virtualNetworkConnections@2021-03-01' = if (!skipVnetIntegration) {
  name: privateSubnetName
  parent: webApp
  properties: {
    vnetResourceId: resourceId('Microsoft.Network/virtualNetworks', vnetName)
  }
}

// 9. Role Assignment para Managed Identity no Storage (condicional)
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = if (createRoleAssignment) {
  name: guid(storageAccount.id, webAppName, 'storageBlobContributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: webApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output vnetId string = virtualNetwork.id
output storageAccountId string = storageAccount.id
output privateEndpointId string = privateEndpoint.id
output appServicePlanId string = appServicePlan.id
output webAppDefaultHostName string = webApp.properties.defaultHostName
