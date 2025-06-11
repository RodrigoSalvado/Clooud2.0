// Template unificado sem VNet: storage, app service plan, web app
// Guarda este ficheiro em templates/main.bicep

targetScope = 'resourceGroup'

// Parâmetros gerais
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

// 1. Storage Account e Container
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: resourceGroup().location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
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

// 2. App Service Plan
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

// 3. Web App com Managed Identity e App Settings
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

// 4. Role Assignment para Managed Identity no Storage (condicional)
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = if (createRoleAssignment) {
  name: guid(storageAccount.id, webAppName, 'storageBlobContributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: webApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output storageAccountId string = storageAccount.id
output appServicePlanId string = appServicePlan.id
output webAppDefaultHostName string = webApp.properties.defaultHostName
